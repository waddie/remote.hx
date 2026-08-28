;; Tests for src/discovery.scm
;; Writes real session files into a scratch directory named by
;; HELIX_REMOTE_DIR, which the test runner sets before loading this file.

(require "steel-test/test.scm")
(require "../src/discovery.scm")

(define token (generate-token))

(deftest token-test
  (testing "tokens are long and drawn from a printable alphabet"
    (is (= 32 (string-length token)))
    (is (not (= token (generate-token))) "a fresh token each time")
    (is (empty? (filter (lambda (c) (equal? c #\newline)) (string->list token)))
      "no newlines, which would break the line protocol")))

(deftest parse-test
  (testing "well formed contents"
    (define parsed (parse-session "session=work\nport=7979\ntoken=abc\n"))
    (is (= "work" (hash-ref parsed "session")))
    (is (= "7979" (hash-ref parsed "port")))
    (is (= "abc" (hash-ref parsed "token"))))
  (testing "a truncated write does not take the reader down"
    (define parsed (parse-session "session=work\ngarbage\n\nport=7979\n"))
    (is (= "work" (hash-ref parsed "session")))
    (is (= "7979" (hash-ref parsed "port")))
    (is (not (hash-contains? parsed "garbage")) "lines without = are skipped")))

(deftest round-trip-test
  (testing "a session file reads back as it was written"
    (write-session! "round-trip" "127.0.0.1" 7979 token "/tmp/project")
    (define parsed (read-session "round-trip"))
    (is (= "round-trip" (hash-ref parsed "session")))
    (is (= "127.0.0.1" (hash-ref parsed "host")))
    (is (= "7979" (hash-ref parsed "port")))
    (is (= token (hash-ref parsed "token")))
    (is (= "/tmp/project" (hash-ref parsed "cwd")))
    (is (= "127.0.0.1:7979" (session-name->address "round-trip"))))
  (testing "rewriting an existing session file replaces it"
    (write-session! "round-trip" "127.0.0.1" 7980 token "/tmp/project")
    (is (= "7980" (hash-ref (read-session "round-trip") "port"))
      "open-output-file refuses an existing file, so the old one is removed first"))
  (testing "a session that was never written reads as false"
    (is (not (read-session "no-such-session")))
    (is (not (session-name->address "no-such-session")))))

(deftest listing-test
  (testing "every session file is listed by name"
    (write-session! "alpha" "127.0.0.1" 7981 token "/tmp/a")
    (write-session! "beta" "127.0.0.1" 7982 token "/tmp/b")
    (define names (all-session-names))
    (is (member "alpha" names))
    (is (member "beta" names))
    (is (not (member "alpha.session" names)) "the suffix is stripped")))

(deftest liveness-test
  (testing "a session whose port refuses connections is dead"
    (write-session! "dead" "127.0.0.1" 7899 token "/tmp/dead")
    (is (not (session-live? "dead"))))
  (testing "sweeping removes dead sessions"
    (define swept (sweep-sessions!))
    (is (member "dead" swept))
    (is (not (member "dead" (all-session-names))))
    (is (not (path-exists? (session-path "dead"))) "and deletes the file")))

(deftest removal-test
  (testing "removing a session is safe to repeat"
    (write-session! "transient" "127.0.0.1" 7983 token "/tmp/t")
    (remove-session! "transient")
    (is (not (member "transient" (all-session-names))))
    (remove-session! "transient")
    (is #t "removing an absent session does not raise")))
