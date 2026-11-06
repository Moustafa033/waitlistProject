// PUBLIC values only. Everything here is visible to every visitor.
// Never put a Supabase key, a Resend key or a Turnstile SECRET here (CI checks it).
window.WAITLIST = Object.freeze({
  api: "https://YOUR-PROJECT-REF.supabase.co/functions/v1/waitlist",
  turnstileSiteKey: "YOUR-TURNSTILE-SITE-KEY",
});
