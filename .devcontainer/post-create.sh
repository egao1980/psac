#!/usr/bin/env bash
# Post-create: Lean toolchain (elan, pinned by model/lean-toolchain) + CL deps (qlot) + ASDF registration.
set -euo pipefail

# --- Lean via elan ---
if [ ! -x "$HOME/.elan/bin/elan" ]; then
  curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --default-toolchain none
fi
export PATH="$HOME/.elan/bin:$PATH"
(cd model && elan toolchain install "$(cat lean-toolchain)")

# --- Common Lisp deps ---
qlot install

# --- ASDF source registry for this project ---
mkdir -p "$HOME/.config/common-lisp/source-registry.conf.d"
echo "(:tree \"$PWD/\")" > "$HOME/.config/common-lisp/source-registry.conf.d/50-psac.conf"

echo "post-create done: $(elan --version); qlot ok"
