;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; discovery.scm - Session files, tokens and liveness
;;;
;;; Each running server writes a session file recording where it listens and
;;; the token needed to talk to it. Clients read that file to find the editor;
;;; the layout is `key=value` lines so a shell script can parse it with sed.
;;;
;;; Sessions are named rather than keyed by pid, after Kakoune's `kak -s`: a
;;; name is what a user types and survives a restart. Liveness is decided by
;;; connecting to the recorded port, not by checking a pid, because Steel
;;; exposes no way to read the current process id.

(require-builtin steel/filesystem)
(require-builtin steel/random)
(require-builtin steel/tcp)
;; steel/process exports its own `set-env-var!`, an alias for `with-env-var`
;; that sets a variable on a command builder rather than on this process. It
;; would shadow the process-wide `set-env-var!` from steel/meta, and
;; `require-builtin ... as` does not take a prefix on this module, so keep the
;; process module confined to this file. remote.scm needs the other one.
(require-builtin steel/process)

(provide
  runtime-dir
  session-path
  generate-token
  write-session!
  remove-session!
  read-session
  parse-session
  session-name->address
  all-session-names
  session-live?
  sweep-sessions!)

;;;; Configuration ;;;;

;; Token alphabet and length. 32 chars of this alphabet is ~165 bits, which is
;; more than enough for a secret that never leaves the machine.
(define token-alphabet "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
(define token-length 32)

(define session-suffix ".session")

;;;; Paths ;;;;

;; Read an environment variable, or #f when it is unset or empty.
(define (env-or-false name)
  (define result (maybe-get-env-var name))
  (if (Ok? result)
    (let ([value (Ok->value result)]) (if (equal? value "") #f value))
    #f))

;;@doc
;; Directory holding session files, created if missing.
;;
;; $XDG_RUNTIME_DIR is already per-user and 0700 on the systems that set it,
;; which is where the access control lives. Elsewhere fall back to a private
;; directory under the user's own space.
(define (runtime-dir)
  (define dir
    (cond
      ;; A single-form cond clause yields void in Steel rather than the test
      ;; value, so every clause here names its result explicitly.
      [(env-or-false "HELIX_REMOTE_DIR") => (lambda (dir) dir)]
      [(equal? (current-os!) "windows")
        (string-append (or (env-or-false "LOCALAPPDATA") ".") "/helix-remote")]
      [(env-or-false "XDG_RUNTIME_DIR")
        =>
        (lambda (base) (string-append base "/helix-remote"))]
      [else
        (string-append (or (env-or-false "TMPDIR") "/tmp")
          "/helix-remote-"
          (or (env-or-false "USER") "user"))]))
  (unless (path-exists? dir)
    (create-directory! dir)
    (restrict-permissions! dir))
  dir)

;; Best effort 0700/0600. steel/filesystem has no permissions primitive, so
;; shell out; on Windows the path is already under the user's profile.
;;
;; Waited on rather than left to run in the background: until chmod returns the
;; file is still at the default mode, and a token file is not something to
;; leave world-readable for even a moment.
(define (restrict-permissions! path)
  (unless (equal? (current-os!) "windows")
    (with-handler (lambda (_) void)
      (let* ([mode (if (is-dir? path) "700" "600")]
             [child (spawn-process (command "chmod" (list mode path)))])
        (when (Ok? child)
          (wait (Ok->value child)))))))

;;@doc
;; Absolute path of the session file for the given session name.
(define (session-path name)
  (string-append (runtime-dir) "/" name session-suffix))

;;;; Tokens ;;;;

;;@doc
;; Generate a fresh random token for a server instance.
(define (generate-token)
  (define size (string-length token-alphabet))
  (list->string
    (map (lambda (_) (string-ref token-alphabet (rng->gen-range 0 size)))
      (range 0 token-length))))

;;;; Session files ;;;;

;;@doc
;; Write the session file for a running server. Returns its path.
(define (write-session! name host port token cwd)
  (define path (session-path name))
  (define body
    (apply string-append
      (list "session=" name "\n"
        "host="
        host
        "\n"
        "port="
        (int->string port)
        "\n"
        "token="
        token
        "\n"
        "cwd="
        cwd
        "\n")))
  (define out
    (begin
      ;; open-output-file fails on an existing file rather than truncating.
      (when (path-exists? path)
        (delete-file! path))
      (open-output-file path)))
  (display body out)
  (close-port out)
  (restrict-permissions! path)
  path)

;;@doc
;; Delete a session file, ignoring one that has already gone.
(define (remove-session! name)
  (define path (session-path name))
  (when (path-exists? path)
    (delete-file! path)))

;;@doc
;; Parse session file contents into a hash of string keys to string values.
;; Malformed lines are skipped rather than raising, so a truncated write does
;; not take the client down with it.
(define (parse-session text)
  (transduce (split-many text "\n")
    (filtering (lambda (line) (string-contains? line "=")))
    (mapping (lambda (line) (split-once line "=")))
    (into-hashmap)))

;;@doc
;; Read and parse a session file, or #f when it does not exist.
(define (read-session name)
  (define path (session-path name))
  (if (path-exists? path)
    (with-handler (lambda (_) #f)
      (parse-session (read-port-to-string (open-input-file path))))
    #f))

;;@doc
;; The "host:port" address a session listens on, or #f if it cannot be read.
(define (session-name->address name)
  (define session (read-session name))
  (if (and session (hash-contains? session "host") (hash-contains? session "port"))
    (string-append (hash-ref session "host") ":" (hash-ref session "port"))
    #f))

;;@doc
;; Names of every session file present, live or stale.
(define (all-session-names)
  (transduce (with-handler (lambda (_) '()) (read-dir (runtime-dir)))
    (mapping file-name)
    (filtering (lambda (f) (ends-with? f session-suffix)))
    (mapping (lambda (f) (substring f 0 (- (string-length f) (string-length session-suffix)))))
    (into-list)))

;;;; Liveness ;;;;

;;@doc
;; Whether something is accepting connections on the session's address. A
;; refused connection means the editor has gone; it does not prove the port
;; still belongs to Helix, which is what the token check is for.
(define (session-live? name)
  (define address (session-name->address name))
  (if address
    (with-handler (lambda (_) #f)
      (begin
        (tcp-connect address)
        #t))
    #f))

;;@doc
;; Delete session files whose port no longer answers, Kakoune's `-clear`.
;; Returns the names removed.
(define (sweep-sessions!)
  (define dead (filter (lambda (name) (not (session-live? name))) (all-session-names)))
  (for-each remove-session! dead)
  dead)
