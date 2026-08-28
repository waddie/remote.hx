;; Top-level test runner. Requires each module's test file, which registers its
;; deftests as a load side effect, then runs the suite and exits non-zero (via
;; the raise inside run-tests!) if anything failed.
;;
;; Run with:  ./run-tests.sh
;;
;; Needs the steel-test cog installed in $STEEL_HOME/cogs, and
;; HELIX_REMOTE_DIR pointing at a scratch directory: the discovery tests write
;; real session files. run-tests.sh arranges both.

(require "steel-test/test.scm")

(require "dispatch-test.scm")
(require "discovery-test.scm")

(run-tests!)
