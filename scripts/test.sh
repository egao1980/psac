#!/usr/bin/env bash
# Run the rove test suite inside the container.
set -euo pipefail
export PATH="$HOME/.roswell/bin:$HOME/.elan/bin:$PATH"
cd "$(dirname "$0")/.."
.qlot/bin/rove psac.asd
