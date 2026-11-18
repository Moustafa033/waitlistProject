-- =====================================================================
-- 0009 — partner applications need a confirmed email (Codex audit #1, owner decision 2026-11-18)
--   Before: anyone could apply with someone else's address, use up that address's one
--   application, and the owner received the fake details.
--   Now:
--   * A new application is stored as PENDING and the applicant gets ONE fixed email
--     with a "Confirm application" button (token in the URL fragment, like the waitlist).
--   * Only a confirmed application uses the "one per address" slot, and only then is
--     the owner notified (1 email). The confirm page says "received".
--   * A pending application never blocks the real person: applying again replaces the
--     details, KILLS the old link at once and sends a new one (bounded: resend_min_minutes
--     between links, partner_max_confirm_sends per address). Unconfirmed applications are
--     deleted after partner_confirm_ttl_hours, queued or not.
--   * The queue (0007) holds either kind of email; the row's status decides which:
--     pending -> confirmation link (fresh token at send time), confirmed -> owner notice.
--   Hardening from the Codex re-check (reviews/codex-recheck.md):
--   R1 a link approves ONLY the details it was issued for (replacing details clears the token)
--   R2 rows from before 0009 were never confirmed, so they are NOT treated as confirmed
--   R3 one lock order: application row -> mailbox advisory lock -> mailbox counter -> global
--      counters -> queue admission; the drain only TRIES row and mailbox locks
--   R4 a live send removes any older queue entry of the same application
--   R5 the mailbox allowance is charged on the day the email actually goes out
--   R6 a confirmed application whose owner notice cannot be queued raises 'queue_full'
--   R7 the 48 h deadline holds in the drain and in cleanup; a send that never reached the
--      provider does not use up one of the 3 links
--   #2 waitlist_send_allowed(): the worker re-checks pause + do-not-email right before each send
-- Every number is an EXAMPLE; the owner decides them in private.settings.
-- =====================================================================

insert into private.settings(key, value) values
  ('partner_confirm_ttl_hours', '48'),  -- EXAMPLE: confirmation link lifetime; unconfirmed rows deleted after this
  ('partner_max_confirm_sends', '3')    -- EXAMPLE: confirmation emails per pending application
on conflict (key) do nothing;

-- R2: rows written before this migration never proved mailbox ownership. They become pending
-- with no link (they can never be confirmed) and are deleted by the next maintenance run once
-- 48 h old. Nothing is sent for them; the owner already received their notices.
alter table private.partner_applications
  add column status               text not null default 'pending' check (status in ('pending','confirmed')),
  add column confirm_token_hash   bytea,
  add column confirm_expires_at   timestamptz,
  add column confirm_sends        integer not null default 0,
  add column last_confirm_sent_at timestamptz,
  add column confirmed_at         timestamptz;
update private.partner_applications set confirm_sends = 1000000;   -- legacy: no new link, ever
delete from private.partner_mail_queue;                             -- legacy queue entries: nothing to send
alter table private.partner_applications add constraint partner_confirmed_has_time
  check (status <> 'confirmed' or confirmed_at is not null);
create unique index partner_applications_token_idx on private.partner_applications(confirm_token_hash)
  where confirm_token_hash is not null;

-- ---------------------------------------------------------------- R6 queue_full alert for partners
-- (the alert kind already exists; this only documents that confirmations use it too)

-- ---------------------------------------------------------------- apply
-- Returns
--   {"action":"send","kind":"confirm","id","token","send_no","hour"}  -> the function emails the link
--   {"action":"saved","reason","queued"}                             -> stored, link sent later by the queue
--   {"action":"none","reason"}                                       -> nothing stored, nothing sent
create or replace function public.waitlist_partner_apply(
  p_email text, p_name text, p_handles jsonb, p_pitch text, p_consent_version text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_email text := private.normalize_email(p_email);
  v_hour  timestamptz := date_trunc('hour', now());
  v_day   timestamptz := date_trunc('day', now());
  v_mbx   text;
  v_row   private.partner_applications%rowtype;
  v_token text;
  v_q     boolean;
begin
  if not private.email_ok(v_email) then return jsonb_build_object('action','none','reason','invalid_email'); end if;
  if p_consent_version is distinct from private.cfg_text('partner_consent_version') then
    return jsonb_build_object('action','none','reason','stale_consent_version');
  end if;
  if not (private.partner_name_ok(p_name) and private.partner_handles_ok(p_handles) and private.partner_pitch_ok(p_pitch)) then
    return jsonb_build_object('action','none','reason','invalid_fields');
  end if;
  -- a full day is "busy" for everybody, whatever the address (audit #5)
  if coalesce((select used from private.counters where bucket = 'partner_day' and period = v_day), 0)
     >= private.cfg_int('partner_per_day') then
    return jsonb_build_object('action','none','reason','busy');
  end if;
  if exists (select 1 from private.suppressions where email_hash = private.email_hash(v_email)) then
    return jsonb_build_object('action','none','reason','suppressed');
  end if;

  select * into v_row from private.partner_applications where email = v_email for update;   -- R3: row first
  if found then
    if v_row.status = 'confirmed' then
      return jsonb_build_object('action','none','reason','already_applied');
    end if;
    if v_row.confirm_sends >= private.cfg_int('partner_max_confirm_sends') then
      return jsonb_build_object('action','none','reason','address_cap');
    end if;
    if v_row.last_confirm_sent_at is not null
       and v_row.last_confirm_sent_at > now() - make_interval(mins => private.cfg_int('resend_min_minutes')) then
      return jsonb_build_object('action','none','reason','too_soon');
    end if;
  end if;

  -- one inbox (all its +tag variants) gets at most mailbox_sends_per_day emails from us per day (audit #3).
  -- R3: the same advisory lock as waitlist_signup, so the waitlist drain (try-lock) skips this inbox.
  v_mbx := private.mailbox_bucket(v_email);
  perform pg_advisory_xact_lock(hashtextextended(v_mbx, 0));
  if not private.take(v_mbx, v_day, private.cfg_int('mailbox_sends_per_day')) then
    return jsonb_build_object('action','none','reason','mailbox_cap');
  end if;

  if v_row.id is null then
    if not private.take('partner_day', v_day, private.cfg_int('partner_per_day')) then
      perform private.give_back(v_mbx, v_day);
      return jsonb_build_object('action','none','reason','busy');
    end if;
    insert into private.partner_applications(email, name, handles, pitch, consent_version, status)
    values (v_email, p_name, p_handles, p_pitch, p_consent_version, 'pending')
    on conflict (email) do nothing
    returning * into v_row;
    if v_row.id is null then                         -- same address in a parallel request
      perform private.give_back('partner_day', v_day);
      perform private.give_back(v_mbx, v_day);
      return jsonb_build_object('action','none','reason','already_applied');
    end if;
  else
    -- R1: new details => the old link must never approve them. Kill it now, in every branch below.
    update private.partner_applications
       set name = p_name, handles = p_handles, pitch = p_pitch, consent_version = p_consent_version,
           confirm_token_hash = null, confirm_expires_at = null
     where id = v_row.id;
  end if;

  -- the confirmation email: 1 unit of the shared hourly and daily caps
  if private.is_paused()
     or not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then
    perform private.give_back(v_mbx, v_day);           -- R5: charged again on the day it really goes out
    perform private.raise_alert('partner_mail_skipped', v_day);
    v_q := private.partner_enqueue(v_row.id);
    if not v_q then perform private.raise_alert('queue_full', v_day); end if;
    return jsonb_build_object('action','saved','reason','queued','queued', v_q);
  end if;
  if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
    perform private.give_back('send_hour', v_hour);
    perform private.give_back(v_mbx, v_day);
    perform private.raise_alert('partner_mail_skipped', v_day);
    v_q := private.partner_enqueue(v_row.id);
    if not v_q then perform private.raise_alert('queue_full', v_day); end if;
    return jsonb_build_object('action','saved','reason','queued','queued', v_q);
  end if;

  v_token := private.new_token();
  update private.partner_applications set
    confirm_token_hash   = private.token_hash(v_token),
    confirm_expires_at   = now() + make_interval(hours => private.cfg_int('partner_confirm_ttl_hours')),
    confirm_sends        = confirm_sends + 1,
    last_confirm_sent_at = now()
  where id = v_row.id
  returning * into v_row;
  delete from private.partner_mail_queue where application_id = v_row.id;   -- R4: the live send supersedes it
  return jsonb_build_object('action','send','kind','confirm','id',v_row.id,'token',v_token,
                            'send_no',v_row.confirm_sends,'hour',v_hour);
end $$;

-- ---------------------------------------------------------------- confirm
-- Called by the function when a person presses "Confirm application" (POST, Turnstile).
-- Single-use: the token is cleared. Returns {"ok":false} for anything invalid, expired,
-- used or suppressed (the same answer for all). On success the owner notice is due:
--   {"ok":true,"action":"send","id","hour","email","name","handles","pitch"}  or
--   {"ok":true,"action":"queued"}  (send cap full / paused: the queue sends it later)
create or replace function public.waitlist_partner_confirm(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  a      private.partner_applications%rowtype;
  v_hour timestamptz := date_trunc('hour', now());
  v_day  timestamptz := date_trunc('day', now());
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then return jsonb_build_object('ok', false); end if;
  select * into a from private.partner_applications
   where confirm_token_hash = private.token_hash(p_token) and status = 'pending'
   for update;
  if not found or a.confirm_expires_at is null or a.confirm_expires_at < now() then
    return jsonb_build_object('ok', false);
  end if;
  if exists (select 1 from private.suppressions where email_hash = private.email_hash(a.email)) then
    return jsonb_build_object('ok', false);
  end if;
  update private.partner_applications
     set status = 'confirmed', confirmed_at = now(), confirm_token_hash = null, confirm_expires_at = null
   where id = a.id;

  if private.is_paused()
     or not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then
    perform private.raise_alert('partner_mail_skipped', v_day);
    if not private.partner_enqueue(a.id) then perform private.raise_alert('queue_full', v_day); end if;   -- R6
    return jsonb_build_object('ok', true, 'action', 'queued');
  end if;
  if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
    perform private.give_back('send_hour', v_hour);
    perform private.raise_alert('partner_mail_skipped', v_day);
    if not private.partner_enqueue(a.id) then perform private.raise_alert('queue_full', v_day); end if;   -- R6
    return jsonb_build_object('ok', true, 'action', 'queued');
  end if;
  delete from private.partner_mail_queue where application_id = a.id;   -- R4
  return jsonb_build_object('ok', true, 'action', 'send', 'id', a.id, 'hour', v_hour,
                            'email', a.email, 'name', a.name, 'handles', a.handles, 'pitch', a.pitch);
end $$;

-- ---------------------------------------------------------------- drain
-- Each queue row is ONE email; the row's status decides which (pending -> link, confirmed ->
-- owner notice). R3: the application row and the mailbox are only TRIED (skip if busy); the
-- global counters come last. R5: the applicant's mailbox allowance is charged today, at dispatch.
-- R7: an unconfirmed application past its deadline is deleted here, never sent a new link.
create or replace function public.waitlist_drain_partner_queue() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  q       record;
  a       private.partner_applications%rowtype;
  v_hour  timestamptz := date_trunc('hour', now());
  v_day   timestamptz := date_trunc('day', now());
  v_out   jsonb := '[]'::jsonb;
  v_n     integer := 0;
  v_token text;
  v_mbx   text;
begin
  if not private.is_paused() then
    for q in select application_id from private.partner_mail_queue order by queued_at
             for update skip locked loop
      exit when v_n >= private.cfg_int('drain_batch');
      perform 1 from private.partner_applications where id = q.application_id;
      if not found then delete from private.partner_mail_queue where application_id = q.application_id; continue; end if;
      select * into a from private.partner_applications where id = q.application_id for update skip locked;
      if not found then continue; end if;                                  -- busy right now: next run
      if exists (select 1 from private.suppressions where email_hash = private.email_hash(a.email)) then
        delete from private.partner_mail_queue where application_id = a.id;
        continue;
      end if;
      if a.status = 'pending' then
        if coalesce(a.last_confirm_sent_at, a.created_at)
           < now() - make_interval(hours => private.cfg_int('partner_confirm_ttl_hours')) then
          delete from private.partner_applications where id = a.id;         -- R7: past the deadline
          continue;
        end if;
        if a.confirm_sends >= private.cfg_int('partner_max_confirm_sends')
           or (a.last_confirm_sent_at is not null
               and a.last_confirm_sent_at > now() - make_interval(mins => private.cfg_int('resend_min_minutes'))) then
          delete from private.partner_mail_queue where application_id = a.id;   -- a link went out recently / cap reached
          continue;
        end if;
        v_mbx := private.mailbox_bucket(a.email);
        if not pg_try_advisory_xact_lock(hashtextextended(v_mbx, 0)) then continue; end if;   -- busy: next run
        if not private.take(v_mbx, v_day, private.cfg_int('mailbox_sends_per_day')) then continue; end if;  -- tomorrow
        if not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then
          perform private.give_back(v_mbx, v_day); exit;
        end if;
        if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
          perform private.give_back('send_hour', v_hour); perform private.give_back(v_mbx, v_day); exit;
        end if;
        v_token := private.new_token();
        update private.partner_applications set
          confirm_token_hash   = private.token_hash(v_token),
          confirm_expires_at   = now() + make_interval(hours => private.cfg_int('partner_confirm_ttl_hours')),
          confirm_sends        = confirm_sends + 1,
          last_confirm_sent_at = now()
        where id = a.id
        returning * into a;
        delete from private.partner_mail_queue where application_id = a.id;
        v_out := v_out || jsonb_build_object('kind', 'confirm', 'id', a.id, 'email', a.email, 'token', v_token,
                                             'send_no', a.confirm_sends, 'hour', v_hour);
      else
        if not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then exit; end if;
        if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
          perform private.give_back('send_hour', v_hour); exit;
        end if;
        delete from private.partner_mail_queue where application_id = a.id;
        v_out := v_out || jsonb_build_object('kind', 'owner', 'id', a.id, 'email', a.email, 'name', a.name,
                                             'handles', a.handles, 'pitch', a.pitch, 'hour', v_hour);
      end if;
      v_n := v_n + 1;
    end loop;
  end if;
  return jsonb_build_object('sends', v_out, 'left', (select count(*) from private.partner_mail_queue),
                            'paused', private.is_paused());
end $$;

-- ---------------------------------------------------------------- requeue (re-stated from 0007)
-- R3: locks the application row BEFORE queue admission (same order as apply/confirm).
-- R7: a confirmation link that never reached the provider does not count as one of the 3 links,
-- and its token is cleared (that email does not exist). Returns false if refused (queue full).
create or replace function public.waitlist_partner_requeue(p_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare a private.partner_applications%rowtype;
begin
  if p_id is null then return false; end if;
  select * into a from private.partner_applications where id = p_id for update;
  if not found then return false; end if;
  if a.status = 'pending' then
    update private.partner_applications
       set confirm_sends = greatest(confirm_sends - 1, 0), last_confirm_sent_at = null,
           confirm_token_hash = null, confirm_expires_at = null
     where id = p_id;
  end if;
  if not private.partner_enqueue(p_id) then
    perform private.raise_alert('queue_full', date_trunc('day', now()));
    return false;
  end if;
  return true;
end $$;

-- ---------------------------------------------------------------- #2 send-time check
-- The worker calls this right before handing each QUEUED email to the provider, so a pause or a
-- deletion / bounce / complaint that committed while it was working stops the emails not yet sent.
-- Returns 'ok', 'paused' (temporary: partner work is put back in the queue) or 'suppressed'
-- (deleted / bounced / complained: never send).
create or replace function public.waitlist_send_allowed(p_email text) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when exists (select 1 from private.suppressions where email_hash = private.email_hash(p_email)) then 'suppressed'
    when private.is_paused() then 'paused'
    else 'ok' end
$$;

-- ---------------------------------------------------------------- retention
-- Re-stated from 0006: also deletes unconfirmed applications once their deadline has passed,
-- queued or not (R7: the published 48 h promise holds).
create or replace function public.waitlist_maintenance() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a integer; b integer; c integer; d integer; e integer; f integer;
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
  delete from private.partner_applications
   where created_at < now() - make_interval(days => private.cfg_int('partner_retention_days'));
  get diagnostics e = row_count;
  delete from private.partner_applications
   where status = 'pending'
     and coalesce(last_confirm_sent_at, created_at) < now() - make_interval(hours => private.cfg_int('partner_confirm_ttl_hours'));
  get diagnostics f = row_count;
  return jsonb_build_object('pending_deleted', a, 'unsubscribed_deleted', b, 'counters_deleted', c,
                            'alerts_deleted', d, 'partner_deleted', e, 'partner_unconfirmed_deleted', f);
end $$;

-- ---------------------------------------------------------------- privileges
do $$ declare f text; begin
  foreach f in array array[
    'public.waitlist_partner_apply(text,text,jsonb,text,text)', 'public.waitlist_partner_confirm(text)',
    'public.waitlist_drain_partner_queue()', 'public.waitlist_partner_requeue(uuid)',
    'public.waitlist_send_allowed(text)', 'public.waitlist_maintenance()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
