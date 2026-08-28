#!/bin/sh
# Run the Scheme test suite. Exits non-zero if any test fails.
#
# The suite covers the pure layers: request policy and session files. The
# socket path is checked by tests/integration.sh, which drives a real server
# from a separate process, because an in-process client and server sharing one
# Steel runtime can deadlock on a request/response round trip.
set -e
cd "$(dirname "$0")"

if [ ! -f "${STEEL_HOME:-$HOME/.steel}/cogs/steel-test/test.scm" ]; then
  echo "run-tests.sh: steel-test is not installed in ${STEEL_HOME:-$HOME/.steel}/cogs." >&2
  echo "  install it with: forge pkg install --git https://github.com/waddie/steel-test" >&2
  exit 1
fi

# The discovery tests write real session files; keep them out of the user's
# runtime directory.
HELIX_REMOTE_DIR=$(mktemp -d)
export HELIX_REMOTE_DIR
trap 'rm -rf "$HELIX_REMOTE_DIR"' EXIT

steel tests/run-tests.scm
