// Server-only configuration (Supabase Edge Function secrets: `supabase secrets set ...`).
// Never in the site, never in git, never pasted into an AI chat.
// A missing value => the function refuses to run (fail closed).
export class ConfigError extends Error {}

export interface Config {
  supabaseUrl: string;
  secretKey: string;            // sb_secret_... (bypasses RLS) — used ONLY to call the waitlist RPCs
  siteOrigin: string;           // e.g. https://example.com  (exact, no trailing slash)
  functionBaseUrl: string;      // e.g. https://<ref>.supabase.co/functions/v1/waitlist
  turnstileSecret: string;
  turnstileHostnames: string[]; // hostnames the widget may be solved on
  resendApiKey: string;         // SENDING-ONLY key, restricted to the sending domain
  mailFrom: string;             // e.g. "Brand AI <hello@mail.example.com>"
  mailReplyTo?: string;         // optional, e.g. "hello@example.com" (a real mailbox, e.g. at Hostinger)
  consentVersion: string;       // must equal private.settings.current_consent_version
  minFillMs: number;            // EXAMPLE: form filled faster than this => bot (weak signal)
}

type Env = (name: string) => string | undefined;
const denoEnv: Env = (n) => Deno.env.get(n);

function need(get: Env, name: string): string {
  const v = get(name);
  if (!v || v.trim() === "") throw new ConfigError(`missing ${name}`);
  return v.trim();
}

/** New-style secret key only. Supabase injects SUPABASE_SECRET_KEYS (JSON) into functions. */
function secretKey(get: Env): string {
  const injected = get("SUPABASE_SECRET_KEYS");
  let key = "";
  if (injected) {
    try { key = String(JSON.parse(injected)["default"] ?? ""); } catch { throw new ConfigError("bad SUPABASE_SECRET_KEYS"); }
  } else {
    key = get("WAITLIST_SECRET_KEY") ?? "";
  }
  if (!key.startsWith("sb_secret_")) throw new ConfigError("need an sb_secret_ key (legacy JWT keys refused)");
  return key;
}

export function loadConfig(get: Env = denoEnv): Config {
  const siteOrigin = need(get, "SITE_ORIGIN");
  if (!/^https:\/\/[a-z0-9.-]+(:\d+)?$/.test(siteOrigin) && !/^http:\/\/localhost(:\d+)?$/.test(siteOrigin)) {
    throw new ConfigError("SITE_ORIGIN must be an exact https origin");
  }
  const resendApiKey = need(get, "RESEND_API_KEY");
  if (!resendApiKey.startsWith("re_")) throw new ConfigError("RESEND_API_KEY looks wrong");
  // A typo here must not silently switch the time trap off (NaN compares false) => fail closed.
  const minFillRaw = (get("MIN_FILL_MS") ?? "2500").trim();
  if (!/^\d{1,5}$/.test(minFillRaw) || Number(minFillRaw) < 500 || Number(minFillRaw) > 60000) {
    throw new ConfigError("MIN_FILL_MS must be a whole number of milliseconds between 500 and 60000");
  }
  // Plain address only (no display name, no CR/LF): it goes into an email header.
  const replyTo = (get("MAIL_REPLY_TO") ?? "").trim().toLowerCase();
  if (replyTo !== "" && !/^[a-z0-9._%+-]{1,64}@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,63}$/.test(replyTo)) {
    throw new ConfigError("MAIL_REPLY_TO must be a plain email address");
  }
  return {
    supabaseUrl: need(get, "SUPABASE_URL").replace(/\/$/, ""),
    secretKey: secretKey(get),
    siteOrigin,
    functionBaseUrl: need(get, "WAITLIST_FUNCTION_URL").replace(/\/$/, ""),
    turnstileSecret: need(get, "TURNSTILE_SECRET"),
    turnstileHostnames: need(get, "TURNSTILE_HOSTNAMES").split(",").map((h) => h.trim().toLowerCase()).filter(Boolean),
    resendApiKey,
    mailFrom: need(get, "MAIL_FROM"),
    mailReplyTo: replyTo === "" ? undefined : replyTo,
    consentVersion: need(get, "CONSENT_VERSION"),
    minFillMs: Number(minFillRaw),
  };
}
