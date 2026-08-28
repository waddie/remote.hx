# remote.hx

Drive a running Helix from another process. Opens a loopback TCP port and runs
editor commands sent to it.

```sh
hx-send open ~/notes/todo.md
hx-send goto 120
hx-send --session work open src/main.rs
```

## Install

```sh
forge pkg install --git https://github.com/waddie/remote.hx
```

In `~/.config/helix/init.scm`:

```scheme
(require "remote.hx/remote.scm")
```

Then `:remote-start` in the editor, or call `(remote-start)` from `init.scm` to
start it with Helix. Put `bin/hx-send` on your `PATH`.

## Commands

| Command                   | Effect                                                                               |
| ------------------------- | ------------------------------------------------------------------------------------ |
| `:remote-start [session]` | Start listening. The session name defaults to the basename of the working directory. |
| `:remote-stop`            | Stop listening and remove the session file.                                          |
| `:remote-status`          | Show the session name, address and session file path.                                |
| `:remote-list`            | List live sessions, deleting any that no longer answer.                              |

## The client

`hx-send <command> [args...]` sends one Helix typable command, without the
leading colon. Arguments are passed through as they are, so paths may contain
spaces with no quoting rules.

```sh
hx-send open "/tmp/a file with spaces.txt"
hx-send --list                  # every session, live or stale
hx-send --ping                  # confirm which editor you are talking to
hx-send --eval '(+ 1 2)'        # only if eval is enabled, see below
hx-send --session work open Cargo.toml
```

It finds the editor in this order:

1. `--session NAME`.
2. `$HELIX_REMOTE` and `$HELIX_REMOTE_TOKEN`, which the editor exports into
   every process it spawns. Anything run from inside Helix therefore talks to
   that Helix with no lookup at all.
3. The session whose recorded working directory is the current one.
4. If several match, whichever of them still answers; if more than one does,
   it lists them and asks for `--session`.

A refused or failed command exits non-zero, so scripts can branch on it.

Exactly one command per invocation. Chain with `&&`:

```sh
hx-send open src/main.rs && hx-send goto 120
```

## What can be run

Only the commands in the table in `remote.scm`, and never those on the deny
list (`write`, the other writing commands, and `run-shell-command`). Anything
else is refused with `error unknown command`.

To allow another command, add it to `command-entries` in `remote.scm`.

`eval`, which evaluates arbitrary Steel against the editor, is off by default;
it hands any local process the whole engine. Turn it on before starting:

```scheme
(set-box! *eval-enabled* #t)
```

## Session files

One file per editor, in `$XDG_RUNTIME_DIR/helix-remote` where that is set,
otherwise a private directory under `$TMPDIR`. `$HELIX_REMOTE_DIR` overrides
both. The directory is 0700 and each file 0600:

```
session=work
host=127.0.0.1
port=7979
token=...
cwd=/home/you/project
```

Several editors coexist: each takes the first free port from 7979 upwards and
writes its own file. Files left behind by an editor that has gone are cleared
by `:remote-list`, and skipped by the client.

## Protocol

One field per line, terminated by a blank line. The reply is a single line,
beginning with `error` if the request was refused.

```
<token>
<verb>
<arg>...
<blank line>
```

Verbs are `cmd` (run a command named by the first argument), `eval`, `ping` and
`shutdown`.

## Limitations

- Connections are served one at a time, and Steel offers no socket read
  timeout, so a client that connects and sends nothing blocks the channel until
  it goes away. Requests queue meanwhile and are answered afterwards.
- A command that raises inside the editor still returns its error, but the
  connection stays open until Steel collects it. `hx-send` bounds that wait
  (`HX_SEND_TIMEOUT`, five seconds by default).
- The token is sent as plain text over loopback, as Emacs' is.

## Tests

```sh
./run-tests.sh          # policy and session files, needs the steel-test cog
./tests/integration.sh  # a real server driven over a socket
```

The suite never drives a socket from the process that serves it: a client and
server sharing one Steel runtime can deadlock on a request/response round trip.

## License

AGPL-3.0-or-later

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.
