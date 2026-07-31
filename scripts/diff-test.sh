#!/usr/bin/env bash
# Differential harness: CL runtime (incremental) vs Lean oracle (from-scratch + checked propagate).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p out
(cd model && lake build oracle)

status=0
for sc in scenarios/*.json; do
  name=$(basename "$sc" .json)
  qlot exec ros \
    -e '(push (uiop:getcwd) asdf:*central-registry*)' \
    -e '(ql:quickload :psac :silent t)' \
    -e "(psac:run-scenario \"$sc\" :output-path \"out/cl-$name.json\")" \
    -q
  ./model/.lake/build/bin/oracle "$sc" > "out/lean-$name.json"
  if diff -u "out/cl-$name.json" "out/lean-$name.json" > /dev/null; then
    echo "OK: $name"
  else
    echo "MISMATCH: $name"
    diff -u "out/cl-$name.json" "out/lean-$name.json" || true
    status=1
  fi
done
exit $status
