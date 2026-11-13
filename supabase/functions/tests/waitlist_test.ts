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
      const action = fd.get("response") === "confirm-token" ? "waitlist_confirm" : "waitlist_signup";
      return Response.json(opts.turnstile ?? { success: true, hostname: "waitlist.example.com", action });
    }
    if (url.includes("/rest/v1/rpc/")) {
      const name = url.split("/").pop()!;
      const def: Record<string, unknown> = {
        waitlist_signup: { action: "send", token: TOKEN, signup_id: "11111111-1111-4111-8111-111111111111", send_no: 1, hour: "2026-11-06T10:00:00Z" },
        waitlist_confirm: { ok: true }, waitlist_unsubscribe: { ok: true }, waitlist_public_count: 1230,
        waitlist_send_failed: null, waitlist_suppress: null,
        waitlist_unsub_token: "U".repeat(43), waitlist_erase_by_token: { ok: true },
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
