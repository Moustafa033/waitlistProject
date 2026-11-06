#!/usr/bin/env bash
# Real concurrency: many sessions released at the same instant by an advisory-lock barrier.
set -euo pipefail
PG="psql -h ${PGHOST:-/tmp} -p ${PGPORT:-5433} -U postgres -d $DB -v ON_ERROR_STOP=1 -qAt"
race() {  # race <n> <sql per worker; :i is replaced by the worker number>
  local n=$1 sql=$2 out; out=$(mktemp -d)
  ($PG -c "select pg_advisory_lock(4343); select pg_sleep(2);" >/dev/null) &
  sleep 0.5
  for i in $(seq 1 "$n"); do
    ($PG -c "select pg_advisory_lock_shared(4343);" -c "set role service_role;" -c "${sql//:i/$i}" > "$out/$i" 2>&1) &
  done
  wait; cat "$out"/*; rm -rf "$out"
}
check() { if [ "$1" = "$2" ]; then echo "ok   $3 (got $1)"; else echo "FAIL: $3 expected $2 got $1"; exit 1; fi; }

# 1) 50 parallel signups of ONE victim address -> exactly one email
res=$(race 50 "select public.waitlist_signup('victim@example.com','waitlist-v1')->>'action'")
check "$(grep -c '^send$' <<<"$res" || true)" 1 "50 simultaneous signups of one address -> exactly 1 email"
check "$($PG -c "select count(*) from private.signups where email='victim@example.com'")" 1 "exactly one row"

# 2) 40 different addresses vs a global hourly cap of 15
$PG -c "update private.settings set value='15' where key='global_sends_per_hour'; delete from private.counters where bucket='send_hour';" >/dev/null
res=$(race 40 "select public.waitlist_signup('bulk-:i@example.com','waitlist-v1')->>'action'")
check "$(grep -c '^send$' <<<"$res" || true)" 15 "40 simultaneous addresses vs hourly cap 15 -> exactly 15 emails"
$PG -c "update private.settings set value='500' where key='global_sends_per_hour'" >/dev/null

# 3) 20 parallel clicks on the same confirmation link -> exactly one confirmation event
$PG -c "update private.signups set last_confirm_sent_at = now() - interval '2 hours' where email='victim@example.com'" >/dev/null
TOK=$($PG -c "set role service_role; select public.waitlist_signup('victim@example.com','waitlist-v1')->>'token'" | tail -1)
res=$(race 20 "select public.waitlist_confirm('$TOK')->>'ok'")
check "$(grep -c '^true$' <<<"$res" || true)" 1 "20 simultaneous clicks -> confirmed exactly once"
check "$($PG -c "select count(*) from private.consent_events e join private.signups s on s.id=e.signup_id where s.email='victim@example.com' and e.event='confirmed'")" 1 "exactly one consent 'confirmed' event"
