#!/usr/bin/env bash
# Build the Lean model (checks all proofs) and the oracle executable.
set -euo pipefail
export PATH="$HOME/.roswell/bin:$HOME/.elan/bin:$PATH"
cd "$(dirname "$0")/../model"
lake build
