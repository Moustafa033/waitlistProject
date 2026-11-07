#!/usr/bin/env bash
# End-to-end: fresh DB, local site + API, real Chrome. Linux/CI only.
# Needs: psql on :5433, deno, node, Chrome, and Playwright installed LOCALLY in e2e/
# (owner-approved, exact version, lockfile committed: `npm ci --ignore-scripts` in e2e/).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# Never borrow packages from the machine's global npm folder: those versions are not
# pinned, not reviewed and not in any lockfile (supply-chain rule SC-1/SC-2).
if [ ! -d "$here/node_modules/playwright" ]; then
  echo "SKIP e2e: Playwright is not installed in e2e/node_modules (needs owner approval first)."
  exit 2
fi

bash "$here/../tests/run_all.sh" >/dev/null
# the test DB starts at the migration default; set it to the version the page shows (like production)
cv=$(sed -n 's/.*data-consent-version="\([a-z0-9-]*\)".*/\1/p' "$here/../site/index.html")
psql -h "${PGHOST:-/tmp}" -p "${PGPORT:-5433}" -U postgres -d waitlist_test -qc "update private.settings set value = '$cv' where key = 'current_consent_version'"
deno run --allow-net=localhost:8787,localhost:8788 --allow-read="$here/../site" --allow-env=DB --allow-run=psql "$here/server.ts" & SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 3
node "$here/browser.mjs"
