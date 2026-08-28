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

(require (prefix-in helix. "helix/commands.scm"))
(require "helix/misc.scm")
(require "helix/ext.scm")
(require-builtin steel/filesystem)

(require "src/server.scm")
(require "src/discovery.scm")
(require "src/dispatch.scm")

(provide remote-start
  remote-stop
  remote-status
  remote-list)

;;;; Configuration ;;;;

;; Loopback only. Binding anything else would expose the editor to the network.
(define host "127.0.0.1")

;; First port to try; the server walks upwards from here if it is taken.
(define base-port 7979)

;; Whether `eval` requests are honoured. Off by default: it hands any local
;; process the whole engine. Set to #t in init.scm before remote-start to
;; enable it.
(define *eval-enabled* (box #f))

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

;;;; Command table ;;;;

;; The commands reachable over the wire. This is the real access control: a
;; name absent from the table cannot run at all. Built in small groups because
;; a call with nine or more arguments inside a required module corrupts the
;; next call's arguments in this Steel build.
(define command-entries
  (append
    (list "open" helix.open "new" helix.new)
    (list "goto" helix.goto "echo" helix.echo)
    (list "buffer-next" helix.buffer-next "buffer-previous" helix.buffer-previous)
    (list "buffer-close" helix.buffer-close "buffer-close!" helix.buffer-close!)
    (list "buffer-close-others" helix.buffer-close-others)
    (list "vsplit" helix.vsplit "hsplit" helix.hsplit)
    (list "vsplit-new" helix.vsplit-new "hsplit-new" helix.hsplit-new)
    (list "quit" helix.quit "quit!" helix.quit!)
    (list "reload" helix.reload "reload-all" helix.reload-all)
    (list "theme" helix.theme "set-language" helix.set-language)
    (list "set-option" helix.set-option "toggle-option" helix.toggle-option)
    (list "change-current-directory" helix.change-current-directory)
    (list "format" helix.format "redraw" helix.redraw)
    (list "config-open" helix.config-open "log-open" helix.log-open)))

(define command-table (apply hash command-entries))

;;;; Running commands ;;;;

;; Run a named command on the editor's own thread. The accept loop is on a
;; native thread, so everything touching the editor goes through
;; hx.block-on-task, which marshals the call onto the main loop and waits for
;; it. Returns a line for the client.
(define (run-editor-command name args)
  ;; No internal defines: binding a module-level table together with a
  ;; parameter inside a provided function panics Helix's Steel compiler
  ;; (analysis.rs, visit_define_without_body). Looking the command up inline
  ;; avoids the binding altogether.
  (hx.block-on-task (lambda () (apply (hash-ref command-table name) args)))
  (string-append "ok " name))

;; Whether a name is one this server will run at all. The dispatcher asks
;; before calling the runner, so an unknown name is refused without raising.
(define (known-command? name)
  (hash-contains? command-table name))

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
                    (if (unbox *eval-enabled*) evaluate-expression #f)
                    'denied
                    (default-denied-commands))]
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
        (set-status! "remote: no free port")))))

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
