#!/usr/bin/env bash
# Regenerate docs/portfolio-demo.pdf from the Markdown source.
# Requires: pandoc, weasyprint, fonts-dejavu (apt-get install -y pandoc weasyprint fonts-dejavu).
set -euo pipefail
cd "$(dirname "$0")/.."
pandoc -s docs/portfolio-demo.md -o docs/portfolio-demo.pdf \
  --pdf-engine=weasyprint \
  --metadata pagetitle="psac: portfolio risk on self-adjusting computation" \
  -H docs/pdf-style.html
echo "wrote docs/portfolio-demo.pdf"
