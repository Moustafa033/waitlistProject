-- =====================================================================
-- 0003 — self-service "Delete my data" (GDPR Art. 17) without any manual work.
--
-- The person proves ownership with the SAME signed personal link used for unsubscribe:
-- token = HMAC(signup_id, unsub_key). Nobody can delete another person (the token cannot be
-- guessed or reused for another id). Deleting:
--   * removes the signup row immediately,
--   * keeps only a keyed hash in private.suppressions so we never email that address again
--     (stated in the privacy notice),
--   * unlinks consent events (FK on delete set null) and logs an anonymous 'erased' event.
-- Idempotent: a valid link for an already-deleted person still answers ok (reveals nothing).
-- =====================================================================

create or replace function public.waitlist_erase_by_token(p_signup_id uuid, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_email text;
begin
  if p_signup_id is null or p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$'
     or p_token <> public.waitlist_unsub_token(p_signup_id) then
    return jsonb_build_object('ok', false);
  end if;
  delete from private.signups where id = p_signup_id returning email into v_email;
  if v_email is not null then
    insert into private.suppressions(email_hash, reason) values (private.email_hash(v_email), 'erasure')
    on conflict (email_hash) do update set reason = 'erasure', at = now();
    insert into private.consent_events(event, detail) values ('erased', jsonb_build_object('method', 'self_service_link'));
  end if;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.waitlist_erase_by_token(uuid, text) from public, anon, authenticated;
grant execute on function public.waitlist_erase_by_token(uuid, text) to service_role;
