#!/usr/bin/env bash
# Edge Function rules. Usage: ci/check-functions.sh supabase
set -uo pipefail
D=${1:-supabase}; fail=0
bad() { echo "FAIL: $*"; fail=1; }
# verify_jwt=false is allowed ONLY for the two public functions
open=$(awk '/^\[functions\./{f=$0} /verify_jwt *= *false/{print f}' "$D/config.toml" | sort -u | tr '\n' ' ')
[ "$open" = "[functions.email-events] [functions.waitlist] " ] || bad "unexpected public functions: $open"
# no wildcard CORS, no reflected origin, no IP usage (P-1), no logging of emails/tokens
grep -RInE "allow-origin\"?\s*[:,]\s*\"\*\"|allow-origin.*req\.headers\.get\(\"origin\"\)" "$D/functions" && bad "wildcard/reflected CORS"
grep -RInE 'x-forwarded-for|cf-connecting-ip|x-real-ip|remoteip"\s*,' -i "$D/functions" --include='*.ts' | grep -v '^\S*:\s*//' | grep -vi 'deliberately NOT' && bad "IP use (owner policy P-1)"
grep -RInE 'console\.(log|error|warn)\([^)]*[^"a-z_-](email|token|raw|body|req)([^"a-z_-]|$)' "$D/functions" --include='*.ts' | grep -v tests/ && bad "possible personal data in logs"
# legacy keys
grep -RInE 'SUPABASE_SERVICE_ROLE_KEY|SUPABASE_ANON_KEY' "$D/functions" && bad "legacy JWT key usage"
[ $fail -eq 0 ] && echo "ok   function checks passed"; exit $fail
