;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; config.scm - User configuration over the shipped policy
;;;
;;; The defaults in dispatch.scm decide what a server allows and refuses with
;;; no configuration at all. This module layers a user's choices on top of
;;; them, so a command can be added without editing the installed cog, whose
;;; contents the package manager replaces on the next update.
;;;
;;; State is module-level boxes set from init.scm before remote-start, which
;;; reads them once. Nothing here touches Helix, so the whole module runs
;;; under the plain Steel CLI.

(require "dispatch.scm")

(provide
  config-allow!
  config-deny!
  config-allow-denied!
  config-allow-all!
  config-allow-eval!
  effective-allowed
  effective-denied
  allow-all?
  eval-allowed?
  reset-config!)

;;;; State ;;;;

(define *allowed* (box '()))
(define *denied* (box '()))
;; Names lifted out of the shipped deny list. Kept apart from *allowed* so an
;; ordinary allow can never unlock a write or a shell command by accident.
(define *unlocked* (box '()))
(define *allow-all* (box #f))
(define *eval* (box #f))

;;;; Names ;;;;

;; Names arrive either one per argument or as a single list. The list form is
;; what a long list needs: a call with nine or more arguments inside a
;; required module corrupts the next call's arguments in this Steel build.
(define (name-list args)
  (if (and (= 1 (length args)) (list? (car args)))
    (car args)
    args))

;; Append names not already present, preserving order.
(define (add-names current names)
  (foldl (lambda (name acc) (if (member name acc) acc (append acc (list name))))
    current
    names))

(define (without names removed)
  (filter (lambda (name) (not (member name removed))) names))

;;;; Setters ;;;;

;;@doc
;; Add commands to the allow list, on top of the shipped defaults.
(define (config-allow! . names)
  (set-box! *allowed* (add-names (unbox *allowed*) (name-list names))))

;;@doc
;; Add commands to the deny list. A denied name is refused whatever else it
;; appears on, so this is how a default is taken away again.
(define (config-deny! . names)
  (set-box! *denied* (add-names (unbox *denied*) (name-list names))))

;;@doc
;; Lift a name out of the shipped deny list, so that `write` and the rest can
;; be reached over the wire. Only the shipped list is affected: a name passed
;; to `config-deny!` stays denied whichever order the two are called in.
;;
;; Allows the name as well. Lifting a deny on its own would leave the command
;; refused as unknown, which is not what anyone asking for this wants.
(define (config-allow-denied! . names)
  (set-box! *unlocked* (add-names (unbox *unlocked*) (name-list names)))
  (set-box! *allowed* (add-names (unbox *allowed*) (name-list names))))

;;@doc
;; Allow every typable command Helix knows, rather than the listed ones. The
;; deny list still applies, so this alone does not reach a write or a shell.
(define (config-allow-all! [on #t])
  (set-box! *allow-all* on))

;;@doc
;; Allow `eval`, which evaluates arbitrary Steel against the editor. Off by
;; default: it hands any local process the whole engine.
(define (config-allow-eval! [on #t])
  (set-box! *eval* on))

;;;; Effective policy ;;;;

;;@doc
;; The commands named as reachable: the shipped list plus anything allowed.
;; Read with `allow-all?`, which overrides it.
(define (effective-allowed)
  (add-names (default-allowed-commands) (unbox *allowed*)))

;;@doc
;; The commands refused: the shipped list less anything unlocked, plus
;; anything denied.
(define (effective-denied)
  (add-names (without (default-denied-commands) (unbox *unlocked*))
    (unbox *denied*)))

;;@doc
;; Whether every typable command is reachable rather than the listed ones.
(define (allow-all?)
  (unbox *allow-all*))

;;@doc
;; Whether `eval` requests are honoured.
(define (eval-allowed?)
  (unbox *eval*))

;;@doc
;; Return every knob to its shipped state. For tests; the boxes are module
;; state shared by everything that requires this file.
(define (reset-config!)
  (set-box! *allowed* '())
  (set-box! *denied* '())
  (set-box! *unlocked* '())
  (set-box! *allow-all* #f)
  (set-box! *eval* #f))
