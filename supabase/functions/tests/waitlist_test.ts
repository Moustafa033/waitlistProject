// deno test supabase/functions/tests   (no network: every outside call goes to a fake fetch)
import { makeHandler } from "../waitlist/handler.ts";
import { makeEventHandler } from "../email-events/handler.ts";
import { loadConfig, ConfigError, type Config } from "../_shared/env.ts";
import { normalizeEmail, isDisposable } from "../_shared/validate.ts";
import { DISPOSABLE } from "../_shared/disposable.ts";
import { csvCell, toCsv } from "../_shared/csv.ts";
import { svixSign, verifySvix } from "../_shared/svix.ts";
import { HttpError } from "../_shared/http.ts";

function assert(c: unknown, msg = "assertion failed"): asserts c { if (!c) throw new Error(msg); }
function eq<T>(a: T, b: T, msg = "") { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg} expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`); }
function throwsCode(fn: () => unknown, code: string) {
  try { fn(); } catch (e) { if (e instanceof HttpError && e.code === code) return; throw new Error(`wrong error ${e}`); }
  throw new Error(`expected ${code}`);
}

const ORIGIN = "https://waitlist.example.com";
const cfg: Config = {
  supabaseUrl: "https://ref.supabase.co", secretKey: "sb_secret_testtesttest", siteOrigin: ORIGIN,
  functionBaseUrl: "https://ref.supabase.co/functions/v1/waitlist", turnstileSecret: "ts-secret",
  turnstileHostnames: ["waitlist.example.com"], resendApiKey: "re_test", mailFrom: "Brand AI <hello@mail.example.com>",
  consentVersion: "waitlist-v1", minFillMs: 2500,
};
const TOKEN = "A".repeat(43);

interface Call { url: string; init?: RequestInit; body?: string }
function fakeFetch(opts: { rpc?: Record<string, unknown>; turnstile?: Record<string, unknown> | "down"; resend?: "ok" | "down" | 500 | "slow" } = {}) {
  const calls: Call[] = [];
  const f = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const body = typeof init?.body === "string" ? init.body : undefined;
    calls.push({ url, init, body });
    if (url.includes("challenges.cloudflare.com")) {
      if (opts.turnstile === "down") throw new TypeError("network");
      const fd = init?.body as FormData;
      const resp = String(fd.get("response"));
      const action = resp === "confirm-token" ? "waitlist_confirm" : resp.startsWith("pconfirm-token") ? "partner_confirm" : resp.startsWith("partner-token") ? "partner_apply" : "waitlist_signup";
      return Response.json(opts.turnstile ?? { success: true, hostname: "waitlist.example.com", action });
    }
    if (url.includes("/rest/v1/rpc/")) {
      const name = url.split("/").pop()!;
      const def: Record<string, unknown> = {
        waitlist_signup: { action: "send", token: TOKEN, signup_id: "11111111-1111-4111-8111-111111111111", send_no: 1, hour: "2026-11-06T10:00:00Z" },
        waitlist_confirm: { ok: true }, waitlist_unsubscribe: { ok: true }, waitlist_public_count: 1230,
        waitlist_send_failed: null, waitlist_suppress: null,
        waitlist_unsub_token: "U".repeat(43), waitlist_erase_by_token: { ok: true },
        waitlist_partner_apply: { action: "send", kind: "confirm", id: "22222222-2222-4222-8222-222222222222", token: "P".repeat(43), send_no: 1, hour: "2026-11-18T10:00:00Z" },
        waitlist_partner_confirm: { ok: true, action: "send", id: "22222222-2222-4222-8222-222222222222", hour: "2026-11-18T10:00:00Z", email: "sara@example.com", name: "Sara Ali", handles: [{ platform: "tiktok", username: "@sara.fit" }], pitch: "Personal trainer, 20k followers. I can post 2 reviews a month." },
        waitlist_drain_partner_queue: { sends: [], left: 0, paused: false }, waitlist_partner_requeue: true, waitlist_send_allowed: "ok",
      };
      return Response.json(opts.rpc?.[name] ?? def[name]);
    }
    if (url.startsWith("https://api.resend.com")) {
      if (opts.resend === "down") throw new TypeError("network");
      if (opts.resend === 500) return new Response("err", { status: 500 });
      if (opts.resend === "slow") await new Promise((r) => setTimeout(r, 400));
      return Response.json({ id: "email_1" });
    }
    throw new Error("unexpected fetch " + url);
  }) as typeof fetch;
  return { f, calls };
}

const pending: Promise<unknown>[] = [];
const deps = (f: typeof fetch) => ({ cfg, fetchFn: f, background: (p: Promise<unknown>) => { pending.push(p); } });
const settle = async () => { while (pending.length) await pending.shift(); };

const goodBody = () => ({ email: "  Ahmed@Example.com ", consent: true, age_16_plus: true, consent_version: "waitlist-v1",
  locale: "en", source: "landing", website: "", elapsed_ms: 8000, turnstile: "signup-token-xxxxxxxx" });
function req(path: string, body: unknown, headers: Record<string, string> = { origin: ORIGIN, "content-type": "application/json" }, method = "POST") {
  return new Request(`https://ref.supabase.co/functions/v1/waitlist/${path}`, {
    method, headers, body: method === "GET" ? undefined : typeof body === "string" ? body : JSON.stringify(body) });
}

// ------------------------------------------------------------------ validation
Deno.test("email: P-2 identity is lower+trim only; dots and plus are different people", () => {
  eq(normalizeEmail("  Ahmed@Example.COM "), "ahmed@example.com");
  eq(normalizeEmail("a.hmed+gym@example.com"), "a.hmed+gym@example.com");
});
Deno.test("email: hostile inputs are refused, never cleaned", () => {
  for (const bad of ["victim@example.com\r\nBcc: x@y.com", "a\u200B@example.com", "a@ex\u0430mple.com" /* cyrillic \u0430 */,
    "a@b", "a@@b.com", ".a@b.com", "a.@b.com", "a..b@c.com", "\"a b\"@c.com", "=cmd|' /C calc'!A0@x.com",
    "a@-b.com", "a@b-.com", "a@b.c0m", "x".repeat(65) + "@a.com", 42, null]) {
    throwsCode(() => normalizeEmail(bad), "invalid_email");
  }
});
Deno.test("email: every invisible/bidi/control character is refused (built from code points, none raw in this file)", () => {
  const codes = [0x00, 0x09, 0x0a, 0x0d, 0x7f, 0x85, 0xad, 0x61c, 0x180e, 0x200b, 0x200c, 0x200d, 0x200e, 0x200f,
    0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0x2066, 0x2067, 0x2068, 0x2069, 0xfeff];
  for (const c of codes) {
    const ch = String.fromCharCode(c);
    for (const s of [`a${ch}b@example.com`, `ab@exa${ch}mple.com`, `${ch}ab@example.com`]) throwsCode(() => normalizeEmail(s), "invalid_email");
  }
});
Deno.test("disposable domains match subdomains too", () => {
  assert(isDisposable("x@mailinator.com", DISPOSABLE));
  assert(isDisposable("x@eu.mailinator.com", DISPOSABLE));
  assert(!isDisposable("x@notmailinator.com", DISPOSABLE));
});

// ------------------------------------------------------------------ csv
Deno.test("CSV export neutralizes formulas (OWASP) and quotes every cell", () => {
  eq(csvCell("=HYPERLINK(\"http://evil\")"), `"'=HYPERLINK(""http://evil"")"`);
  for (const t of ["+1", "-1", "@SUM(A1)", "\tx", "\rx", "＝1"]) assert(csvCell(t).startsWith(`"'`), t);
  eq(csvCell("ahmed@example.com"), `"ahmed@example.com"`);
  eq(toCsv([{ email: "a@b.com", n: 1 }], ["email", "n"]), `"email","n"\r\n"a@b.com","1"\r\n`);
});

// ------------------------------------------------------------------ config
Deno.test("config refuses legacy JWT keys and wildcard/insecure origins", () => {
  const base: Record<string, string> = { SUPABASE_URL: "https://r.supabase.co", SITE_ORIGIN: ORIGIN, WAITLIST_FUNCTION_URL: "https://r/f",
    TURNSTILE_SECRET: "s", TURNSTILE_HOSTNAMES: "waitlist.example.com", RESEND_API_KEY: "re_x", MAIL_FROM: "a <a@b.com>", CONSENT_VERSION: "v1",
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_abc" }) };
  eq(loadConfig((n) => base[n]).secretKey, "sb_secret_abc");
  eq(loadConfig((n) => base[n]).minFillMs, 2500, "default time trap");
  eq(loadConfig((n) => base[n]).mailReplyTo, undefined, "reply-to is optional");
  eq(loadConfig((n) => (n === "MAIL_REPLY_TO" ? " Hello@Example.com " : base[n])).mailReplyTo, "hello@example.com");
  for (const v of ["hello@example.com\r\nBcc: x@y.com", "Name <hello@example.com>", "not-an-email", "a@b.com,c@d.com"]) {
    let threw = false;
    try { loadConfig((n) => (n === "MAIL_REPLY_TO" ? v : base[n])); } catch (e) { threw = e instanceof ConfigError; }
    assert(threw, `MAIL_REPLY_TO=${JSON.stringify(v)} must be refused (header injection)`);
  }
  eq(loadConfig((n) => (n === "MIN_FILL_MS" ? "3000" : base[n])).minFillMs, 3000);
  for (const [k, v] of [["SUPABASE_SECRET_KEYS", JSON.stringify({ default: "eyJhbGciOi..." })], ["SITE_ORIGIN", "*"], ["SITE_ORIGIN", "http://evil.com"], ["RESEND_API_KEY", "sk_live"],
                        ["MIN_FILL_MS", "abc"], ["MIN_FILL_MS", "2.5s"], ["MIN_FILL_MS", "0"], ["MIN_FILL_MS", "-1"], ["MIN_FILL_MS", "999999"], ["MIN_FILL_MS", ""]]) {
    let threw = false;
    try { loadConfig((n) => (n === k ? v : base[n])); } catch (e) { threw = e instanceof ConfigError; }
    assert(threw, `${k}=${v} must be refused`);
  }
});

// ------------------------------------------------------------------ signup
Deno.test("signup happy path: Turnstile checked, RPC called with normalized email, mail sent with idempotency key and fragment link", async () => {
  const { f, calls } = fakeFetch();
  const res = await makeHandler(deps(f))(req("signup", goodBody()));
  eq(res.status, 202);
  eq(await res.json(), { ok: true, message: "check_inbox" });
  eq(res.headers.get("access-control-allow-origin"), ORIGIN);
  await settle();
  const rpcCall = calls.find((c) => c.url.endsWith("/rpc/waitlist_signup"))!;
  eq(JSON.parse(rpcCall.body!).p_email, "ahmed@example.com");
  eq((rpcCall.init!.headers as Record<string, string>).apikey, "sb_secret_testtesttest");
  const mail = calls.find((c) => c.url.startsWith("https://api.resend.com"))!;
  eq((mail.init!.headers as Record<string, string>)["idempotency-key"], "confirm/11111111-1111-4111-8111-111111111111/1");
  const m = JSON.parse(mail.body!);
  eq(m.to, ["ahmed@example.com"]);
  assert(m.text.includes(`${ORIGIN}/confirm#t=${TOKEN}`), "token must be in the fragment, not the query");
  assert(!m.text.includes("?t="), "no token in query string");
  assert(m.text.includes(`${ORIGIN}/unsubscribe#id=11111111-1111-4111-8111-111111111111&t=${"U".repeat(43)}`),
    "personal unsubscribe / delete-my-data link (signed, in the fragment) is in the confirmation email");
  // HTML version: same two links (HTML-escaped), the "ignore" line, no tracking image, only our own image.
  eq(m.subject, "You acted on it");
  assert(m.html.includes(`href="${ORIGIN}/confirm#t=${TOKEN}"`), "HTML confirm button uses the fragment link");
  assert(m.html.includes(`href="${ORIGIN}/unsubscribe#id=11111111-1111-4111-8111-111111111111&amp;t=${"U".repeat(43)}"`), "HTML unsubscribe link, escaped");
  assert(m.html.includes("Didn&#39;t sign up?") && m.text.includes("Didn't sign up?"), "ignore line in both versions (HTML-escaped in the HTML part)");
  const imgs = [...m.html.matchAll(/<img[^>]+src="([^"]+)"/g)].map((x) => x[1]);
  eq(imgs, [`${ORIGIN}/email-logo.png`], "only image is our own logo (no tracking pixel)");
  assert(!/ahmed@example\.com/.test(m.html + m.text + m.subject), "the recipient's address is never echoed into the email");
  // Turnstile first, then the signup RPC; the signed-link RPC and the mail run in the background.
  const order = calls.map((c) => c.url.includes("cloudflare") ? "ts" : c.url.includes("rpc") ? c.url.split("/").pop() : "mail");
  eq(order, ["ts", "waitlist_signup", "waitlist_unsub_token", "mail"], "Turnstile must run BEFORE the database");
});

Deno.test("confirmation mail carries reply_to only when configured", async () => {
  for (const replyTo of [undefined, "hello@example.com"]) {
    const { f, calls } = fakeFetch();
    const d = { ...deps(f), cfg: { ...cfg, mailReplyTo: replyTo } };
    eq((await makeHandler(d)(req("signup", goodBody()))).status, 202);
    await settle();
    const m = JSON.parse(calls.find((c) => c.url.startsWith("https://api.resend.com"))!.body!);
    eq(m.reply_to, replyTo, "reply_to");
  }
});

Deno.test("signup answers are byte-identical for sent / already-on-list / limited / bot (no enumeration)", async () => {
  const bodies: string[] = [];
  for (const rpc of [undefined, { waitlist_signup: { action: "none", reason: "already_confirmed" } },
                     { waitlist_signup: { action: "none", reason: "address_too_soon" } }, { waitlist_signup: { action: "none", reason: "suppressed" } }]) {
    const { f } = fakeFetch({ rpc: rpc as Record<string, unknown> | undefined });
    const r = await makeHandler(deps(f))(req("signup", goodBody()));
    eq(r.status, 202); bodies.push(await r.text()); await settle();
  }
  const { f, calls } = fakeFetch();
  const bot = await makeHandler(deps(f))(req("signup", { ...goodBody(), website: "http://spam" }));
  bodies.push(await bot.text());
  eq(calls.length, 0, "honeypot hit must not reach Turnstile, DB or email");
  assert(bodies.every((b) => b === bodies[0]), "all answers identical");
});

Deno.test("signup filled in under the minimum time -> silent 202, nothing done", async () => {
  const { f, calls } = fakeFetch();
  const r = await makeHandler(deps(f))(req("signup", { ...goodBody(), elapsed_ms: 300 }));
  eq(r.status, 202); eq(calls.length, 0);
});

Deno.test("signup refusals: origin, content-type, consent, age, version, extra keys, size, method, captcha", async () => {
  const h = (o = {}) => makeHandler(deps(fakeFetch(o).f));
  eq((await h()(req("signup", goodBody(), { "content-type": "application/json" }))).status, 403, "no Origin");
  eq((await h()(req("signup", goodBody(), { origin: "https://evil.com", "content-type": "application/json" }))).status, 403, "foreign Origin");
  eq((await h()(req("signup", "email=a@b.com", { origin: ORIGIN, "content-type": "application/x-www-form-urlencoded" }))).status, 415, "form post (CSRF style)");
  eq((await h()(req("signup", { ...goodBody(), consent: "true" }))).status, 400, "consent must be literal true");
  eq((await h()(req("signup", { ...goodBody(), age_16_plus: false }))).status, 400, "age 16+ required (P-9)");
  eq((await h()(req("signup", { ...goodBody(), consent_version: "waitlist-v0" }))).status, 409, "stale consent text");
  eq((await h()(req("signup", { ...goodBody(), status: "confirmed" }))).status, 400, "mass assignment field");
  eq((await h()(req("signup", { ...goodBody(), email: "x@mailinator.com" }))).status, 400, "disposable");
  eq((await h()(req("signup", { ...goodBody(), email: "a@b.com\r\nBcc: z@z.com" }))).status, 400, "header injection");
  eq((await h()(req("signup", { ...goodBody(), source: "x".repeat(5000) }))).status, 413, "huge body");
  eq((await h()(req("signup", null, { origin: ORIGIN }, "GET"))).status, 405, "GET");
  eq((await h()(req("signup", { ...goodBody(), turnstile: undefined }))).status, 400, "no captcha token");
  eq((await h({ turnstile: { success: true, hostname: "evil.example.net", action: "waitlist_signup" } })(req("signup", goodBody()))).status, 400, "token solved on another hostname");
  eq((await h({ turnstile: { success: true, hostname: "waitlist.example.com", action: "contact" } })(req("signup", goodBody()))).status, 400, "token from another widget/action");
  eq((await h({ turnstile: "down" })(req("signup", goodBody()))).status, 503, "Turnstile outage fails CLOSED");
});

Deno.test("mail provider unreachable -> global send unit refunded, visitor sees the same 202", async () => {
  const { f, calls } = fakeFetch({ resend: "down" });
  const r = await makeHandler(deps(f))(req("signup", goodBody()));
  eq(r.status, 202);
  await settle();
  assert(calls.some((c) => c.url.endsWith("/rpc/waitlist_send_failed")), "refund called");
  const { f: f2, calls: c2 } = fakeFetch({ resend: 500 });
  eq((await makeHandler(deps(f2))(req("signup", goodBody()))).status, 202);
  await settle();
  assert(!c2.some((c) => c.url.endsWith("/rpc/waitlist_send_failed")), "provider answered (500) -> no refund (it may have sent)");
});

Deno.test("signed link cannot be made -> no mail without it, global units refunded, same 202", async () => {
  for (const bad of ["short", "", 42]) {
    const { f, calls } = fakeFetch({ rpc: { waitlist_unsub_token: bad } as Record<string, unknown> });
    eq((await makeHandler(deps(f))(req("signup", goodBody()))).status, 202);
    await settle();
    assert(!calls.some((c) => c.url.startsWith("https://api.resend.com")), "no email without a valid personal link");
    assert(calls.some((c) => c.url.endsWith("/rpc/waitlist_send_failed")), "units given back (provider never reached)");
  }
});

Deno.test("erase ('Delete my data'): only our page (Origin + JSON) with a well-formed signed link; never via GET or one-click", async () => {
  const { f, calls } = fakeFetch();
  const h = makeHandler(deps(f));
  const id = "11111111-1111-4111-8111-111111111111";
  eq(await (await h(req("erase", { id, t: TOKEN }))).json(), { ok: true });
  eq(JSON.parse(calls.at(-1)!.body!), { p_signup_id: id, p_token: TOKEN });
  const before = calls.length;
  eq(await (await h(req("erase", { id: "not-a-uuid", t: TOKEN }))).json(), { ok: false }, "bad id");
  eq(await (await h(req("erase", { id, t: "short" }))).json(), { ok: false }, "bad token");
  eq(calls.length, before, "malformed link: no database call at all");
  eq((await h(req("erase", { id, t: TOKEN }, { "content-type": "application/json" }))).status, 403, "no Origin (other site / script)");
  eq((await h(req("erase", { id, t: TOKEN }, { origin: "https://evil.com", "content-type": "application/json" }))).status, 403, "foreign Origin");
  eq((await h(new Request(`https://ref.supabase.co/functions/v1/waitlist/erase?id=${id}&t=${TOKEN}`, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "List-Unsubscribe=One-Click" }))).status, 403,
    "one-click / form post never deletes (mail providers and scanners have no Origin)");
  eq((await h(req("erase", "id=x", { origin: ORIGIN, "content-type": "application/x-www-form-urlencoded" }))).status, 415,
    "form post even from our own origin is refused (JSON only)");
  eq((await h(req("erase", { id, t: TOKEN, status: "x" }))).status, 400, "extra keys refused");
  eq((await h(req("erase", null, {}, "GET"))).status, 405, "GET never deletes");
  const { f: f2 } = fakeFetch({ rpc: { waitlist_erase_by_token: { ok: false } } });
  eq(await (await makeHandler(deps(f2))(req("erase", { id, t: TOKEN }))).json(), { ok: false }, "database refuses a wrong signature");
});

Deno.test("internal errors never leak details", async () => {
  // deno-lint-ignore require-await -- a fetch that always rejects (simulated outage)
  const broken = (async () => { throw new Error("db password=hunter2 at host x"); }) as unknown as typeof fetch;
  const r = await makeHandler(deps(broken))(req("signup", goodBody()));
  eq(r.status, 503); // Turnstile is first and fails closed
  const r2 = await makeHandler(deps(broken))(req("count", null, {}, "GET"));
  eq(r2.status, 500); eq(await r2.text(), `{"error":"try_later"}`);
});

// ------------------------------------------------------------------ confirm / unsubscribe / cors
Deno.test("confirm: only via POST + Origin + Turnstile(action confirm); signup captcha token cannot be reused", async () => {
  const { f, calls } = fakeFetch();
  const h = makeHandler(deps(f));
  eq((await h(req("confirm", null, { origin: ORIGIN }, "GET"))).status, 405, "GET never confirms (link scanners)");
  eq(await (await h(req("confirm", { token: "short", turnstile: "confirm-token" }))).json(), { ok: false });
  eq(calls.length, 0, "malformed token: no outside call at all");
  eq(await (await h(req("confirm", { token: TOKEN, turnstile: "confirm-token" }))).json(), { ok: true });
  eq((await h(req("confirm", { token: TOKEN, turnstile: "signup-token-xxxxxxxx" }))).status, 400, "token of the signup widget");
  eq((await h(req("confirm", { token: TOKEN, turnstile: "confirm-token" }, { "content-type": "application/json" }))).status, 403, "no Origin");
});

Deno.test("unsubscribe: RFC 8058 one-click works without Origin; JSON path needs Origin", async () => {
  const { f, calls } = fakeFetch();
  const h = makeHandler(deps(f));
  const id = "11111111-1111-4111-8111-111111111111";
  const oneClick = new Request(`https://ref.supabase.co/functions/v1/waitlist/unsubscribe?id=${id}&t=${TOKEN}`, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "List-Unsubscribe=One-Click" });
  eq(await (await h(oneClick)).json(), { ok: true });
  eq(JSON.parse(calls.at(-1)!.body!), { p_signup_id: id, p_token: TOKEN });
  const wrongBody = new Request(`https://ref.supabase.co/functions/v1/waitlist/unsubscribe?id=${id}&t=${TOKEN}`, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "x=y" });
  eq((await h(wrongBody)).status, 400);
  eq((await h(req("unsubscribe", { id, t: TOKEN }, { "content-type": "application/json" }))).status, 403);
  eq((await h(req("unsubscribe", { id, t: TOKEN }))).status, 200);
  eq((await h(req("unsubscribe", null, {}, "GET"))).status, 405, "GET never unsubscribes either");
});

Deno.test("CORS: exact origin only, never reflected", async () => {
  const h = makeHandler(deps(fakeFetch().f));
  const evil = await h(new Request("https://ref.supabase.co/functions/v1/waitlist/signup", { method: "OPTIONS", headers: { origin: "https://evil.com" } }));
  eq(evil.headers.get("access-control-allow-origin"), null);
  const ok = await h(new Request("https://ref.supabase.co/functions/v1/waitlist/signup", { method: "OPTIONS", headers: { origin: ORIGIN } }));
  eq(ok.headers.get("access-control-allow-origin"), ORIGIN);
});

// ------------------------------------------------------------------ webhook
const WH = "whsec_" + btoa("0123456789abcdef0123456789abcdef");
async function signed(body: string, ts = Math.floor(Date.now() / 1000)) {
  const sig = await svixSign(WH, "msg_1", String(ts), body);
  return new Request("https://ref.supabase.co/functions/v1/email-events", { method: "POST", body,
    headers: { "svix-id": "msg_1", "svix-timestamp": String(ts), "svix-signature": `v1,bad v1,${sig}` } });
}
Deno.test("webhook: signature, replay window, complaint/hard bounce suppress, soft bounce ignored", async () => {
  const { f, calls } = fakeFetch();
  const h = makeEventHandler({ cfg, webhookSecret: WH, fetchFn: f });
  const complaint = JSON.stringify({ type: "email.complained", data: { to: ["Sara@Example.com"] } });
  eq((await h(await signed(complaint))).status, 200);
  eq(JSON.parse(calls.at(-1)!.body!), { p_email: "sara@example.com", p_reason: "complaint" });
  const before = calls.length;
  eq((await h(await signed(JSON.stringify({ type: "email.bounced", data: { to: ["a@b.com"], bounce: { type: "Transient" } } })))).status, 200);
  eq(calls.length, before, "soft bounce does not suppress");
  const tampered = await signed(complaint);
  const bad = new Request(tampered.url, { method: "POST", headers: tampered.headers, body: complaint.replace("Sara", "Boss") });
  eq((await h(bad)).status, 401, "tampered body");
  eq((await h(await signed(complaint, Math.floor(Date.now() / 1000) - 3600))).status, 401, "replayed old event");
  eq((await h(new Request("https://x/email-events", { method: "POST", body: complaint }))).status, 401, "unsigned");
});
Deno.test("svix verify accepts rotated multi-signature header", async () => {
  const ts = "1762400000"; const sig = await svixSign(WH, "id", ts, "{}");
  await verifySvix(WH, new Headers({ "svix-id": "id", "svix-timestamp": ts, "svix-signature": `v1,AAAA v1,${sig}` }), "{}", 1762400000);
});

import { launchMail } from "../_shared/mailer.ts";
Deno.test("launch email carries RFC 8058 headers, a visible unsubscribe link and a per-campaign idempotency key", () => {
  const m = launchMail(cfg, "a@b.com", "11111111-1111-4111-8111-111111111111", TOKEN, "launch-1");
  eq(m.headers!["List-Unsubscribe-Post"], "List-Unsubscribe=One-Click");
  assert(m.headers!["List-Unsubscribe"].startsWith("<https://ref.supabase.co/functions/v1/waitlist/unsubscribe?id="));
  assert(m.text.includes(`${ORIGIN}/unsubscribe#id=`));
  eq(m.idempotencyKey, "launch-1/11111111-1111-4111-8111-111111111111");
  let threw = false; try { launchMail(cfg, "a@b.com", "x", TOKEN, "bad id\r\n"); } catch { threw = true; }
  assert(threw, "campaign id validated");
});

Deno.test("GET /count is cached per instance (a GET flood is not a DB flood)", async () => {
  const { f, calls } = fakeFetch();
  let t = 0;
  const h = makeHandler({ ...deps(f), now: () => t });
  for (let i = 0; i < 50; i++) await h(req("count", null, {}, "GET"));
  eq(calls.length, 1);
  t = 61_000; await h(req("count", null, {}, "GET"));
  eq(calls.length, 2);
});

Deno.test("response does not wait for the email provider (latency cannot reveal 'new address')", async () => {
  const { f } = fakeFetch({ resend: "slow" });
  const t0 = Date.now();
  const r = await makeHandler(deps(f))(req("signup", goodBody()));
  const ms = Date.now() - t0;
  eq(r.status, 202);
  assert(ms < 200, `answered in ${ms}ms while the provider takes 400ms`);
  await settle();
});

// ------------------------------------------------------------------ 0005 safety net: /drain + owner alerts
const CRON = "c".repeat(40);
const cronCfg: Config = { ...cfg, cronSecret: CRON, alertTo: "owner@example.com" };
const SEND = { email: "queued@example.com", token: TOKEN, signup_id: "22222222-2222-4222-8222-222222222222", send_no: 1, hour: "2026-11-06T10:00:00Z" };
const drainReq = (key?: string) => req("drain", {}, key === undefined ? { "content-type": "application/json" } : { "content-type": "application/json", "x-cron-key": key });

Deno.test("drain: invisible without CRON_SECRET, and with a wrong/missing key (404 like any unknown route)", async () => {
  const { f, calls } = fakeFetch();
  eq((await makeHandler(deps(f))(drainReq(CRON))).status, 404, "not configured");
  const h = makeHandler({ ...deps(f), cfg: cronCfg });
  eq((await h(drainReq())).status, 404, "no key");
  eq((await h(drainReq("c".repeat(39) + "d"))).status, 404, "wrong key");
  eq((await h(drainReq(CRON + "x"))).status, 404, "longer key");
  eq(calls.filter((c) => c.url.includes("/rpc/")).length, 0, "no database call without the right key");
});

Deno.test("drain: sends each queued person their confirmation, then emails the owner the alerts (counts only)", async () => {
  const alerts = [{ kind: "global_send_cap", period: "2026-11-06T10:00:00Z", hits: 7, first_at: "2026-11-06T10:01:00Z", last_at: "2026-11-06T10:40:00Z" }];
  const { f, calls } = fakeFetch({ rpc: { waitlist_drain_queue: { sends: [SEND, { ...SEND, email: "q2@example.com", signup_id: "33333333-3333-4333-8333-333333333333" }], left: 4, paused: false },
                                          waitlist_take_alerts: alerts } });
  const res = await makeHandler({ ...deps(f), cfg: cronCfg })(drainReq(CRON));
  eq(res.status, 200);
  const out = await res.json();
  eq([out.sent, out.failed, out.left, out.alerts], [2, 0, 4, 1]);
  const mails = calls.filter((c) => c.url.startsWith("https://api.resend.com")).map((c) => JSON.parse(c.body!));
  eq(mails.map((m) => m.to[0]), ["queued@example.com", "q2@example.com", "owner@example.com"]);
  assert(mails[0].text.includes(`/confirm#t=${TOKEN}`), "queued person gets the normal fragment link");
  const alert = mails[2];
  assert(alert.text.includes("7 time(s)") && alert.text.includes("waiting in the queue: 4"), "alert has the counts");
  assert(!alert.text.includes("queued@example.com") && !alert.text.includes("q2@example.com"), "alert never contains a visitor's address");
});

Deno.test("drain: provider down -> units given back, the rest of the batch is not waited on", async () => {
  const { f, calls } = fakeFetch({ resend: "down", rpc: { waitlist_drain_queue: { sends: [SEND, SEND, SEND], left: 0, paused: false }, waitlist_take_alerts: [] } });
  const out = await (await makeHandler({ ...deps(f), cfg: cronCfg })(drainReq(CRON))).json();
  eq([out.sent, out.failed], [0, 3]);
  eq(calls.filter((c) => c.url.startsWith("https://api.resend.com")).length, 1, "only ONE attempt at the provider");
  eq(calls.filter((c) => c.url.endsWith("/waitlist_send_failed")).length, 3, "all three units given back");
});

Deno.test("drain: a malformed row from the database is skipped, never mailed", async () => {
  const { f, calls } = fakeFetch({ rpc: { waitlist_drain_queue: { sends: [{ ...SEND, email: "x@y.com\r\nBcc: a@b.com" }, { ...SEND, token: "short" }], left: 0, paused: true }, waitlist_take_alerts: [] } });
  const out = await (await makeHandler({ ...deps(f), cfg: cronCfg })(drainReq(CRON))).json();
  eq([out.sent, out.failed, out.paused], [0, 2, true]);
  eq(calls.filter((c) => c.url.startsWith("https://api.resend.com")).length, 0);
});

Deno.test("auto-pause alert is marked urgent and tells the owner how to resume", async () => {
  const { alertMail } = await import("../_shared/mailer.ts");
  const m = await alertMail(cfg, "owner@example.com", [
    { kind: "auto_paused", period: "2026-11-06T00:00:00Z", hits: 1, first_at: "2026-11-06T03:00:00Z", last_at: "2026-11-06T03:00:00Z" },
    { kind: "<script>", period: "x", hits: 1, first_at: "x", last_at: "x" }], 12, true);
  eq(m.subject, "Waitlist: sending PAUSED");
  assert(m.text.includes("waitlist_set_paused(false)"), "resume instruction");
  assert(!m.text.includes("<script>") && !m.html.includes("<script>"), "unknown alert kinds are dropped, never echoed");
  assert(/^alert\/[0-9a-f]{32}$/.test(m.idempotencyKey), "re-running the job never sends the same alert twice");
});

Deno.test("config: CRON_SECRET must be long and header-safe; ALERT_TO must be a plain address", () => {
  const base: Record<string, string> = { SUPABASE_URL: "https://r.supabase.co", SITE_ORIGIN: ORIGIN, WAITLIST_FUNCTION_URL: "https://r/f",
    TURNSTILE_SECRET: "s", TURNSTILE_HOSTNAMES: "waitlist.example.com", RESEND_API_KEY: "re_x", MAIL_FROM: "a <a@b.com>", CONSENT_VERSION: "v1",
    SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_abc" }) };
  eq(loadConfig((n) => base[n]).cronSecret, undefined, "optional: off by default");
  eq(loadConfig((n) => (n === "CRON_SECRET" ? CRON : base[n])).cronSecret, CRON);
  eq(loadConfig((n) => (n === "ALERT_TO" ? " Owner@Example.com " : base[n])).alertTo, "owner@example.com");
  for (const [k, v] of [["CRON_SECRET", "short"], ["CRON_SECRET", "a".repeat(40) + "\r\nx"], ["CRON_SECRET", "a".repeat(40) + " b"],
                        ["ALERT_TO", "owner@example.com\r\nBcc: x@y.com"], ["ALERT_TO", "Owner <o@example.com>"]]) {
    let threw = false;
    try { loadConfig((n) => (n === k ? v : base[n])); } catch (e) { threw = e instanceof ConfigError; }
    assert(threw, `${k}=${JSON.stringify(v)} must be refused`);
  }
});


// ------------------------------------------------------------------ partner applications (0006-0009)
const cfgP: Config = { ...cfg, alertTo: "owner@example.com", mailReplyTo: "create@example.com" };
const depsP = (f: typeof fetch, c: Config = cfgP) => ({ cfg: c, fetchFn: f, background: (p: Promise<unknown>) => { pending.push(p); } });
const partnerBody = () => ({ name: "Sara Ali", email: " Sara@Example.com ", handles: [{ platform: "tiktok", username: "@sara.fit" }],
  pitch: "Personal trainer, 20k followers. I can post 2 reviews a month.", consent: true, age_18_plus: true,
  consent_version: "partners-v1", website: "", elapsed_ms: 9000, turnstile: "partner-token-xxxxxxxx" });
const pconfirm = (t: unknown = "P".repeat(43), ts = "pconfirm-token-xxxxxxxx") => req("partner-confirm", { token: t, turnstile: ts });
const mails = (calls: Call[]) => calls.filter((c) => c.url.startsWith("https://api.resend.com")).map((c) => ({
  key: (c.init!.headers as Record<string, string>)["idempotency-key"], ...JSON.parse(c.body!) }));
const ZWSP = String.fromCodePoint(0x200b), RLO = String.fromCodePoint(0x202e);   // built from code points, never raw
const PID = "22222222-2222-4222-8222-222222222222";

Deno.test("partner apply: Turnstile(partner_apply) first, then ONE fixed confirmation email; the owner is NOT told yet", async () => {
  const { f, calls } = fakeFetch();
  const res = await makeHandler(depsP(f))(req("partner", partnerBody()));
  eq(res.status, 202);
  eq(await res.json(), { ok: true, message: "check_inbox" });
  await settle();
  const order = calls.map((c) => c.url.includes("cloudflare") ? "ts" : c.url.includes("rpc") ? c.url.split("/").pop() : "mail");
  eq(order, ["ts", "waitlist_partner_apply", "mail"], "Turnstile before the database; exactly ONE email");
  const args = JSON.parse(calls.find((c) => c.url.endsWith("/rpc/waitlist_partner_apply"))!.body!);
  eq(args.p_email, "sara@example.com");
  const [m] = mails(calls);
  eq(m.to, ["sara@example.com"]);
  eq(m.subject, "Confirm your application");
  eq(m.key, `partner-confirm/${PID}/1`);
  eq(m.reply_to, "create@example.com");
  assert(m.text.includes(`${ORIGIN}/partners-confirm#t=${"P".repeat(43)}`), "token in the fragment");
  assert(m.html.includes(`href="${ORIGIN}/partners-confirm#t=${"P".repeat(43)}"`), "HTML button uses the fragment link");
  for (const typed of ["Sara", "sara.fit", "20k", "tiktok", "sara@example.com"]) {
    assert(!(m.subject + m.text + m.html).includes(typed), `confirmation email must not echo visitor text: ${typed}`);
  }
  eq([...m.html.matchAll(/<img[^>]+src="([^"]+)"/g)].map((x) => x[1]), [`${ORIGIN}/email-logo.png`], "no tracking image");
});

Deno.test("the confirmation email is byte-identical whatever the visitor typed (one standard email for everyone)", async () => {
  const run = async (extra: Record<string, unknown>) => {
    const { f, calls } = fakeFetch();
    await makeHandler(depsP(f))(req("partner", { ...partnerBody(), ...extra }));
    await settle();
    const a = mails(calls)[0];
    return JSON.stringify([a.subject, a.text, a.html]);
  };
  eq(await run({ name: "Buy Cheap Pills Now", pitch: "VISIT OUR SHOP FOR 90% OFF TODAY ONLY!!!" }), await run({}), "spam text never reaches the applicant");
});

Deno.test("partner confirm: only via POST + Origin + Turnstile(partner_confirm); then the owner gets the details", async () => {
  const { f, calls } = fakeFetch();
  const h = makeHandler(depsP(f));
  const r = await h(pconfirm());
  eq(r.status, 200); eq(await r.json(), { ok: true });
  await settle();
  const ts = calls.find((c) => c.url.includes("cloudflare"))!;
  eq((ts.init!.body as FormData).get("response"), "pconfirm-token-xxxxxxxx");
  eq(JSON.parse(calls.find((c) => c.url.endsWith("/rpc/waitlist_partner_confirm"))!.body!).p_token, "P".repeat(43));
  const [owner] = mails(calls);
  eq(owner.to, ["owner@example.com"]);
  eq(owner.subject, "New partner application", "fixed subject: no visitor text in a header");
  eq(owner.reply_to, "sara@example.com", "Reply answers the (now confirmed) applicant");
  eq(owner.key, `partner-owner/${PID}`);
  assert(owner.text.includes("Name (unverified): Sara Ali") && owner.text.includes("tiktok (unverified): @sara.fit"));
  // refusals
  eq((await h(new Request(`https://ref.supabase.co/functions/v1/waitlist/partner-confirm`))).status, 405, "GET never confirms (link scanners)");
  eq((await h(req("partner-confirm", { token: "P".repeat(43), turnstile: "x" }, { origin: "https://evil.example", "content-type": "application/json" }))).status, 403);
  eq((await h(pconfirm("P".repeat(43), "partner-token-xxxxxxxx"))).status, 400, "an APPLY captcha token cannot confirm");
  eq((await h(pconfirm("P".repeat(43), "signup-token-xxxxxxxx"))).status, 400, "a waitlist captcha token cannot confirm");
  eq((await h(req("partner-confirm", { token: "P".repeat(43), turnstile: "pconfirm-token-xxxxxxxx", extra: 1 }))).status, 400);
  const { f: f2, calls: c2 } = fakeFetch();
  eq(await (await makeHandler(depsP(f2))(pconfirm("short"))).json(), { ok: false }, "malformed token: refused before Turnstile and the database");
  eq(c2.length, 0);
});

Deno.test("partner confirm: invalid / expired / used token -> same {ok:false}, no email", async () => {
  const { f, calls } = fakeFetch({ rpc: { waitlist_partner_confirm: { ok: false } } });
  const r = await makeHandler(depsP(f))(pconfirm());
  eq(await r.json(), { ok: false });
  await settle();
  eq(mails(calls).length, 0);
});

Deno.test("partner confirm: queued (cap full / paused) -> ok for the visitor, no email now", async () => {
  const { f, calls } = fakeFetch({ rpc: { waitlist_partner_confirm: { ok: true, action: "queued" } } });
  eq(await (await makeHandler(depsP(f))(pconfirm())).json(), { ok: true });
  await settle();
  eq(mails(calls).length, 0);
});

Deno.test("partner confirm: a stored row that breaks the form rules is never mailed; its unit is given back", async () => {
  const { f, calls } = fakeFetch({ rpc: { waitlist_partner_confirm: { ok: true, action: "send", id: PID, hour: "2026-11-18T10:00:00Z",
    email: "x@y.com\r\nBcc: a@b.com", name: "Sara", handles: [{ platform: "tiktok", username: "a" }], pitch: "long enough text" } } });
  await makeHandler(depsP(f))(pconfirm());
  await settle();
  eq(mails(calls).length, 0);
  eq(calls.filter((c) => c.url.endsWith("/rpc/waitlist_send_failed")).length, 1);
});

Deno.test("partner: owner email escapes HTML and marks every applicant field as unverified (audit #14)", async () => {
  const { f, calls } = fakeFetch({ rpc: { waitlist_partner_confirm: { ok: true, action: "send", id: PID, hour: "2026-11-18T10:00:00Z",
    email: "sara@example.com", name: "Sara Ali", handles: [{ platform: "tiktok", username: "@sara.fit" }],
    pitch: "<img src=x onerror=alert(1)> Your account is locked, log in at evil dot example." } } });
  await makeHandler(depsP(f))(pconfirm());
  await settle();
  const owner = mails(calls)[0];
  assert(!owner.html.includes("<img"), "no live markup");
  assert(owner.html.includes("&lt;img src=x onerror=alert(1)&gt;"), "shown escaped");
  assert(owner.text.startsWith("New partner application") && owner.text.indexOf("UNVERIFIED") < owner.text.indexOf("Your account is locked"));
  for (const label of ["Name (unverified):", "Email (unverified):", "tiktok (unverified):"]) assert(owner.text.includes(label), label);
});

Deno.test("partner apply answers are byte-identical for new / pending / applied / suppressed / limited / queued / bot", async () => {
  const bodies: string[] = [];
  for (const r of [undefined, { action: "none", reason: "already_applied" }, { action: "none", reason: "suppressed" },
                   { action: "none", reason: "too_soon" }, { action: "none", reason: "address_cap" }, { action: "none", reason: "mailbox_cap" },
                   { action: "saved", reason: "send_cap", queued: true }]) {
    const { f } = fakeFetch(r ? { rpc: { waitlist_partner_apply: r } } : {});
    const res = await makeHandler(depsP(f))(req("partner", partnerBody()));
    eq(res.status, 202); bodies.push(await res.text());
  }
  const { f, calls } = fakeFetch();
  bodies.push(await (await makeHandler(depsP(f))(req("partner", { ...partnerBody(), website: "http://spam" }))).text());
  bodies.push(await (await makeHandler(depsP(f))(req("partner", { ...partnerBody(), elapsed_ms: 300 }))).text());
  eq(calls.length, 0, "bot traps: nothing called at all");
  eq(new Set(bodies).size, 1, "every answer is the same");
  await settle();
});

Deno.test("partner: refused applications get NO email", async () => {
  for (const reason of ["already_applied", "suppressed", "too_soon", "address_cap", "mailbox_cap"]) {
    const { f, calls } = fakeFetch({ rpc: { waitlist_partner_apply: { action: "none", reason } } });
    await makeHandler(depsP(f))(req("partner", partnerBody()));
    await settle();
    eq(mails(calls).length, 0, reason);
  }
});

Deno.test("partner refusals: bad fields never reach Turnstile or the database", async () => {
  const bad: Record<string, unknown>[] = [
    { name: "Visit http://spam.example" }, { name: "www.spam.com" }, { name: "a@b.com" }, { name: "x".repeat(81) }, { name: "" },
    { name: "Sara" + ZWSP + "Ali" }, { name: "Sara" + RLO + "ilA" },
    { handles: [] }, { handles: "tiktok" }, { handles: [{ platform: "myspace", username: "a" }] },
    { handles: [{ platform: "tiktok", username: "https://evil.example" }] }, { handles: [{ platform: "tiktok", username: "a", x: 1 }] },
    { handles: [1, 2, 3, 4].map((i) => ({ platform: "x", username: "u" + i })) },
    { pitch: "short" }, { pitch: "x".repeat(1001) }, { pitch: "hello there" + ZWSP + " friend" },
  ];
  for (const b of bad) {
    const { f, calls } = fakeFetch();
    const r = await makeHandler(depsP(f))(req("partner", { ...partnerBody(), ...b }));
    eq(r.status, 400, JSON.stringify(b).slice(0, 60));
    eq((await r.json()).error, "invalid_fields");
    eq(calls.length, 0, "refused before any outside call");
  }
});

Deno.test("partner refusals: origin, consent, age 18, version, extra keys, size, captcha action, daily cap", async () => {
  const h = (o = {}) => makeHandler(depsP(fakeFetch(o).f));
  eq((await h()(req("partner", partnerBody(), { origin: "https://evil.example", "content-type": "application/json" }))).status, 403);
  eq((await h()(req("partner", { ...partnerBody(), consent: false }))).status, 400);
  eq((await h()(req("partner", { ...partnerBody(), consent: "true" }))).status, 400, "only literal true");
  eq((await h()(req("partner", { ...partnerBody(), age_18_plus: false }))).status, 400);
  const { age_18_plus: _drop, ...no18 } = partnerBody();
  eq((await h()(req("partner", { ...no18, age_16_plus: true }))).status, 400, "the waitlist's 16+ box does not count");
  eq((await h()(req("partner", { ...partnerBody(), consent_version: "waitlist-v4" }))).status, 409);
  eq((await h()(req("partner", { ...partnerBody(), role: "admin" }))).status, 400, "unknown keys refused");
  eq((await h()(req("partner", JSON.stringify({ ...partnerBody(), pitch: "x".repeat(9000) })))).status, 413);
  eq((await h()(req("partner", { ...partnerBody(), turnstile: "signup-token-xxxxxxxx" }))).status, 400, "a signup captcha token cannot be reused here");
  eq((await h()(req("partner", { ...partnerBody(), turnstile: "pconfirm-token-xxxxxxxx" }))).status, 400, "a confirm captcha token cannot apply");
  eq((await h()(req("partner", partnerBody(), {}, "GET"))).status, 405);
  const busy = await h({ rpc: { waitlist_partner_apply: { action: "none", reason: "busy" } } })(req("partner", partnerBody()));
  eq(busy.status, 429); eq((await busy.json()).error, "busy");
  eq((await h({ rpc: { waitlist_partner_apply: { action: "none", reason: "stale_consent_version" } } })(req("partner", partnerBody()))).status, 409);
  await settle();
});

Deno.test("partner: provider unreachable -> unit refunded and the application requeued (nothing lost); 500 -> no refund", async () => {
  const { f, calls } = fakeFetch({ resend: "down" });
  eq((await makeHandler(depsP(f))(req("partner", partnerBody()))).status, 202);
  await settle();
  eq(calls.filter((c) => c.url.endsWith("/rpc/waitlist_send_failed")).length, 1);
  eq(calls.filter((c) => c.url.endsWith("/rpc/waitlist_partner_requeue")).map((c) => JSON.parse(c.body!).p_id), [PID]);
  const { f: f2, calls: c2 } = fakeFetch({ resend: 500 });
  await makeHandler(depsP(f2))(pconfirm());
  await settle();
  eq(c2.filter((c) => c.url.endsWith("/rpc/waitlist_send_failed")).length, 0, "provider answered: it may have sent, no refund");
});

Deno.test("partner: without ALERT_TO a confirmed application sends nothing and its unit is refunded", async () => {
  const { f, calls } = fakeFetch();
  await makeHandler(depsP(f, { ...cfgP, alertTo: undefined }))(pconfirm());
  await settle();
  eq(mails(calls).length, 0);
  eq(calls.filter((c) => c.url.endsWith("/rpc/waitlist_send_failed")).length, 1);
});

Deno.test("audit #15: a refused requeue (queue full) is logged, not silent", async () => {
  const lines: string[] = [];
  const orig = console.log;
  console.log = (s: string) => { lines.push(String(s)); };
  try {
    const { f } = fakeFetch({ resend: "down", rpc: { waitlist_partner_requeue: false } });
    await makeHandler(depsP(f))(req("partner", partnerBody()));
    await settle();
  } finally { console.log = orig; }
  assert(lines.some((l) => l.includes('"requeue_failed"')), "requeue_failed is in the log");
});

// ------------------------------------------------------------------ partner mail queue (0007 + 0009)
const cronP: Config = { ...cfgP, cronSecret: CRON };
const QCONF = { kind: "confirm", id: "44444444-4444-4444-8444-444444444444", email: "queued.partner@example.com", token: "Q".repeat(43), send_no: 1, hour: "2026-11-18T11:00:00Z" };
const QOWNER = { kind: "owner", id: "55555555-5555-4555-8555-555555555555", email: "omar@example.com", name: "Omar K",
  handles: [{ platform: "instagram", username: "omar.lifts" }], pitch: "Coach with a small but loyal community.", hour: "2026-11-18T11:00:00Z" };

Deno.test("drain: queued partner rows send ONE email each (confirmation link or owner notice), after the waitlist queue", async () => {
  const { f, calls } = fakeFetch({ rpc: { waitlist_drain_queue: { sends: [SEND], left: 0, paused: false },
    waitlist_drain_partner_queue: { sends: [QCONF, QOWNER], left: 3, paused: false }, waitlist_take_alerts: [] } });
  const out = await (await makeHandler(depsP(f, cronP))(drainReq(CRON))).json();
  eq([out.sent, out.partner_sent, out.partner_failed, out.partner_left], [1, 2, 0, 3]);
  const m = mails(calls);
  eq(m.map((x) => x.to[0]), ["queued@example.com", "queued.partner@example.com", "owner@example.com"], "waitlist first");
  eq(m[1].subject, "Confirm your application");
  assert(m[1].text.includes(`/partners-confirm#t=${"Q".repeat(43)}`));
  eq(m[1].key, "partner-confirm/44444444-4444-4444-8444-444444444444/1");
  eq(m[2].subject, "New partner application");
  eq(m[2].reply_to, "omar@example.com");
});

Deno.test("drain: a partner row that breaks the rules is never mailed", async () => {
  const bad = [{ ...QOWNER, name: "Visit http://spam.example" }, { ...QCONF, email: "x@y.com\r\nBcc: a@b.com" }, { ...QCONF, token: "short" },
               { ...QOWNER, handles: [{ platform: "tiktok", username: "https://evil" }] }, { ...QOWNER, id: "not-a-uuid" }, { ...QOWNER, kind: "other" }];
  const { f, calls } = fakeFetch({ rpc: { waitlist_drain_queue: { sends: [], left: 0, paused: false },
    waitlist_drain_partner_queue: { sends: bad, left: 0, paused: false }, waitlist_take_alerts: [] } });
  const out = await (await makeHandler(depsP(f, cronP))(drainReq(CRON))).json();
  eq([out.partner_sent, out.partner_failed], [0, 6]);
  eq(mails(calls).length, 0);
});

Deno.test("drain: provider down mid-run -> units refunded and EVERY partner row put back in the queue", async () => {
  const ids = ["44444444-4444-4444-8444-444444444444", "66666666-6666-4666-8666-666666666666", "77777777-7777-4777-8777-777777777777"];
  const { f, calls } = fakeFetch({ resend: "down", rpc: { waitlist_drain_queue: { sends: [], left: 0, paused: false },
    waitlist_drain_partner_queue: { sends: ids.map((id) => ({ ...QCONF, id })), left: 0, paused: false }, waitlist_take_alerts: [] } });
  const out = await (await makeHandler(depsP(f, cronP))(drainReq(CRON))).json();
  eq([out.partner_sent, out.partner_failed, out.partner_left], [0, 3, 3]);
  eq(mails(calls).length, 1, "only ONE attempt at the provider");
  eq(calls.filter((c) => c.url.endsWith("/rpc/waitlist_send_failed")).length, 3);
  eq(calls.filter((c) => c.url.endsWith("/rpc/waitlist_partner_requeue")).map((c) => JSON.parse(c.body!).p_id), ids);
});

Deno.test("drain: provider already down for the waitlist -> the partner queue is not touched this run", async () => {
  const { f, calls } = fakeFetch({ resend: "down", rpc: { waitlist_drain_queue: { sends: [SEND], left: 0, paused: false },
    waitlist_drain_partner_queue: { sends: [QCONF], left: 1, paused: false }, waitlist_take_alerts: [] } });
  await makeHandler(depsP(f, cronP))(drainReq(CRON));
  eq(calls.filter((c) => c.url.endsWith("/rpc/waitlist_drain_partner_queue")).length, 0);
});

// ------------------------------------------------------------------ 0008 / Codex audit fixes (non-partner)
Deno.test("audit #13: database on another consent version -> 409 reload_page, never a false 'check your inbox'", async () => {
  const { f, calls } = fakeFetch({ rpc: { waitlist_signup: { action: "none", reason: "stale_consent_version" } } });
  const r = await makeHandler(deps(f))(req("signup", goodBody()));
  eq(r.status, 409); eq((await r.json()).error, "reload_page");
  await settle();
  eq(calls.filter((c) => c.url.startsWith("https://api.resend.com")).length, 0);
});

Deno.test("audit #12: 20 simultaneous /count requests on a cold cache start ONE database query", async () => {
  const { f, calls } = fakeFetch();
  const h = makeHandler(deps(f));
  const rs = await Promise.all(Array.from({ length: 20 }, () => h(req("count", null, {}, "GET"))));
  assert(rs.every((r) => r.status === 200));
  eq(calls.filter((c) => c.url.endsWith("/rpc/waitlist_public_count")).length, 1);
});

Deno.test("audit #23: letters that lowercase INTO ascii (Kelvin sign, dotted capital I, long s) are refused, not folded", () => {
  for (const cp of [0x212a, 0x0130, 0x017f]) throwsCode(() => normalizeEmail(String.fromCodePoint(cp) + "ate@example.com"), "invalid_email");
  eq(normalizeEmail("  Kate@Example.com "), "kate@example.com", "plain ASCII still works");
});

// ------------------------------------------------------------------ Codex re-check fixes
Deno.test("re-check #2: a waitlist address deleted/bounced (or a pause) after the batch was claimed is NOT emailed", async () => {
  for (const verdict of ["suppressed", "paused"]) {
    const { f, calls } = fakeFetch({ rpc: { waitlist_drain_queue: { sends: [SEND], left: 0, paused: false },
      waitlist_send_allowed: verdict, waitlist_take_alerts: [] } });
    const out = await (await makeHandler(depsP(f, cronP))(drainReq(CRON))).json();
    eq([out.sent, out.failed], [0, 1], verdict);
    eq(mails(calls).length, 0, `${verdict}: nothing handed to the provider`);
    eq(calls.filter((c) => c.url.endsWith("/rpc/waitlist_send_failed")).length, 1, `${verdict}: the unit is given back`);
  }
});

Deno.test("re-check #2: a queued partner email checks again right before the send (paused -> back in the queue, deleted -> dropped)", async () => {
  const run = async (verdict: string) => {
    const { f, calls } = fakeFetch({ rpc: { waitlist_drain_queue: { sends: [], left: 0, paused: false },
      waitlist_drain_partner_queue: { sends: [QCONF, QOWNER], left: 0, paused: false }, waitlist_send_allowed: verdict, waitlist_take_alerts: [] } });
    const out = await (await makeHandler(depsP(f, cronP))(drainReq(CRON))).json();
    return { out, mails: mails(calls).length, requeues: calls.filter((c) => c.url.endsWith("/rpc/waitlist_partner_requeue")).length,
             refunds: calls.filter((c) => c.url.endsWith("/rpc/waitlist_send_failed")).length };
  };
  const p = await run("paused");
  eq([p.mails, p.requeues, p.refunds, p.out.partner_left], [0, 2, 2, 2], "paused: nothing sent, both back in the queue");
  const s = await run("suppressed");
  eq([s.mails, s.requeues, s.refunds], [0, 0, 2], "deleted/bounced: nothing sent, nothing requeued");
  const broken = await run("garbage");
  eq(broken.mails, 0, "an unexpected answer fails closed");
});

Deno.test("re-check R6: a refused requeue is not counted as waiting", async () => {
  const ids = ["44444444-4444-4444-8444-444444444444", "66666666-6666-4666-8666-666666666666"];
  const { f } = fakeFetch({ resend: "down", rpc: { waitlist_drain_queue: { sends: [], left: 0, paused: false },
    waitlist_drain_partner_queue: { sends: ids.map((id) => ({ ...QCONF, id })), left: 0, paused: false },
    waitlist_partner_requeue: false, waitlist_take_alerts: [] } });
  const out = await (await makeHandler(depsP(f, cronP))(drainReq(CRON))).json();
  eq(out.partner_left, 0, "queue refused them: not reported as waiting");
});
