;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; remote.hx - Drive a running Helix from another process
;;;
;;; Listens on a loopback TCP port and runs editor commands sent to it, so a
;;; file manager, a build script or a shell can open a file in the editor
;;; already on screen instead of starting a new one.
;;;
;;; Usage:
;;;   :remote-start [session]  - Start the listener (session defaults to cwd)
;;;   :remote-stop             - Stop it and remove the session file
;;;   :remote-status           - Show the session name, address and file
;;;   :remote-list             - List live sessions, clearing dead ones
;;;
;;; From a shell, with bin/hx-send on PATH:
;;;   hx-send open ~/notes/todo.md
;;;   hx-send --session work open src/main.rs goto 120

(require "helix/misc.scm")
(require "helix/ext.scm")
(require-builtin steel/filesystem)

(require "src/server.scm")
(require "src/discovery.scm")
(require "src/dispatch.scm")
(require "src/config.scm")

(provide remote-start
  remote-stop
  remote-status
  remote-list
  remote-allow!
  remote-deny!
  remote-allow-denied!
  remote-allow-all!
  remote-allow-eval!)

;;;; Server settings ;;;;

;; Loopback only. Binding anything else would expose the editor to the network.
(define host "127.0.0.1")

;; First port to try; the server walks upwards from here if it is taken.
(define base-port 7979)

;;;; State ;;;;

;; The process-wide `set-env-var!` lives in steel/meta, and reaching it takes
;; some care. Helix's engine already binds an unprefixed `set-env-var!` from
;; steel/process, a different function that sets a variable on a command
;; builder; requiring steel/meta unprefixed fails on a missing
;; #%function-ptr-table; and a prefixed require-builtin does not resolve inside
;; a required module. It does resolve at the engine's top level, so pull the
;; function out from there once and call it normally.
(define set-process-env-var!
  (eval-string "(begin (require-builtin steel/meta as meta.) meta.set-env-var!)"))

(define *server* (box #f))
(define *session* (box #f))
(define *token* (box #f))

;; The policy this server started with. Configuration is read once, so a
;; change made afterwards does not move the running server's ground.
(define *allowed-commands* (box '()))
(define *allow-any-command* (box #f))

;; Command name to the procedure Helix registered for it, filled as names are
;; asked for.
(define *resolved-commands* (box (hash)))

;;;; User configuration ;;;;

;; Every setter takes names one per argument or as a single list, and hands
;; the list straight on: config.scm accepts either form.

;;@doc
;; Allow further commands over the wire, on top of the defaults.
;;
;; ```scheme
;; (remote-allow! "yank" "reflow")
;; (remote-allow! (list "yank" "reflow"))
;; ```
(define (remote-allow! . names)
  (config-allow! names)
  (warn-if-running!))

;;@doc
;; Refuse commands that would otherwise be allowed. A denied name is refused
;; whatever else it appears on.
(define (remote-deny! . names)
  (config-deny! names)
  (warn-if-running!))

;;@doc
;; Lift a name out of the shipped deny list, one name at a time, so `write`
;; and the rest can be reached. A name also passed to `remote-deny!` stays
;; denied.
(define (remote-allow-denied! . names)
  (config-allow-denied! names)
  (warn-if-running!))

;;@doc
;; Allow every typable command Helix knows rather than the listed ones. The
;; deny list still applies, so this alone reaches no write and no shell.
(define (remote-allow-all! [on #t])
  (config-allow-all! on)
  (warn-if-running!))

;;@doc
;; Allow `eval`, which evaluates arbitrary Steel against the editor. Off by
;; default: it hands any local process the whole engine.
(define (remote-allow-eval! [on #t])
  (config-allow-eval! on)
  (warn-if-running!))

;; Configuration is read by remote-start, so say so rather than leave a call
;; that looks like it took effect.
(define (warn-if-running!)
  (when (unbox *server*)
    (set-status! "remote: configuration applies at the next :remote-start")))

;; Read the configuration once, into the boxes the running server consults.
(define (snapshot-policy!)
  (set-box! *allowed-commands* (effective-allowed))
  (set-box! *allow-any-command* (allow-all?)))

;;;; Resolving commands ;;;;

;; Look up the procedure Helix registered for a typable command name.
;;
;; helix/core/typable holds every entry of Helix's typable command list under
;; its own name, but a prefixed require-builtin does not resolve inside a
;; required module, so reach it through the engine's top level as
;; set-process-env-var! above does. The name has been through
;; valid-command-name? and the prefix confines the lookup to that one module,
;; so the string can only ever name a typable command. A name Helix does not
;; have raises FreeIdentifier.
(define (look-up-command name)
  (eval-string
    (string-append "(begin (require-builtin helix/core/typable as hx-remote-typable.)"
      " hx-remote-typable."
      name
      ")")))

;; The procedure for a name already resolved, or #f.
(define (command-procedure name)
  (if (hash-contains? (unbox *resolved-commands*) name)
    (hash-ref (unbox *resolved-commands*) name)
    #f))

;; Resolve a name and remember the answer, #f included, so a name Helix does
;; not have is not looked up twice. Returns the procedure, or #f.
;;
;; eval-string reaches into the engine, and only the editor's thread may do
;; that: run from the accept loop's own thread it takes the thread down
;; silently and the server stops answering anything at all. hx.block-on-task
;; marshals it across, the same crossing run-editor-command makes.
(define (resolve-command! name)
  (when (and (valid-command-name? name)
         (not (hash-contains? (unbox *resolved-commands*) name)))
    (set-box! *resolved-commands*
      (hash-insert (unbox *resolved-commands*)
        name
        (with-handler (lambda (_) #f)
          (hx.block-on-task (lambda () (with-handler (lambda (_) #f) (look-up-command name))))))))
  (command-procedure name))

;;;; Running commands ;;;;

;; Run a named command on the editor's own thread. The accept loop is on a
;; native thread, so everything touching the editor goes through
;; hx.block-on-task, which marshals the call onto the main loop and waits for
;; it. Returns a line for the client.
;;
;; The typable builtins take their arguments as one list, unlike the variadic
;; wrappers in helix/commands.scm, so args is passed rather than applied.
;;
;; The name is already resolved: the dispatcher asks known-command? first,
;; and that is what resolves.
(define (run-editor-command name args)
  ;; No internal defines: binding a module-level value together with a
  ;; parameter inside a provided function panics Helix's Steel compiler
  ;; (analysis.rs, visit_define_without_body). Looking the command up inline
  ;; avoids the binding altogether.
  (hx.block-on-task (lambda () ((command-procedure name) args)))
  (string-append "ok " name))

;; Whether a name is one this server will run at all: allowed by the policy it
;; started with, and known to this Helix. The dispatcher asks before calling
;; the runner, so an unknown name is refused without raising.
(define (known-command? name)
  (if (and (or (unbox *allow-any-command*) (member name (unbox *allowed-commands*)))
       (resolve-command! name))
    #t
    #f))

;; Evaluate Steel on the editor's thread and render the result.
(define (evaluate-expression expr)
  (to-string (hx.block-on-task (lambda () (eval-string expr)))))

;;;; Session naming ;;;;

;; Default session name: the basename of the working directory, which is what
;; a client is most likely to match on.
(define (default-session-name)
  (define name (file-name (current-directory)))
  (if (or (not name) (equal? name "")) "helix" name))

;;;; Commands ;;;;

;;@doc
;; Start the remote listener.
;;
;; Takes an optional session name, defaulting to the basename of the working
;; directory. Writes a session file recording the address and token, and
;; exports HELIX_REMOTE and HELIX_REMOTE_TOKEN so processes started from this
;; editor find it without a lookup.
(define (remote-start [name #f])
  (if (unbox *server*)
    (set-status! (string-append "remote: already running on "
                  (server-address (unbox *server*))))
    (begin
      (snapshot-policy!)
      (let* ([session (or name (default-session-name))]
             [token (generate-token)]
             [config (hash 'token token
                      'session
                      session
                      'runner
                      run-editor-command
                      'known?
                      known-command?
                      'evaluator
                      (if (eval-allowed?) evaluate-expression #f)
                      'denied
                      (effective-denied))]
             [server (start-server host base-port (make-dispatcher config))])
        (if server
          (begin
            (write-session! session host (server-port server) token (current-directory))
            (set-box! *server* server)
            (set-box! *session* session)
            (set-box! *token* token)
            ;; std::env::set_var races with getenv in a multithreaded
            ;; process, so set these once here and never again.
            (set-process-env-var! "HELIX_REMOTE" (server-address server))
            (set-process-env-var! "HELIX_REMOTE_TOKEN" token)
            (set-status! (string-append "remote: " session " on " (server-address server))))
          (set-status! "remote: no free port"))))))

;;@doc
;; Stop the remote listener and remove its session file.
;;
;; The listener is closed when the accept loop lets go of it, which is usually
;; immediate but is up to the collector. A restart that finds the old port
;; still bound simply takes the next one and rewrites the session file.
(define (remote-stop)
  (define server (unbox *server*))
  (if server
    (begin
      (stop-listener (server-address server) (unbox *token*))
      (remove-session! (unbox *session*))
      (set-box! *server* #f)
      (set-box! *session* #f)
      (set-box! *token* #f)
      (set-status! "remote: stopped"))
    (set-status! "remote: not running")))

;; Wake the blocked accept and tell it to stop. The reply is deliberately not
;; read: an in-process request/response round trip between the editor thread
;; and the server thread can wedge, while a one-way write cannot.
(define (stop-listener address token)
  (with-handler (lambda (_) void)
    (send-oneway address token "shutdown")))

;;@doc
;; Show the current session name, address and session file path.
(define (remote-status)
  (define server (unbox *server*))
  (if server
    (set-status! (string-append "remote: " (unbox *session*)
                  " on "
                  (server-address server)
                  " ("
                  (session-path (unbox *session*))
                  ")"))
    (set-status! "remote: not running")))

;;@doc
;; List live sessions, deleting any whose port no longer answers.
(define (remote-list)
  (sweep-sessions!)
  (define names (all-session-names))
  (if (empty? names)
    (set-status! "remote: no sessions")
    (set-status! (string-append "remote sessions: " (join-names names)))))

;; Comma-separate a list of names without a variadic call.
(define (join-names names)
  (transduce names (into-reducer (lambda (acc n) (if (equal? acc "") n (string-append acc ", " n))) "")))
