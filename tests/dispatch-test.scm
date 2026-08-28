;; Tests for src/dispatch.scm
;; Feeds synthetic request hashes through a dispatcher built with stub runners,
;; so the policy is checked without an editor. No sockets, no threads.

(require "steel-test/test.scm")
(require "../src/dispatch.scm")

(define calls (box '()))

(define (stub-runner name args)
  (set-box! calls (cons (list name args) (unbox calls)))
  (string-append "ran " name))

(define (stub-evaluator expr)
  (string-append "evaled " expr))

(define (exploding-runner name args)
  (error "runner exploded"))

(define known-commands (list "open" "goto" "write" "write!" "run-shell-command"))

(define (known? name) (member name known-commands))

(define (dispatcher-with runner evaluator)
  (make-dispatcher (hash 'token "sekrit"
                    'session
                    "work"
                    'runner
                    runner
                    'known?
                    known?
                    'evaluator
                    evaluator
                    'denied
                    (default-denied-commands))))

(define handler (dispatcher-with stub-runner stub-evaluator))

(define (request token verb args)
  (hash 'token token 'verb verb 'args args))

(define (text-of reply) (hash-ref reply 'text))
(define (stop-of reply) (hash-ref reply 'stop))

(deftest command-name-test
  (testing "valid names"
    (is (valid-command-name? "open"))
    (is (valid-command-name? "buffer-close!"))
    (is (valid-command-name? "goto")))
  (testing "rejected names"
    (is (not (valid-command-name? "")))
    (is (not (valid-command-name? "open; rm -rf /")) "no shell metacharacters")
    (is (not (valid-command-name? "open file")) "no spaces")
    (is (not (valid-command-name? "(eval)")) "no parens")))

(deftest authorisation-test
  (testing "the token gates every request"
    (is (= "error unauthorised" (text-of (handler (request "wrong" "ping" '())))))
    (is (= "error unauthorised" (text-of (handler (request "" "cmd" (list "open"))))))
    (is (authorised? (request "sekrit" "ping" '()) "sekrit"))))

(deftest ping-test
  (testing "ping names the session so a client can confirm its target"
    (is (= "pong work" (text-of (handler (request "sekrit" "ping" '())))))
    (is (not (stop-of (handler (request "sekrit" "ping" '())))))))

(deftest shutdown-test
  (testing "shutdown asks the server to stop"
    (is (stop-of (handler (request "sekrit" "shutdown" '()))))
    (is (= "stopping" (text-of (handler (request "sekrit" "shutdown" '())))))))

(deftest command-test
  (testing "a permitted command reaches the runner"
    (set-box! calls '())
    (define reply (handler (request "sekrit" "cmd" (list "open" "/tmp/a b.txt"))))
    (is (= "ran open" (text-of reply)))
    (is (= 1 (length (unbox calls))))
    (is (equal? (list "open" (list "/tmp/a b.txt")) (car (unbox calls)))
      "arguments arrive intact, spaces and all"))
  (testing "a request with no command name is refused"
    (is (= "error cmd needs a command name"
         (text-of (handler (request "sekrit" "cmd" '()))))))
  (testing "an unknown command is refused without raising"
    ;; Refusing without a raise matters beyond tidiness: a caught Steel error
    ;; holds the client's connection open until the collector runs.
    (set-box! calls '())
    (is (= "error unknown command: frobnicate"
         (text-of (handler (request "sekrit" "cmd" (list "frobnicate"))))))
    (is (empty? (unbox calls)) "and the runner is never called")))

(deftest deny-list-test
  (testing "writes and shell commands are refused"
    (is (= "error command not permitted: write"
         (text-of (handler (request "sekrit" "cmd" (list "write"))))))
    (is (= "error command not permitted: run-shell-command"
         (text-of (handler (request "sekrit" "cmd" (list "run-shell-command" "rm"))))))
    (is (member "write-buffer-close" (default-denied-commands))
      "the deny list uses Helix's real command name"))
  (testing "the runner is never reached for a denied command"
    (set-box! calls '())
    (handler (request "sekrit" "cmd" (list "write!")))
    (is (empty? (unbox calls)))))

(deftest eval-test
  (testing "eval is refused unless an evaluator was supplied"
    (define off (dispatcher-with stub-runner #f))
    (is (= "error eval is disabled" (text-of (off (request "sekrit" "eval" (list "(+ 1 2)")))))))
  (testing "eval reaches the evaluator when enabled"
    (is (= "evaled (+ 1 2)"
         (text-of (handler (request "sekrit" "eval" (list "(+ 1 2)"))))))
    (is (= "error eval needs an expression"
         (text-of (handler (request "sekrit" "eval" '())))))))

(deftest failure-containment-test
  (testing "a command that raises becomes an error line, not a crash"
    (define blowing-up (dispatcher-with exploding-runner #f))
    (define reply (blowing-up (request "sekrit" "cmd" (list "open" "/tmp/x"))))
    (is (starts-with? (text-of reply) "error") "reported as an error")
    (is (not (stop-of reply)) "and the server keeps running")))

(deftest unknown-verb-test
  (testing "an unrecognised verb is reported rather than ignored"
    (is (= "error unknown verb: frobnicate"
         (text-of (handler (request "sekrit" "frobnicate" '())))))))
