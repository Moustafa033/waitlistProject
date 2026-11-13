#!/usr/bin/env bash
# LIVE check of the deployed site + function (guide §6b). Run after every upload/deploy:
#   bash ci/check-live-site.sh                      (Git Bash on Windows, or any bash with curl)
#   bash ci/check-live-site.sh https://creatinginpublic.com
# Read-only and harmless: it never signs anyone up and never sends an email. Every request it
# makes is refused by the server BEFORE the captcha (wrong origin, extra field, huge body...).
set -uo pipefail
SITE=${1:-https://creatinginpublic.com}
HOST=${SITE#https://}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
API=$(grep -oE 'https://[a-z0-9]+\.supabase\.co/functions/v1/waitlist' "$HERE/site/assets/config.js" | head -1)
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
status() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }
header() { tr -d '\r' | grep -i "^$1:" | head -1 | cut -d' ' -f2-; }

# 1) headers on the real page = exactly what the repo says
H=$(curl -s -D - -o /dev/null --max-time 15 "$SITE/")
want_csp=$(grep -m1 'Content-Security-Policy:' "$HERE/site/_headers" | sed 's/^ *Content-Security-Policy: *//')
[ "$(echo "$H" | header content-security-policy)" = "$want_csp" ] && ok "CSP is live and identical to site/_headers" || bad "CSP missing or different from site/_headers (was .htaccess uploaded?)"
for h in strict-transport-security x-content-type-options x-frame-options referrer-policy permissions-policy cross-origin-opener-policy; do
  [ -n "$(echo "$H" | header $h)" ] && ok "header $h" || bad "header $h missing"
done
echo "$H" | grep -qi '^x-powered-by:' && bad "X-Powered-By leaks the server software" || ok "no X-Powered-By"

# 2) one address only, HTTPS only
c=$(status "http://$HOST/"); [ "$c" = 301 ] || [ "$c" = 302 ] || [ "$c" = 308 ] && ok "http -> https redirect ($c)" || bad "http:// answered $c (turn on Force HTTPS in hPanel)"
loc=$(curl -s -D - -o /dev/null --max-time 15 "https://www.$HOST/" | header location)
case "$loc" in "$SITE"/*|"$SITE") ok "www redirects to $SITE";; *) bad "www.$HOST does not redirect to $SITE (got: ${loc:-nothing})";; esac

# 3) nothing hidden is downloadable
for p in /.htaccess /.git/config /.git/HEAD /.env /_headers /assets/ /.DS_Store /index.html.bak /wp-login.php; do
  c=$(status "$SITE$p"); [ "$c" = 403 ] || [ "$c" = 404 ] && ok "$p -> $c" || bad "$p answered $c (must be 403/404)"
done
c=$(status "$SITE/.well-known/security.txt"); [ "$c" = 200 ] && ok "security.txt is published" || bad "security.txt answered $c"

# 4) the function refuses junk BEFORE doing anything (no signup, no email)
if [ -z "$API" ]; then bad "function URL not found in site/assets/config.js"; else
  J='content-type: application/json'
  c=$(status -X POST "$API/signup" -H "$J" -d '{"email":"a@b.com"}');                                  [ "$c" = 403 ] && ok "signup without Origin -> 403" || bad "signup without Origin answered $c"
  c=$(status -X POST "$API/signup" -H "$J" -H "Origin: https://evil.example" -d '{"email":"a@b.com"}'); [ "$c" = 403 ] && ok "signup from another site -> 403" || bad "signup from another site answered $c"
  c=$(status -X POST "$API/signup" -H "$J" -H "Origin: $SITE" -d '{"email":"<script>@x","status":"confirmed","is_admin":true}'); [[ "$c" =~ ^4 ]] && ok "junk fields / injection text -> $c" || bad "junk body answered $c"
  big=$(mktemp); head -c 300000 /dev/zero | tr '\0' 'a' > "$big"     # a file: a 300 KB argument breaks Git Bash
  c=$(status -X POST "$API/signup" -H "$J" -H "Origin: $SITE" --data-binary "@$big"); rm -f "$big"
  # 413 = refused with an answer; 000 = the platform dropped the upload (also refused, seen on Supabase).
  case "$c" in 413) ok "300 KB body -> 413";; 000) ok "300 KB body -> dropped by the server (refused)";; *) bad "huge body answered $c (expected 413)";; esac
  c=$(status -X POST "$API/signup" -H "content-type: text/plain" -H "Origin: $SITE" -d 'x');            [ "$c" = 415 ] && ok "wrong content type -> 415" || bad "wrong content type answered $c"
  c=$(status -X POST "$API/drain" -H "$J" -H "x-cron-key: wrong");                                       [ "$c" = 404 ] && ok "/drain with a wrong key -> 404" || bad "/drain answered $c"
  acao=$(curl -s -D - -o /dev/null --max-time 15 -X OPTIONS "$API/signup" -H "Origin: https://evil.example" -H "Access-Control-Request-Method: POST" | header access-control-allow-origin)
  [ "$acao" = "$SITE" ] || [ -z "$acao" ] && ok "CORS never allows another site" || bad "CORS allows: $acao"
  c=$(status "$API/count"); [ "$c" = 200 ] && ok "public counter works" || bad "/count answered $c"
fi

echo; echo "Also by hand (once per release): securityheaders.com shows A+; Supabase Advisors -> Security shows 0 errors;"
echo "hPanel Malware Scanner shows clean."
[ $fail -eq 0 ] && echo "ok   live site check passed" || echo "LIVE SITE CHECK FAILED"; exit $fail
