#!/usr/bin/env bash
# Fails if any tracked text file contains invisible / bidi-control characters ("Trojan Source",
# poisoned AGENTS.md/CLAUDE.md, gym guide SC-3). Write such characters as \u escapes in code.
# Usage: ci/check-hidden-unicode.sh .
set -uo pipefail
D=${1:-.}
export LC_ALL=C.UTF-8
pattern='[\x{00AD}\x{061C}\x{180E}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}\x{E0000}-\x{E007F}]'
# *.woff2 / *.png = binary files (compressed bytes, not text: fonts verified against upstream, icons rendered by us)
hits=$(grep -rlP --exclude-dir=.git --exclude-dir=node_modules --exclude='*.woff2' --exclude='*.png' "$pattern" "$D"); rc=$?
# grep: 0 = found, 1 = nothing found, 2 = error (e.g. no UTF-8 locale). An error must FAIL, never pass.
if [ $rc -ge 2 ]; then echo "FAIL: grep could not scan (exit $rc)"; exit 1; fi
if [ -n "$hits" ]; then
  echo "FAIL: hidden/bidi Unicode characters in:"; echo "$hits"; exit 1
fi
echo "ok   no hidden Unicode characters"
