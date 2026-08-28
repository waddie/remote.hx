;; Tests for src/config.scm
;; The configuration layer is pure: boxes and list arithmetic over the
;; defaults in dispatch.scm. No editor, no sockets. Each test resets the
;; configuration first, because the boxes are module state shared by the
;; whole suite.

(require "steel-test/test.scm")
(require "../src/config.scm")
(require "../src/dispatch.scm")

(define (denied? name) (if (member name (effective-denied)) #t #f))
(define (allowed? name) (if (member name (effective-allowed)) #t #f))

(deftest defaults-test
  (testing "an unconfigured server allows and denies what it ships with")
  (reset-config!)
  (is (allowed? "open"))
  (is (allowed? "buffer-close!"))
  (is (not (allowed? "yank")) "nothing outside the default list")
  (is (denied? "write"))
  (is (denied? "run-shell-command"))
  (is (not (allow-all?)))
  (is (not (eval-allowed?)) "eval stays off until asked for"))

(deftest allow-test
  (testing "names given one per argument")
  (reset-config!)
  (config-allow! "yank" "reflow")
  (is (allowed? "yank"))
  (is (allowed? "reflow"))
  (is (allowed? "open") "the defaults are added to, not replaced")

  (testing "names given as a single list, for lists too long to pass as arguments")
  (reset-config!)
  (config-allow! (list "yank" "reflow"))
  (is (allowed? "yank"))
  (is (allowed? "reflow"))

  (testing "a name is not added twice")
  (reset-config!)
  (config-allow! "yank" "yank")
  (config-allow! "open")
  (is (= 1 (length (filter (lambda (n) (equal? n "yank")) (effective-allowed)))))
  (is (= 1 (length (filter (lambda (n) (equal? n "open")) (effective-allowed))))))

(deftest deny-test
  (testing "a name can be added to the deny list")
  (reset-config!)
  (config-deny! "config-open")
  (is (denied? "config-open"))
  (is (denied? "write") "the defaults are still denied")

  (testing "denying a command does not remove it from the allow list")
  ;; run-command checks the deny list first, so the refusal is
  ;; `command not permitted` rather than `unknown command`.
  (is (allowed? "config-open")))

(deftest allow-denied-test
  (testing "a default deny can be lifted one name at a time")
  (reset-config!)
  (config-allow-denied! "write")
  (is (not (denied? "write")))
  (is (allowed? "write") "and is allowed too, or it would only be refused as unknown")
  (is (denied? "run-shell-command") "the rest of the deny list is untouched")

  (testing "an explicit deny wins over a lifted default, whichever order they are called in")
  (reset-config!)
  (config-allow-denied! "write")
  (config-deny! "write")
  (is (denied? "write"))
  (reset-config!)
  (config-deny! "write")
  (config-allow-denied! "write")
  (is (denied? "write"))

  (testing "lifting a name that was never denied changes nothing")
  (reset-config!)
  (config-allow-denied! "open")
  (is (= (length (default-denied-commands)) (length (effective-denied)))))

(deftest allow-all-test
  (testing "the switch is off by default and defaults to on when called bare")
  (reset-config!)
  (is (not (allow-all?)))
  (config-allow-all!)
  (is (allow-all?))

  (testing "and can be switched back off")
  (config-allow-all! #f)
  (is (not (allow-all?)))
  (is (allowed? "open") "leaving the default list in place")

  (testing "the deny list still applies")
  (reset-config!)
  (config-allow-all!)
  (is (denied? "write"))
  (is (denied? "run-shell-command")))

(deftest eval-switch-test
  (testing "eval is off until switched on, and can be switched back off")
  (reset-config!)
  (is (not (eval-allowed?)))
  (config-allow-eval!)
  (is (eval-allowed?))
  (config-allow-eval! #f)
  (is (not (eval-allowed?))))

(deftest reset-test
  (testing "reset returns every knob to its shipped state")
  (config-allow! "yank")
  (config-deny! "open")
  (config-allow-denied! "write")
  (config-allow-all!)
  (config-allow-eval!)
  (reset-config!)
  (is (not (allowed? "yank")))
  (is (not (denied? "open")))
  (is (denied? "write"))
  (is (not (allow-all?)))
  (is (not (eval-allowed?))))
