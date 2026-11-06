#!/usr/bin/env bash
# Every new migration must keep the waitlist locked down (the SQL tests prove it at runtime).
set -uo pipefail
D=${1:-supabase/migrations}; fail=0
for f in "$D"/*.sql; do
  if grep -qiE 'security definer' "$f" && ! grep -qiE "set search_path *= *''" "$f"; then echo "FAIL: $f SECURITY DEFINER without search_path=''"; fail=1; fi
  if grep -qiE 'grant[^;]*(to|,)\s*(anon|authenticated|public)\b' "$f"; then echo "FAIL: $f grants to a browser role"; fail=1; fi
  if grep -qiE 'disable row level security|no force row level security' "$f"; then echo "FAIL: $f disables RLS"; fail=1; fi
done
[ $fail -eq 0 ] && echo "ok   migration checks passed"; exit $fail
