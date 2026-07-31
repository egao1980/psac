#!/usr/bin/env bash
# Run the rove test suite inside the container.
set -euo pipefail
cd "$(dirname "$0")/.."
qlot exec ros \
  -e '(push (uiop:getcwd) asdf:*central-registry*)' \
  -e '(ql:quickload :psac/tests :silent t)' \
  -e '(unless (rove:run :psac/tests) (uiop:quit 1))' \
  -q
