#!/usr/bin/env bash
# End-to-end: fresh DB, local site + API, real Chrome. Needs: psql on :5433, deno, node + playwright, Chrome.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bash "$here/../tests/run_all.sh" >/dev/null
deno run -A "$here/server.ts" & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 3
# playwright: `npm i -D playwright` in e2e/, or reuse a global install
[ -e "$here/node_modules" ] || ln -s "$(npm root -g)" "$here/node_modules"
node "$here/browser.mjs"
