;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; cog.scm - Forge package manifest for remote.hx
;;;
;;; A remote command channel for a running Helix: external processes send
;;; editor commands over a loopback TCP socket, so a file manager, a build
;;; script or a shell can drive the editor already on screen.
;;;
;;; Installable with Steel's package manager:
;;;
;;;   forge pkg install --git https://github.com/waddie/remote.hx
;;;
;;; then, in ~/.config/helix/init.scm:
;;;
;;;   (require "remote.hx/remote.scm")
;;;   (remote-start)

(define package-name 'remote.hx)
(define version "0.2.0")

;; No dependencies: networking, filesystem and process primitives all come
;; from steel-core builtins.
(define dependencies '())
