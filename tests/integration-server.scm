;; A real server, wired the way remote.scm wires one but with a stub runner in
;; place of the editor, so tests/integration.sh can drive it over a socket from
;; another process. Prints its address, then serves until told to stop.
;;
;; Requires HELIX_REMOTE_DIR to be set to a scratch directory.

(require "../src/server.scm")
(require "../src/discovery.scm")
(require "../src/dispatch.scm")
(require-builtin steel/time)

;; Stands in for the editor: echoes what it was asked to run so the test can
;; assert the arguments survived the wire intact.
(define (stub-runner name args)
  (apply string-append (append (list "ran " name) (map (lambda (a) (string-append " [" a "]")) args))))

(define session (if (> (length (command-line)) 2) (list-ref (command-line) 2) "test"))
(define token (generate-token))

(define (known? name) (member name (list "open" "goto" "write" "run-shell-command")))

(define config
  (hash 'token token
    'session
    session
    'runner
    stub-runner
    'known?
    known?
    'evaluator
    #f
    'denied
    (default-denied-commands)))

(define server (start-server "127.0.0.1" 7979 (make-dispatcher config)))

(if server
  (begin
    (write-session! session "127.0.0.1" (server-port server) token (current-directory))
    (displayln (server-address server))
    ;; Serve for long enough for the suite to run, then exit even if the
    ;; shutdown request never arrives, so a failing run cannot leave the
    ;; process behind.
    (time/sleep-ms 60000))
  (begin
    (displayln "no free port")
    (error "could not bind")))
