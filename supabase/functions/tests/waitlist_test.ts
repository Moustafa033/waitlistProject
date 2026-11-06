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
  for (const bad of ["victim@example.com\r\nBcc: x@y.com", "a​@example.com", "a@exаmple.com" /* cyrillic а */,
    "a@b", "a@@b.com", ".a@b.com", "a.@b.com", "a..b@c.com", "\"a b\"@c.com", "=cmd|' /C calc'!A0@x.com",
    "a@-b.com", "a@b-.com", "a@b.c0m", "x".repeat(65) + "@a.com", 42, null]) {
    throwsCode(() => normalizeEmail(bad), "invalid_email");
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
  for (const [k, v] of [["SUPABASE_SECRET_KEYS", JSON.stringify({ default: "eyJhbGciOi..." })], ["SITE_ORIGIN", "*"], ["SITE_ORIGIN", "http://evil.com"], ["RESEND_API_KEY", "sk_live"]]) {
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
  const order = calls.map((c) => c.url.includes("cloudflare") ? "ts" : c.url.includes("rpc") ? "rpc" : "mail");
  eq(order, ["ts", "rpc", "mail"], "Turnstile must run BEFORE the database");
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

Deno.test("internal errors never leak details", async () => {
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
