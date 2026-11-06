#!/usr/bin/env bash
# Static site rules: no secrets, no inline JS/CSS, no unsafe CSP, only allowed third parties.
# Usage: ci/check-site.sh site
set -uo pipefail
S=${1:-site}; fail=0
bad() { echo "FAIL: $*"; fail=1; }

# 1) no server secrets in anything that ships to the browser
if grep -RInE 'sb_secret_|service_role|SUPABASE_SECRET|re_[A-Za-z0-9]{16,}|whsec_|TURNSTILE_SECRET|RESEND_API_KEY|-----BEGIN [A-Z ]*PRIVATE KEY' "$S"; then bad "secret-looking value in $S"; fi

# 2) no inline script, no inline event handlers, no inline styles, no javascript: URLs
grep -RInE '<script(\s[^>]*)?>[^<[:space:]]' "$S" --include='*.html' && bad "inline <script> body"
grep -RInP '<script(?![^>]*\bsrc=)' "$S" --include='*.html' && bad "<script> without src"
grep -RInE '\son[a-z]+\s*=' "$S" --include='*.html' && bad "inline on*= handler"
grep -RInE '\sstyle\s*=|<style' "$S" --include='*.html' && bad "inline style"
grep -RInEi 'javascript:' "$S" && bad "javascript: URL"

# 3) only our own scripts + Turnstile
ext=$(grep -RhoE '<script[^>]*src="https?://[^"]+"' "$S" --include='*.html' | grep -vE 'src="https://challenges\.cloudflare\.com/turnstile/v0/api\.js' || true)
[ -n "$ext" ] && bad "third-party script: $ext"

# 4) DOM XSS sinks in our JS
grep -RInE 'innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(|new Function|setTimeout\(\s*["'\'']' "$S" --include='*.js' && bad "dangerous DOM sink"

# 5) CSP must exist and stay strict
H="$S/_headers"
[ -f "$H" ] || bad "missing _headers"
csp=$(grep -i 'Content-Security-Policy:' "$H" || true)
[ -z "$csp" ] && bad "no CSP"
grep -qiE "unsafe-inline|unsafe-eval|unsafe-hashes|script-src[^;]*\*|default-src[^;]*\*" <<<"$csp" && bad "CSP weakened: $csp"
for d in "default-src 'none'" "frame-ancestors 'none'" "base-uri 'none'" "form-action 'none'"; do grep -q "$d" <<<"$csp" || bad "CSP missing $d"; done
grep -qi 'Strict-Transport-Security' "$H" || bad "no HSTS"

# 6) the consent checkboxes must not be pre-ticked
grep -RInE 'type="checkbox"[^>]*\bchecked\b' "$S" --include='*.html' && bad "pre-ticked consent box"

[ $fail -eq 0 ] && echo "ok   site checks passed"; exit $fail
