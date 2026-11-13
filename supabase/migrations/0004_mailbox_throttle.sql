-- =====================================================================
-- 0004 — per-MAILBOX send cap (closes the "+tag" subscription-bombing hole).
--
-- The problem 0001-0003 left open:
--   Identity is the EXACT address (owner policy P-2): ahmed+1@gmail.com,
--   ahmed+2@gmail.com ... are stored as DIFFERENT people, each with its own
--   per-address cap (max_confirm_sends). But Gmail/Outlook/Fastmail/iCloud all
--   deliver every "+tag" variant to ONE inbox. So one attacker could turn the
--   "3 emails per address" cap into "3 per variant" and flood a victim's inbox
--   up to the global daily cap. Proven: 60 "+tag" variants -> 60 emails sent.
--
-- The fix (owner-approved 2026-11-13): keep identity EXACT (every variant is
-- still its own row / its own person on the list), but add a second, separate
-- throttle keyed by the real delivery MAILBOX. All "+tag" variants of one
-- address share one mailbox key, so together they get at most
-- mailbox_sends_per_day confirmation emails.
--
-- Scope, deliberately narrow (owner decision):
--   * We strip ONLY the "+tag" part — the piece every provider ignores for
--     delivery. We do NOT fold dots: a.hmed@ and ahmed@ stay separate mailbox
--     keys. (Dot variants are a smaller vector and the global daily cap still
--     bounds them. A future flag could fold Gmail dots if the owner wants it.)
--   * This NEVER merges two different-letter addresses: ahmedmohamed@ and
--     ahmedsayed@ have different mailbox keys and are always separate.
--   * It changes the THROTTLE only, never identity, export, or who is "on the
--     list". Each variant still confirms and is exported as its own row.
--
-- Same house rules: single-statement atomic counters, SECURITY DEFINER +
-- search_path = '', return a reason (never raise), EXECUTE for service_role.
-- Every number is an EXAMPLE the owner sets in private.settings.
-- =====================================================================

insert into private.settings(key, value) values ('mailbox_sends_per_day', '3')
on conflict (key) do nothing;

-- Harden the server-side email check too (defence in depth with validate.ts):
-- refuse MIME "encoded-word" local parts (=?charset?enc?...?=), a parser-confusion
-- trick that some mail software decodes and re-targets. No real local part needs "=?".
create or replace function private.email_ok(p text) returns boolean
language sql immutable set search_path = '' as $$
  select p is not null
     and length(p) between 6 and 254
     and p ~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]{1,64}@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$'
     and p !~ '\.\.'
     and left(p, 1) <> '.'
     and split_part(p, '@', 1) !~ '\.$'
     and position('=?' in split_part(p, '@', 1)) = 0      -- no encoded-word local part
     and right(split_part(p, '@', 2), 1) <> '-'
     and split_part(p, '@', 2) ~ '\.[a-z]{2,63}$'
$$;

-- The real delivery mailbox for throttling. Lower+trim (already the identity
-- form), strip "+tag", normalise googlemail.com -> gmail.com. Dots untouched.
create or replace function private.mailbox_key(p_email text) returns text
language plpgsql immutable set search_path = '' as $$
declare e text := private.normalize_email(p_email); l text; d text;
begin
  if position('@' in e) = 0 then return e; end if;
  l := split_part(e, '@', 1);
  d := split_part(e, '@', 2);
  if position('+' in l) > 0 then
    l := split_part(l, '+', 1);
    if l = '' then l := split_part(e, '@', 1); end if;  -- never collapse every "+tag@dom" into one bucket
  end if;
  if d = 'googlemail.com' then d := 'gmail.com'; end if;
  return l || '@' || d;
end $$;

-- Counter bucket for a mailbox. Hashed with the existing pepper so no plaintext
-- address is ever written to private.counters. Reuses private.take / give_back
-- and the daily counter cleanup in waitlist_maintenance.
create or replace function private.mailbox_bucket(p_email text) returns text
language sql stable security definer set search_path = '' as $$
  select 'send_mbx:' || encode(
    extensions.hmac(private.mailbox_key(p_email), private.secret('email_pepper'), 'sha256'), 'hex')
$$;

-- waitlist_signup, re-stated from 0002 with the per-mailbox cap added FIRST
-- (before the global hour/day caps), so a flood of one inbox's "+tag" variants
-- is refused without ever consuming the shared global budget. If a later global
-- cap blocks, the mailbox unit is given back (no email was attempted); on a real
-- provider outage it is NOT refunded (same rule as the per-address counter).
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

  -- per-ADDRESS limits (exact address). Lifetime counter never resets.
  if v_row.confirm_sends >= private.cfg_int('max_confirm_sends') then
    return jsonb_build_object('action','none','reason','address_lifetime_cap');
  end if;
  if v_row.last_confirm_sent_at is not null
     and v_row.last_confirm_sent_at > now() - make_interval(mins => private.cfg_int('resend_min_minutes')) then
    return jsonb_build_object('action','none','reason','address_too_soon');
  end if;

  -- per-MAILBOX cap: all "+tag" variants of one inbox share this. Taken first so
  -- a blocked flood never touches the shared global counters.
  v_mbx := private.mailbox_bucket(v_email);
  if not private.take(v_mbx, v_day, private.cfg_int('mailbox_sends_per_day')) then
    return jsonb_build_object('action','none','reason','mailbox_send_cap');
  end if;
  if not private.take('send_hour', v_hour, private.cfg_int('global_sends_per_hour')) then
    perform private.give_back(v_mbx, v_day);
    return jsonb_build_object('action','none','reason','global_send_cap');
  end if;
  if not private.take('send_day', v_day, private.cfg_int('global_sends_per_day')) then
    perform private.give_back('send_hour', v_hour);
    perform private.give_back(v_mbx, v_day);
    return jsonb_build_object('action','none','reason','global_send_day_cap');
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

  insert into private.consent_events(signup_id, event, consent_version, detail)
  values (v_row.id, case when v_was_unsub then 'resubscribe_requested' else 'requested' end,
          p_consent_version, jsonb_build_object('source', p_source, 'send_no', v_row.confirm_sends));

  return jsonb_build_object('action','send','token', v_token, 'signup_id', v_row.id,
                            'send_no', v_row.confirm_sends, 'hour', v_hour);
end $$;

-- The two new private helpers are internal (only SECURITY DEFINER functions owned by the
-- table owner call them). Nothing in the API roles may execute them. 0001's one-time
-- "revoke all on all functions in schema private" ran before these existed, so revoke here.
revoke all on function private.mailbox_key(text)    from public, anon, authenticated;
revoke all on function private.mailbox_bucket(text) from public, anon, authenticated;
revoke all on function public.waitlist_signup(text,text,text,text) from public, anon, authenticated;
grant execute on function public.waitlist_signup(text,text,text,text) to service_role;
