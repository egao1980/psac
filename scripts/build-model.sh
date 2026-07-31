#!/usr/bin/env bash
# Build the Lean model (checks all proofs) and the oracle executable.
set -euo pipefail
cd "$(dirname "$0")/../model"
lake build
