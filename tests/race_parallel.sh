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

# 4) queue drain under fire: 30 people queued, then 10 drain jobs AND 30 re-signups of the same
#    people all at once -> everyone gets exactly ONE email, nothing deadlocks, queue ends empty.
$PG -c "update private.settings set value='0' where key='global_sends_per_hour'; update private.settings set value='30' where key='resend_min_minutes'; delete from private.counters; delete from private.send_queue;" >/dev/null
for i in $(seq 1 30); do $PG -c "set role service_role; select public.waitlist_signup('drain-$i@example.com','waitlist-v1')" >/dev/null; done
check "$($PG -c "select count(*) from private.send_queue")" 30 "30 people queued while the cap is 0"
$PG -c "update private.settings set value='500' where key='global_sends_per_hour'" >/dev/null
res=$(race 40 "select case when :i <= 10 then (select jsonb_array_length(public.waitlist_drain_queue()->'sends'))::text
                           else public.waitlist_signup('drain-' || (:i - 10) || '@example.com','waitlist-v1')->>'action' end")
if grep -qi "deadlock\|ERROR" <<<"$res"; then echo "FAIL: drain race raised an error"; echo "$res" | grep -i error | head -3; exit 1; fi
echo "ok   10 drains + 30 re-signups at once -> no deadlock, no error"
check "$($PG -c "select count(*) from private.signups where email like 'drain-%' and confirm_sends <> 1")" 0 "every queued person got exactly ONE email"
$PG -c "set role service_role; select public.waitlist_drain_queue()" >/dev/null
check "$($PG -c "select count(*) from private.send_queue")" 0 "queue is empty after one more drain"

# 0006) partner applications under real concurrency
$PG -c "update private.settings set value='20' where key='partner_per_day'; update private.settings set value='500' where key='global_sends_per_hour'; update private.settings set value='100000' where key='global_sends_per_day'; delete from private.counters; delete from private.partner_applications;" >/dev/null
P="'Sara Ali', '[{\"platform\":\"tiktok\",\"username\":\"sara\"}]'::jsonb, 'Personal trainer, 2 reviews a month.', 'partners-v1'"
res=$(race 30 "select public.waitlist_partner_apply('one-victim@example.com', $P)->>'action'")
check "$(grep -c '^send$' <<<"$res" || true)" 1 "30 simultaneous applications from ONE address -> exactly 1 accepted"
check "$($PG -c "select count(*) from private.partner_applications where email='one-victim@example.com'")" 1 "exactly one stored application"
check "$($PG -c "select used from private.counters where bucket='send_hour'")" 1 "exactly 1 email's worth of send units (the confirmation link)"
$PG -c "delete from private.counters where bucket='partner_day'" >/dev/null
res=$(race 40 "select public.waitlist_partner_apply('many-:i@example.com', $P)->>'action'")
check "$(grep -c '^send$' <<<"$res" || true)" 20 "40 simultaneous different addresses vs daily cap 20 -> exactly 20"
check "$($PG -c "select count(*) from private.partner_applications where email like 'many-%'")" 20 "exactly 20 stored"

# 0007) 10 drain runs at the same time on a queue of 30 -> every application sent exactly once
$PG -c "update private.settings set value='0' where key='global_sends_per_hour'; update private.settings set value='100' where key='partner_per_day'; delete from private.counters; delete from private.partner_mail_queue; delete from private.partner_applications;" >/dev/null
for i in $(seq 1 30); do $PG -c "set role service_role; select public.waitlist_partner_apply('pq-$i@example.com', $P)" >/dev/null; done
check "$($PG -c "select count(*) from private.partner_mail_queue")" 30 "30 partner applications queued while the cap is 0"
$PG -c "update private.settings set value='500' where key='global_sends_per_hour'; update private.settings set value='50' where key='drain_batch'" >/dev/null
res=$(race 10 "select e->>'id' from jsonb_array_elements(public.waitlist_drain_partner_queue()->'sends') e")
if grep -qi "deadlock\|ERROR" <<<"$res"; then echo "FAIL: partner drain race raised an error"; exit 1; fi
check "$(grep -cE '^[0-9a-f-]{36}$' <<<"$res" || true)" 30 "10 simultaneous drains -> 30 sends in total"
check "$(grep -E '^[0-9a-f-]{36}$' <<<"$res" | sort -u | wc -l | tr -d ' ')" 30 "no application sent twice"
check "$($PG -c "select count(*) from private.partner_mail_queue")" 0 "partner queue empty"

# 0008 / audit #11) "Delete my data" and a bounce webhook for the SAME address at the same moment,
# 20 addresses x 2 sessions: before 0008 the two took their locks in opposite order (deadlock risk).
$PG -c "delete from private.suppressions; delete from private.counters; update private.settings set value='500' where key='global_sends_per_hour'; update private.settings set value='100000' where key='global_sends_per_day'; update private.settings set value='100' where key='mailbox_sends_per_day';" >/dev/null
for i in $(seq 1 20); do $PG -c "set role service_role; select public.waitlist_signup('dl-$i@example.com', 'waitlist-v1')" >/dev/null; done
$PG -c "create table if not exists public.race_tok as select id, email, public.waitlist_unsub_token(id) tok from private.signups where email like 'dl-%'; grant select on public.race_tok to service_role;" >/dev/null
res=$(race 40 "select case when :i % 2 = 0
  then (select (public.waitlist_erase_by_token(id, tok)->>'ok') from public.race_tok where email = 'dl-' || (:i / 2) || '@example.com')
  else (select public.waitlist_suppress('dl-' || ((:i + 1) / 2) || '@example.com', 'hard_bounce')::text) end")
if grep -qi "deadlock\|ERROR" <<<"$res"; then echo "FAIL: erase vs suppress raised an error"; grep -i error <<<"$res" | head -3; exit 1; fi
echo "ok   20 x (delete-my-data + bounce webhook) at the same moment -> no deadlock, no error"
check "$($PG -c "select count(*) from private.signups where email like 'dl-%'")" 0 "every signup erased"
check "$($PG -c "select count(*) from private.suppressions")" 20 "every address on the do-not-email list exactly once"
$PG -c "drop table public.race_tok" >/dev/null

# 0009) 20 clicks on the same "Confirm application" link at the same moment -> confirmed exactly once
$PG -c "delete from private.counters; delete from private.partner_mail_queue; delete from private.partner_applications; delete from private.suppressions; update private.settings set value='100' where key='mailbox_sends_per_day'; update private.settings set value='false' where key='sending_paused';" >/dev/null
PT=$($PG -c "set role service_role; select public.waitlist_partner_apply('click-race@example.com', $P)->>'token'" | tail -1)
res=$(race 20 "select public.waitlist_partner_confirm('$PT')->>'ok'")
check "$(grep -c '^true$' <<<"$res" || true)" 1 "20 simultaneous confirm clicks -> exactly 1 confirmation (one owner notice)"

# 0009 / re-check R3) mixed traffic on ONE inbox at the same moment: partner applies (+tags), waitlist
# signups (+tags), the waitlist drain and the partner drain. Before 0009's lock order these could deadlock.
$PG -c "delete from private.counters; delete from private.partner_mail_queue; delete from private.partner_applications; delete from private.send_queue; delete from private.suppressions; update private.settings set value='false' where key='sending_paused'; update private.settings set value='100' where key='mailbox_sends_per_day'; update private.settings set value='0' where key='resend_min_minutes'; update private.settings set value='100' where key='partner_per_day';" >/dev/null
res=$(race 40 "select case :i % 4
  when 0 then public.waitlist_partner_apply('mixed+p' || :i || '@example.com', $P)->>'action'
  when 1 then public.waitlist_signup('mixed+w' || :i || '@example.com', 'waitlist-v1')->>'action'
  when 2 then (public.waitlist_drain_queue()->>'left')
  else (public.waitlist_drain_partner_queue()->>'left') end")
if grep -qi "deadlock\|ERROR" <<<"$res"; then echo "FAIL: mixed partner/waitlist traffic raised an error"; grep -i "error\|deadlock" <<<"$res" | head -3; exit 1; fi
echo "ok   40 mixed partner/waitlist requests + both drains on one inbox at once -> no deadlock, no error"
$PG -c "update private.settings set value='30' where key='resend_min_minutes'" >/dev/null

# re-check 2 #4) a POPULATED partner queue: 20 live re-applications of queued applications and 20 drains
# at the same moment. The live path removes queue entries without waiting (skip locked), so no deadlock.
$PG -c "delete from private.counters; delete from private.partner_mail_queue; delete from private.partner_applications; update private.settings set value='0' where key='global_sends_per_hour'; update private.settings set value='0' where key='resend_min_minutes'; update private.settings set value='false' where key='sending_paused';" >/dev/null
for i in $(seq 1 20); do $PG -c "set role service_role; select public.waitlist_partner_apply('busyq-$i@example.com', $P)" >/dev/null; done
check "$($PG -c "select count(*) from private.partner_mail_queue")" 20 "20 applications waiting in the queue"
$PG -c "update private.settings set value='500' where key='global_sends_per_hour'" >/dev/null
res=$(race 40 "select case when :i % 2 = 0
  then public.waitlist_partner_apply('busyq-' || (:i / 2) || '@example.com', $P)->>'action'
  else (public.waitlist_drain_partner_queue()->>'left') end")
if grep -qi "deadlock\|ERROR" <<<"$res"; then echo "FAIL: live sends vs drains on a populated queue raised an error"; grep -i "error\|deadlock" <<<"$res" | head -3; exit 1; fi
echo "ok   20 live re-applications + 20 drains on a populated queue at once -> no deadlock, no error"
check "$($PG -c "select count(*) from private.partner_applications where email like 'busyq-%' and confirm_sends > 2")" 0 "nobody got more than 2 links from the race"
$PG -c "update private.settings set value='30' where key='resend_min_minutes'" >/dev/null

# re-check 3 #4) waitlist: live re-signups, requeues and drains for the SAME 20 people at the same moment.
# Requeue now locks the signup row before the queue insert, like a live signup, so no deadlock.
$PG -c "delete from private.counters; delete from private.send_queue; delete from private.suppressions; update private.settings set value='0' where key='resend_min_minutes'; update private.settings set value='100' where key='max_confirm_sends'; update private.settings set value='100' where key='mailbox_sends_per_day'; update private.settings set value='500' where key='global_sends_per_hour'; update private.settings set value='false' where key='sending_paused';" >/dev/null
$PG -c "drop table if exists public.race_lk; create table public.race_lk(n int primary key, id uuid, tok text); grant select on public.race_lk to service_role;" >/dev/null
for i in $(seq 1 20); do $PG -c "set role service_role; create temp table x as select public.waitlist_signup('lk-$i@example.com','waitlist-v1') j; reset role; insert into public.race_lk select $i, (j->>'signup_id')::uuid, j->>'token' from x;" >/dev/null; done
res=$(race 60 "select case :i % 3
  when 0 then public.waitlist_signup('lk-' || (:i / 3) || '@example.com', 'waitlist-v1')->>'action'
  when 1 then (select public.waitlist_signup_requeue(id, tok)::text from public.race_lk where n = (:i + 2) / 3)
  else (public.waitlist_drain_queue()->>'left') end")
if grep -qi "deadlock\|ERROR" <<<"$res"; then echo "FAIL: waitlist signup/requeue/drain raised an error"; grep -i "error\|deadlock" <<<"$res" | head -3; exit 1; fi
echo "ok   20 live re-signups + 20 requeues + 20 drains for the same people at once -> no deadlock, no error"
$PG -c "drop table public.race_lk; update private.settings set value='30' where key='resend_min_minutes'; update private.settings set value='3' where key='max_confirm_sends'" >/dev/null
