;; Copyright (C) 2026 Tom Waddington
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; server.scm - Loopback TCP listener
;;;
;;; A blocking accept loop on a native thread. Knows nothing about Helix: it
;;; reads a request, hands it to a handler function and writes the reply back,
;;; so the whole module can be exercised from the plain Steel CLI.
;;;
;;; Request format, one field per line, so no quoting rules are needed for
;;; paths containing spaces:
;;;
;;;   <token>
;;;   <verb>
;;;   <arg>...
;;;   <blank line>
;;;
;;; The reply is a single line.
;;;
;;; The listener stays in blocking mode. A non-blocking listener hands back
;;; accepted streams that are also non-blocking, and on macOS Steel's buffered
;;; reader turns EWOULDBLOCK into eof, which cannot be told apart from a real
;;; close; there is no primitive to put a stream back into blocking mode.
;;; Shutdown therefore comes over the socket itself (see the `stop` field of a
;;; handler result).
;;;
;;; Connections are served one at a time on the accept loop's own thread.
;;; Steel exposes no socket read timeout, so a client that connects and sends
;;; nothing blocks the loop until it goes away: requests from elsewhere queue
;;; in the listen backlog and are answered once it does. Handing connections to
;;; a steel/sync thread pool removes that, but the pool made the server exit
;;; mid-request under the integration suite, so the simpler loop wins. The
;;; exposure is one local process stalling a token-gated loopback port, and it
;;; recovers by itself.
;;;
;;; `tcp-shutdown!` is never called. On macOS it raises "Socket is not
;;; connected" (os error 57), which kills the accept loop's thread silently.
;;; Dropping the stream closes it.

(require-builtin steel/tcp)
(require "steel/sync")

(provide
  start-server
  send-oneway
  server-address
  server-port
  server-host
  make-reply
  reply-text
  reply-stop?)

;;;; Configuration ;;;;

;; How many consecutive ports to try before giving up.
(define default-attempts 16)

;; Upper bound on argument lines accepted per request, so a hostile or broken
;; client cannot make the editor read forever.
(define max-args 64)

;;;; Handler results ;;;;

;;@doc
;; Build a handler result: the line to send back, and whether the server
;; should stop after sending it.
(define (make-reply text stop?)
  (hash 'text text 'stop stop?))

;;@doc
;; The reply line of a handler result.
(define (reply-text reply)
  (hash-ref reply 'text))

;;@doc
;; Whether a handler result asks the server to stop.
(define (reply-stop? reply)
  (hash-ref reply 'stop))

;;;; Reading requests ;;;;

;; Read one line, trimmed, or #f at end of stream.
(define (read-field port)
  (define line (read-line-from-port port))
  (if (string? line) (trim line) #f))

;; Read argument lines until a blank line, end of stream, or the cap.
(define (read-args port acc)
  (if (>= (length acc) max-args)
    (reverse acc)
    (let ([field (read-field port)])
      (if (or (not field) (equal? field ""))
        (reverse acc)
        (read-args port (cons field acc))))))

;; Parse a connection into a request hash, or #f if it carried no verb.
(define (read-request port)
  (define token (read-field port))
  (define verb (read-field port))
  (if (and token verb (not (equal? verb "")))
    (hash 'token token 'verb verb 'args (read-args port '()))
    #f))

;;;; Serving ;;;;

;; Write a single reply line and flush, since write does not flush itself.
(define (write-reply port text)
  (display text port)
  (display "\n" port)
  (flush-output-port port))

;; Handle one accepted connection. Returns #t when the server should stop.
(define (serve-connection stream handler)
  (define request (read-request (tcp-stream-buffered-reader stream)))
  (define writer (tcp-stream-writer stream))
  (if request
    (let ([reply (handler request)])
      (write-reply writer (reply-text reply))
      (reply-stop? reply))
    (begin
      (write-reply writer "error empty request")
      #f)))

;; Accept loop. Any error handling one connection is swallowed so a bad client
;; cannot take the listener down with it.
(define (accept-loop listener handler)
  (define stop?
    (with-handler (lambda (_) #f)
      (serve-connection (tcp-accept listener) handler)))
  (unless stop?
    (accept-loop listener handler)))

;;;; Binding ;;;;

;; Try to bind one port, returning the listener or #f if it is taken.
(define (try-bind address)
  (with-handler (lambda (_) #f) (tcp-listen address)))

;; Walk upwards from base-port looking for a free one. `tcp-listener-local-addr`
;; exists in steel-core but is not registered in the steel/tcp module, so an
;; ephemeral port cannot be discovered after binding :0; the port has to be
;; chosen here to be recorded in the session file.
(define (bind-walk host base-port remaining)
  (if (<= remaining 0)
    #f
    (let* ([address (string-append host ":" (int->string base-port))]
           [listener (try-bind address)])
      (if listener
        ;; Built with apply: a call of nine or more arguments inside a
        ;; required module corrupts the next call's arguments.
        (apply hash
          (list 'listener listener
            'host
            host
            'port
            base-port))
        (bind-walk host (+ base-port 1) (- remaining 1))))))

;;@doc
;; Bind a loopback port and serve requests on a native thread.
;;
;; ```scheme
;; (start-server host base-port handler)
;; ```
;;
;; * host : string?      - address to bind, normally "127.0.0.1"
;; * base-port : int?    - first port to try
;; * handler : (-> hash? hash?) - takes a request hash of 'token, 'verb and
;;   'args, returns a `make-reply` result
;;
;; Returns a server hash, or #f when every candidate port was taken.
(define (start-server host base-port handler)
  (define server (bind-walk host base-port default-attempts))
  (when server
    (spawn-native-thread (lambda () (accept-loop (hash-ref server 'listener) handler))))
  server)

;;@doc
;; The "host:port" a server is listening on.
(define (server-address server)
  (string-append (hash-ref server 'host) ":" (int->string (hash-ref server 'port))))

;;@doc
;; The port a server is listening on.
(define (server-port server)
  (hash-ref server 'port))

;;@doc
;; The host a server is bound to.
(define (server-host server)
  (hash-ref server 'host))

;;;; Client ;;;;

;;@doc
;; Send a request to a server and close without reading the reply.
;;
;; ```scheme
;; (send-oneway address token verb)
;; ```
;;
;; Used for shutdown, which has to come from the editor's own thread. Nothing
;; is read back: a full request/response round trip between two threads of one
;; process can wedge, where a one-way write cannot.
(define (send-oneway address token verb)
  (define stream (tcp-connect address))
  (define writer (tcp-stream-writer stream))
  (display (string-append token "\n" verb "\n\n") writer)
  (flush-output-port writer))
