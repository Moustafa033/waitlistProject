-- =====================================================================
-- 0005 — send-cap safety net
--   * A real person who signs up while a global send cap is full is QUEUED,
--     not silently dropped. A scheduled job sends the queue when room frees up.
--   * Kill switch: settings.sending_paused = 'true' stops every confirmation
--     email at once (signups are still recorded and queued).
--   * Auto-pause: a spike of hard bounces or spam complaints flips the kill
--     switch by itself, so a bot feeding us fake addresses cannot burn the
--     sending domain's reputation overnight.
--   * Owner alerts: the first time a cap trips (per window), the queue fills,
--     or sending pauses, one row is written to private.alerts. The scheduled
--     job emails the owner a summary (counts only, never anyone's address).
-- Every number is an EXAMPLE; the owner decides them in private.settings.
-- Trade-off on auto-pause (written down on purpose): someone who floods fake
-- addresses can pause our confirmation emails. That only DELAYS real people
-- (they wait in the queue) and the owner is alerted; a burned domain takes
-- weeks to recover. Delay beats damage.
-- =====================================================================

insert into private.settings(key, value) values
  ('sending_paused',        'false'), -- kill switch: 'true' = no confirmation emails at all
  ('queue_max',             '2000'),  -- EXAMPLE: most people waiting in the queue at once
  ('queue_ttl_hours',       '48'),    -- EXAMPLE: queued longer than this => dropped (they can sign up again)
  ('drain_batch',           '50'),    -- EXAMPLE: most queued emails sent per scheduled run
  ('bounce_pause_min',      '5'),     -- EXAMPLE: hard bounces in 24 h before the ratio is even looked at
  ('bounce_pause_pct',      '5'),     -- EXAMPLE: pause when hard bounces >= this % of the last 24 h of sends
  ('complaint_pause_min',   '2')      -- EXAMPLE: spam complaints in 24 h that pause sending (Gmail's limit is 0.3%)
on conflict (key) do nothing;

-- ---------------------------------------------------------------- tables
-- Only the signup id is stored (no copy of the address). Deleting or erasing a
-- signup removes its queue entry automatically.
create table private.send_queue (
  signup_id uuid primary key references private.signups(id) on delete cascade,
  queued_at timestamptz not null default now()
);
create index send_queue_order_idx on private.send_queue(queued_at);

-- One row per alert kind per window. hits counts how often it happened.
create table private.alerts (
  kind      text not null check (kind in ('global_send_cap','global_send_day_cap','global_new_cap',
                                          'queue_full','paused_signups','auto_paused')),
  period    timestamptz not null,
  hits      integer not null default 1,
  first_at  timestamptz not null default now(),
  last_at   timestamptz not null default now(),
  notified_at timestamptz,                 -- set when the owner was emailed
  detail    jsonb not null default '{}'::jsonb check (pg_column_size(detail) < 1024),
  primary key (kind, period)
);

alter table private.send_queue enable row level security;
alter table private.send_queue force  row level security;
alter table private.alerts     enable row level security;
alter table private.alerts     force  row level security;
revoke all on private.send_queue from public, anon, authenticated, service_role;
revoke all on private.alerts     from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------- helpers
create or replace function private.is_paused() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select value from private.settings where key = 'sending_paused'), 'false') = 'true'
$$;

-- Records an alert; repeat hits in the same window only bump the counter.
create or replace function private.raise_alert(p_kind text, p_period timestamptz, p_detail jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into private.alerts as a(kind, period, detail) values (p_kind, p_period, p_detail)
  on conflict (kind, period) do update set hits = a.hits + 1, last_at = now()
$$;

-- Puts a PENDING signup in the queue (bounded). Returns true if it is now queued.
create or replace function private.enqueue(p_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from private.send_queue where signup_id = p_id) then return true; end if;
  if (select count(*) from private.send_queue) >= private.cfg_int('queue_max') then
    perform private.raise_alert('queue_full', date_trunc('day', now()));
    return false;
  end if;
  insert into private.send_queue(signup_id) values (p_id) on conflict do nothing;
  return true;
end $$;

-- ---------------------------------------------------------------- signup
-- Re-stated from 0004. New: the kill switch, and queuing when a GLOBAL cap is
-- full. The per-address and per-mailbox limits still refuse WITHOUT queuing:
-- a queue must never become a way around them. Only rows in status 'pending'
-- are queued (an unsubscribed person re-joining during a full cap just tries again).
create or replace function public.waitlist_signup(p_email text, p_consent_version text, p_locale text default null, p_source text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_email text := private.normalize_email(p_email);
  v_row   private.signups%rowtype;
  v_token text;
  v_hour  timestamptz := date_trunc('hour', now());
  v_day   timestamptz := date_trunc('day', now());
  v_mbx   text;
  v_was_unsub boolean;
  v_reason text;
begin
  if not private.email_ok(v_email) then
    return jsonb_build_object('action','none','reason','invalid_email');
  end if;
  if p_consent_version is distinct from private.cfg_text('current_consent_version') then
    return jsonb_build_object('action','none','reason','stale_consent_version');
  end if;
  if p_locale is not null and p_locale !~ '^[a-z]{2}(-[A-Z]{2})?$' then p_locale := null; end if;
  if p_source is not null and p_source !~ '^[a-z0-9_-]{1,32}$' then p_source := null; end if;

  if exists (select 1 from private.suppressions where email_hash = private.email_hash(v_email)) then
    return jsonb_build_object('action','none','reason','suppressed');
  end if;

  select * into v_row from private.signups where email = v_email for update;
  if not found then
    if not private.take('new_day', v_day, private.cfg_int('global_new_per_day')) then
      perform private.raise_alert('global_new_cap', v_day);
      return jsonb_build_object('action','none','reason','global_new_cap');
    end if;
    insert into private.signups(email, locale, source, consent_version)
    values (v_email, p_locale, p_source, p_consent_version)
    on conflict (email) do nothing;
    if not found then
      perform private.give_back('new_day', v_day);
    end if;
    select * into v_row from private.signups where email = v_email for update;
  end if;
  if v_row.status = 'confirmed' then
    return jsonb_build_object('action','none','reason','already_confirmed');
  end if;

  if v_row.confirm_sends >= private.cfg_int('max_confirm_sends') then
    return jsonb_build_object('action','none','reason','address_lifetime_cap');
  end if;
  if v_row.last_confirm_sent_at is not null
     and v_row.last_confirm_sent_at > now() - make_interval(mins => private.cfg_int('resend_min_minutes')) then
    return jsonb_build_object('action','none','reason','address_too_soon');
  end if;

  -- kill switch: record the person, send nothing, queue them for later
  if private.is_paused() then
    perform private.raise_alert('paused_signups', v_day);
    return jsonb_build_object('action','none','reason','paused',
      'queued', case when v_row.status = 'pending' then private.enqueue(v_row.id) else false end);
  end if;

  v_mbx := private.mailbox_bucket(v_email);
  -- the drain only TRIES this lock, so a live signup and the drain never wait on each other in a circle
  perform pg_advisory_xact_lock(hashtextextended(v_mbx, 0));
  if not private.take(v_mbx, v_day, private.cfg_int('mailbox_sends_per_day')) then
    return jsonb_build_object('action','none','reason','mailbox_send_cap');   -- never queued
  end if;
  v_reason := null;
  if not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then
    perform private.give_back(v_mbx, v_day);
    v_reason := 'global_send_cap';
    perform private.raise_alert(v_reason, v_hour);
  elsif not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
    perform private.give_back('send_hour', v_hour);
    perform private.give_back(v_mbx, v_day);
    v_reason := 'global_send_day_cap';
    perform private.raise_alert(v_reason, v_day);
  end if;
  if v_reason is not null then
    return jsonb_build_object('action','none','reason', v_reason,
      'queued', case when v_row.status = 'pending' then private.enqueue(v_row.id) else false end);
  end if;

  v_was_unsub := v_row.status = 'unsubscribed';
  v_token := private.new_token();
  update private.signups set
    status               = case when status = 'unsubscribed' then 'pending' else status end,
    consent_version      = p_consent_version,
    locale               = coalesce(p_locale, locale),
    confirm_token_hash   = private.token_hash(v_token),
    confirm_expires_at   = now() + make_interval(hours => private.cfg_int('confirm_ttl_hours')),
    confirm_sends        = confirm_sends + 1,
    last_confirm_sent_at = now(),
    updated_at           = now()
  where id = v_row.id
  returning * into v_row;
  -- No queue delete here on purpose: the drain locks queue-row then signup-row, so touching the
  -- queue while holding the signup lock could deadlock. The drain drops any entry whose person was
  -- emailed after being queued (last_confirm_sent_at >= queued_at), so nobody gets a second email.

  insert into private.consent_events(signup_id, event, consent_version, detail)
  values (v_row.id, case when v_was_unsub then 'resubscribe_requested' else 'requested' end,
          p_consent_version, jsonb_build_object('source', p_source, 'send_no', v_row.confirm_sends));

  return jsonb_build_object('action','send','token', v_token, 'signup_id', v_row.id,
                            'send_no', v_row.confirm_sends, 'hour', v_hour);
end $$;

-- ---------------------------------------------------------------- drain
-- Called by the scheduled job only. Sends queued people, oldest first, through
-- EXACTLY the same limits as a live signup. Stops at the first full global cap.
-- Returns {"sends":[{email,token,signup_id,send_no,hour}], "left": n, "paused": bool}.
-- (It returns addresses because the job must email them; service_role only.)
create or replace function public.waitlist_drain_queue() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  q       record;
  v_row   private.signups%rowtype;
  v_token text;
  v_hour  timestamptz := date_trunc('hour', now());
  v_day   timestamptz := date_trunc('day', now());
  v_mbx   text;
  v_out   jsonb := '[]'::jsonb;
  v_n     integer := 0;
begin
  -- drop stale entries (the person can simply sign up again)
  delete from private.send_queue where queued_at < now() - make_interval(hours => private.cfg_int('queue_ttl_hours'));

  if not private.is_paused() then
    for q in select signup_id, queued_at from private.send_queue order by queued_at
             for update skip locked loop
      exit when v_n >= private.cfg_int('drain_batch');
      -- Lock rule (proven by tests/race_parallel.sh #4): once this loop holds the global hour/day
      -- counters it must NEVER wait on a per-person lock, or it deadlocks with a live signup that
      -- holds that person's locks and waits for the hour counter. So every per-person lock here is
      -- try-only: if the person is busy right now, skip them; the next run picks them up.
      perform 1 from private.signups where id = q.signup_id;
      if not found then delete from private.send_queue where signup_id = q.signup_id; continue; end if;
      select * into v_row from private.signups where id = q.signup_id for update skip locked;
      if not found then continue; end if;                                    -- busy: next run
      v_mbx := private.mailbox_bucket(v_row.email);
      if not pg_try_advisory_xact_lock(hashtextextended(v_mbx, 0)) then continue; end if;  -- busy: next run
      -- no longer eligible => leave the queue, send nothing
      if v_row.status <> 'pending'
         or v_row.confirm_sends >= private.cfg_int('max_confirm_sends')
         or (v_row.last_confirm_sent_at is not null and v_row.last_confirm_sent_at >= q.queued_at)
         or exists (select 1 from private.suppressions where email_hash = private.email_hash(v_row.email)) then
        delete from private.send_queue where signup_id = q.signup_id;
        continue;
      end if;
      if not private.take(v_mbx, v_day, private.cfg_int('mailbox_sends_per_day')) then
        delete from private.send_queue where signup_id = q.signup_id;   -- same rule as live: not queued
        continue;
      end if;
      if not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then
        perform private.give_back(v_mbx, v_day);
        exit;                                   -- still full: try again next run
      end if;
      if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
        perform private.give_back('send_hour', v_hour);
        perform private.give_back(v_mbx, v_day);
        exit;
      end if;

      v_token := private.new_token();
      update private.signups set
        confirm_token_hash   = private.token_hash(v_token),
        confirm_expires_at   = now() + make_interval(hours => private.cfg_int('confirm_ttl_hours')),
        confirm_sends        = confirm_sends + 1,
        last_confirm_sent_at = now(),
        updated_at           = now()
      where id = v_row.id
      returning * into v_row;
      delete from private.send_queue where signup_id = v_row.id;
      insert into private.consent_events(signup_id, event, consent_version, detail)
      values (v_row.id, 'requested', v_row.consent_version,
              jsonb_build_object('source', 'queue', 'send_no', v_row.confirm_sends));
      v_out := v_out || jsonb_build_object('email', v_row.email, 'token', v_token, 'signup_id', v_row.id,
                                           'send_no', v_row.confirm_sends, 'hour', v_hour);
      v_n := v_n + 1;
    end loop;
  end if;

  return jsonb_build_object('sends', v_out, 'left', (select count(*) from private.send_queue),
                            'paused', private.is_paused());
end $$;

-- ---------------------------------------------------------------- alerts
-- Returns alerts not yet emailed and marks them, in one statement (two job runs
-- at once never email the same alert twice). Counts only, no addresses.
create or replace function public.waitlist_take_alerts() returns jsonb
language sql security definer set search_path = '' as $$
  with t as (
    update private.alerts set notified_at = now()
     where notified_at is null
    returning kind, period, hits, first_at, last_at
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'period', period, 'hits', hits,
                                               'first_at', first_at, 'last_at', last_at) order by first_at), '[]'::jsonb)
  from t
$$;

-- Owner's switch. Turning sending back on is a deliberate act (never automatic).
create or replace function public.waitlist_set_paused(p_paused boolean) returns jsonb
language sql security definer set search_path = '' as $$
  update private.settings set value = case when p_paused then 'true' else 'false' end where key = 'sending_paused';
  select jsonb_build_object('paused', private.is_paused(), 'queued', (select count(*) from private.send_queue));
$$;

-- ---------------------------------------------------------------- auto-pause
-- Re-stated from 0001. New: after recording a hard bounce or complaint, look at
-- the last 24 hours and flip the kill switch if they spiked. Only NEW
-- suppressions count (a repeated webhook for the same address adds nothing).
create or replace function public.waitlist_suppress(p_email text, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_new boolean; v_b integer; v_c integer; v_sent integer;
begin
  if p_reason not in ('hard_bounce','complaint','manual') then raise exception 'bad reason'; end if;
  insert into private.suppressions(email_hash, reason) values (private.email_hash(p_email), p_reason)
  on conflict (email_hash) do nothing;
  v_new := found;
  update private.signups set status = 'unsubscribed', unsubscribed_at = now(),
         confirm_token_hash = null, confirm_expires_at = null, updated_at = now()
  where email = private.normalize_email(p_email) and status <> 'unsubscribed'
  returning id into v_id;
  if v_id is not null then
    insert into private.consent_events(signup_id, event, detail) values (v_id, 'suppressed', jsonb_build_object('reason', p_reason));
  end if;

  if v_new and p_reason in ('hard_bounce','complaint') and not private.is_paused() then
    select count(*) filter (where reason = 'hard_bounce'), count(*) filter (where reason = 'complaint')
      into v_b, v_c
      from private.suppressions where at > now() - interval '24 hours';
    select coalesce(sum(used), 0) into v_sent
      from private.counters where bucket = 'send_hour' and period > now() - interval '24 hours';
    if v_c >= private.cfg_int('complaint_pause_min')
       or (v_b >= private.cfg_int('bounce_pause_min')
           and v_b * 100 >= private.cfg_int('bounce_pause_pct') * greatest(v_sent, 1)) then
      update private.settings set value = 'true' where key = 'sending_paused';
      perform private.raise_alert('auto_paused', date_trunc('day', now()),
        jsonb_build_object('bounces_24h', v_b, 'complaints_24h', v_c, 'sent_24h', v_sent));
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------- maintenance
-- Re-stated from 0001: also forgets alerts older than 30 days.
create or replace function public.waitlist_maintenance() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a integer; b integer; c integer; d integer;
begin
  delete from private.signups
   where status = 'pending'
     and coalesce(last_confirm_sent_at, created_at) < now() - make_interval(days => private.cfg_int('pending_retention_days'));
  get diagnostics a = row_count;
  delete from private.signups
   where status = 'unsubscribed' and coalesce(unsubscribed_at, updated_at) < now() - make_interval(days => private.cfg_int('unsub_retention_days'));
  get diagnostics b = row_count;
  delete from private.counters where period < now() - interval '3 days';
  get diagnostics c = row_count;
  delete from private.alerts where first_at < now() - interval '30 days';
  get diagnostics d = row_count;
  return jsonb_build_object('pending_deleted', a, 'unsubscribed_deleted', b, 'counters_deleted', c, 'alerts_deleted', d);
end $$;

-- ---------------------------------------------------------------- privileges
-- Explicit for every function this file creates (0001's one-time revoke ran before they existed).
revoke all on function private.is_paused()                       from public, anon, authenticated;
revoke all on function private.raise_alert(text, timestamptz, jsonb) from public, anon, authenticated;
revoke all on function private.enqueue(uuid)                     from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array[
    'public.waitlist_signup(text,text,text,text)', 'public.waitlist_drain_queue()',
    'public.waitlist_take_alerts()', 'public.waitlist_set_paused(boolean)',
    'public.waitlist_suppress(text,text)', 'public.waitlist_maintenance()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
