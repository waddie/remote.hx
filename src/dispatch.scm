;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; dispatch.scm - Request policy
;;;
;;; Decides what a request is allowed to do, and turns it into a reply. Holds
;;; no editor state: the caller supplies a runner for editor commands and an
;;; evaluator for Steel expressions, so the policy can be tested without
;;; Helix in the loop.
;;;
;;; Every request must carry the server's token. A loopback port is reachable
;;; by any process on the machine, unlike a 0600 unix socket, so the token is
;;; what stands in for filesystem permissions. It is the same approach Emacs
;;; takes for `server-use-tcp`.

(provide
  default-allowed-commands
  default-denied-commands
  valid-command-name?
  authorised?
  make-dispatcher)

;;;; Policy ;;;;

;;@doc
;; Commands refused over the wire by default: anything that writes to disk or
;; runs a shell. Mirrors the deny list in helix-editor/helix#13896.
(define (default-denied-commands)
  (list
    "run-shell-command"
    "write"
    "write!"
    "write-buffer-close"
    "write-buffer-close!"
    "write-quit"
    "write-quit!"
    "write-all"
    "write-all!"
    "write-quit-all"
    "write-quit-all!"))

;;@doc
;; Commands reachable over the wire without any configuration: navigation,
;; windows, buffers and display. Nothing here writes to disk or leaves the
;; editor. `remote-allow!` adds to this list; `remote-allow-all!` replaces it
;; with every typable command Helix knows.
;;
;; Built in small groups because a call with nine or more arguments inside a
;; required module corrupts the next call's arguments in this Steel build.
(define (default-allowed-commands)
  (append
    (list "open" "new" "goto" "echo")
    (list "buffer-next" "buffer-previous" "buffer-close" "buffer-close!")
    (list "buffer-close-others" "vsplit" "hsplit")
    (list "vsplit-new" "hsplit-new" "quit" "quit!")
    (list "reload" "reload-all" "theme" "set-language")
    (list "set-option" "toggle-option" "change-current-directory")
    (list "format" "redraw" "config-open" "log-open")))

;; Characters a typable command name may contain. Steel has no
;; `char-alphabetic?`, so compare code points directly.
(define (in-range? code low high)
  (and (>= code low) (<= code high)))

(define (name-char? c)
  (define code (char->integer c))
  (or (in-range? code 97 122) ;; a-z
    (in-range? code 65 90) ;; A-Z
    (in-range? code 48 57) ;; 0-9
    (equal? c #\-)
    (equal? c #\!)
    (equal? c #\?)))

;;@doc
;; Whether a string is shaped like a Helix command name. Rejecting anything
;; else keeps unexpected input away from the lookup.
(define (valid-command-name? name)
  (and (string? name)
    (> (string-length name) 0)
    (<= (string-length name) 64)
    (empty? (filter (lambda (c) (not (name-char? c))) (string->list name)))))

;;@doc
;; Whether a request carries the expected token.
(define (authorised? request token)
  (equal? (hash-ref request 'token) token))

;;;; Dispatch ;;;;

;; Reply helpers, kept local so this module does not depend on server.scm.
(define (ok text) (hash 'text text 'stop #f))
(define (failed text) (hash 'text (string-append "error " text) 'stop #f))
(define (halt text) (hash 'text text 'stop #t))

;; Run one editor command through the supplied runner, reporting failures as
;; an error line rather than letting them reach the accept loop.
;;
;; The checks that can be made without calling into the editor are made here,
;; and answered with a plain string. That is not only tidier: a Steel error
;; that is raised and caught keeps the client's connection open until the
;; garbage collector gets to it, so a request that can be refused without
;; raising leaves the socket to close promptly.
(define (run-command runner known? denied name args)
  (cond
    [(not (valid-command-name? name)) (failed "bad command name")]
    [(member name denied) (failed (string-append "command not permitted: " name))]
    [(not (known? name)) (failed (string-append "unknown command: " name))]
    [else
      (with-handler (lambda (e) (failed (to-string e)))
        (ok (runner name args)))]))

;;@doc
;; Build a request handler for `start-server`.
;;
;; ```scheme
;; (make-dispatcher config)
;; ```
;;
;; config is a hash of:
;;
;; * 'token : string?      - the secret every request must present
;; * 'session : string?    - session name, reported by ping
;; * 'runner : (-> string? list? string?)  - runs a named editor command
;; * 'known? : (-> string? boolean?)       - whether a command name exists
;; * 'evaluator : (-> string? string?)     - evaluates Steel, or #f to refuse
;; * 'denied : list?       - command names to refuse
(define (make-dispatcher config)
  (define token (hash-ref config 'token))
  (define session (hash-ref config 'session))
  (define runner (hash-ref config 'runner))
  (define known? (hash-ref config 'known?))
  (define evaluator (hash-ref config 'evaluator))
  (define denied (hash-ref config 'denied))
  (lambda (request)
    (define verb (hash-ref request 'verb))
    (define args (hash-ref request 'args))
    (cond
      [(not (authorised? request token)) (failed "unauthorised")]
      [(equal? verb "ping") (ok (string-append "pong " session))]
      [(equal? verb "shutdown") (halt "stopping")]
      [(equal? verb "cmd")
        (if (empty? args)
          (failed "cmd needs a command name")
          (run-command runner known? denied (car args) (cdr args)))]
      [(equal? verb "eval")
        (cond
          [(not evaluator) (failed "eval is disabled")]
          [(empty? args) (failed "eval needs an expression")]
          [else (with-handler (lambda (e) (failed (to-string e)))
                 (ok (evaluator (car args))))])]
      [else (failed (string-append "unknown verb: " verb))])))
