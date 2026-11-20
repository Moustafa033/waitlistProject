// The ONE public endpoint of the waitlist (deployed with verify_jwt = false,
// because visitors have no account). Everything it does is bounded:
//   POST /signup       browser only (exact Origin) + Turnstile + honeypot + validation
//   POST /partner      "Work with us" application: same protections; stored pending, confirmation link emailed
//   POST /partner-confirm  the applicant presses "Confirm application": only then it counts and the owner is told
//   POST /confirm      browser only, called by the explicit "Confirm" button (never on GET)
//   POST /unsubscribe  RFC 8058 one-click (mail providers, no Origin) or our page
//   GET  /count        coarse public counter, cacheable
//   POST /drain        scheduled job only (secret header): sends the queue, emails owner alerts.
//                      Without CRON_SECRET configured it does not exist (404).
// Every signup answer is the SAME 202 whether the email is new, pending,
// confirmed, suppressed, rate-limited or a detected bot (no enumeration, no
// feedback that teaches a bot what worked).
import type { Config } from "../_shared/env.ts";
import { corsHeaders, decodeUtf8, HttpError, json, log, onlyKeys, parseJsonObject, readBodyCapped, requireOrigin } from "../_shared/http.ts";
import { isDisposable, isToken, isUuid, normalizeEmail, partnerHandles, partnerName, partnerPitch } from "../_shared/validate.ts";
import { verifyTurnstile } from "../_shared/turnstile.ts";
import { rpc } from "../_shared/db.ts";
import { alertMail, type Alert, confirmationMail, type Mail, partnerConfirmMail, partnerOwnerMail, type PartnerApp, ProviderNotReached, sendMail } from "../_shared/mailer.ts";
import { safeEqual } from "../_shared/svix.ts";
import { DISPOSABLE } from "../_shared/disposable.ts";

export interface Deps {
  cfg: Config;
  fetchFn: typeof fetch;
  /** Runs work AFTER the response is sent (Supabase: EdgeRuntime.waitUntil). Sending the
   *  email in the background keeps the response time the same whether or not an email is
   *  sent — otherwise latency would reveal whether an address is already on the list. */
  background: (p: Promise<unknown>) => void;
  now?: () => number;
}

const ACCEPTED = { ok: true, message: "check_inbox" } as const;
const LOCALES = /^[a-z]{2}(-[A-Z]{2})?$/;

export function makeHandler(d: Deps): (req: Request) => Promise<Response> {
  const { cfg } = d;
  const cors = corsHeaders(cfg.siteOrigin);

  async function signup(req: Request): Promise<Response> {
    requireOrigin(req, cfg.siteOrigin);
    if (!(req.headers.get("content-type") ?? "").startsWith("application/json")) throw new HttpError(415, "invalid_body");
    const body = parseJsonObject(await readBodyCapped(req, 4096));
    onlyKeys(body, ["email", "consent", "age_16_plus", "consent_version", "locale", "source", "website", "elapsed_ms", "turnstile"]);

    // bot traps: answer exactly like a success, do nothing
    if (typeof body.website === "string" && body.website !== "") return accepted("honeypot");
    if (typeof body.elapsed_ms !== "number" || body.elapsed_ms < cfg.minFillMs) return accepted("too_fast");

    // explicit, unticked-by-default consent + age (P-9/P-10). Literal true only.
    if (body.consent !== true || body.age_16_plus !== true) throw new HttpError(400, "consent_required");
    if (body.consent_version !== cfg.consentVersion) throw new HttpError(409, "reload_page"); // stale page text

    const email = normalizeEmail(body.email);
    if (isDisposable(email, DISPOSABLE)) throw new HttpError(400, "use_another_email");
    const locale = typeof body.locale === "string" && LOCALES.test(body.locale) ? body.locale : null;
    const source = typeof body.source === "string" && /^[a-z0-9_-]{1,32}$/.test(body.source) ? body.source : null;

    await verifyTurnstile(body.turnstile, { secret: cfg.turnstileSecret, hostnames: cfg.turnstileHostnames, action: "waitlist_signup", fetchFn: d.fetchFn });

    const r = await rpc<{ action: string; reason?: string; token?: string; signup_id?: string; send_no?: number; hour?: string }>(
      cfg, "waitlist_signup", { p_email: email, p_consent_version: cfg.consentVersion, p_locale: locale, p_source: source }, d.fetchFn);
    // Audit #13: the database is on another consent version than this function (a release mismatch).
    // Say so instead of "check your inbox"; it is about the release, never about the address.
    if (r.action === "none" && r.reason === "stale_consent_version") throw new HttpError(409, "reload_page");

    if (r.action === "send" && r.token && r.signup_id && r.send_no && r.hour) {
      const { token, signup_id, send_no, hour } = r;
      d.background(sendSignupConfirmation(email, token, signup_id, send_no, hour).then(() => {}));
    }
    return accepted(r.action === "send" ? "sent" : (r.reason ?? "none"));
  }

  /** The ONE path for a waitlist confirmation email, live or queued. Order (re-check 3 #1):
   *    1. prepare everything the email needs (the unsubscribe link);
   *    2. LAST step before the provider: ask the database whether THIS exact link may still be sent
   *       (address not on the do-not-email list, sending not paused, signup still pending, and the
   *       link in this email is still the signup's current, unexpired link);
   *    3. hand it to the provider.
   *  Whenever the email was NOT handed over (prepare failed, paused, provider not reached) the send
   *  unit is refunded and the signup goes back in the queue with its allowance restored (re-check 3
   *  #2), so the retry is the same email: same link, same idempotency key.
   *  Returns "sent", "down" (provider not reached), "held" (kept for later), "cancelled" (deleted,
   *  unsubscribed, bounced, replaced by a newer email) or "failed" (the provider answered with an error). */
  async function sendSignupConfirmation(email: string, token: string, signupId: string, sendNo: number, hour: string):
      Promise<"sent" | "down" | "held" | "cancelled" | "failed"> {
    const refund = () => rpc(cfg, "waitlist_send_failed", { p_hour: hour }, d.fetchFn).catch(() => {});
    const keep = async () => {
      await refund();
      const ok = await rpc<boolean>(cfg, "waitlist_signup_requeue", { p_signup_id: signupId, p_token: token }, d.fetchFn).catch(() => false);
      if (ok !== true) log("waitlist.mail", 500, "requeue_failed");
    };
    let mail: Mail;
    try {
      const unsubToken = await rpc<string>(cfg, "waitlist_unsub_token", { p_signup_id: signupId }, d.fetchFn);
      if (!isToken(unsubToken)) throw new Error("unsub token");
      mail = confirmationMail(cfg, email, token, signupId, sendNo, unsubToken);
    } catch {
      await keep();
      log("waitlist.mail", 500, "prepare_failed");
      return "held";
    }
    const allowed = await sendAllowed(email, "signup", signupId, token);
    if (allowed !== "ok") {
      if (allowed === "paused") await keep(); else await refund();
      log("waitlist.mail", 200, allowed === "paused" ? "held" : allowed);
      return allowed === "paused" ? "held" : "cancelled";
    }
    try {
      await sendMail(cfg, mail, d.fetchFn);
      log("waitlist.mail", 200, "sent");
      return "sent";
    } catch (e) {
      log("waitlist.mail", 500, "mail_failed");
      if (e instanceof ProviderNotReached) { await keep(); return "down"; }
      return "failed";
    }
  }

  function accepted(reason: string): Response {
    log("waitlist.signup", 202, reason);   // reason is internal metrics only
    return json(202, ACCEPTED, cors);
  }

  // "Work with us" (site/partners.html). Same protections as signup. Since 0009 an application only
  // counts once the applicant confirms the email address (audit #1): this route stores it as pending
  // and emails ONE fixed confirmation link. The visitor gets the SAME 202 for new / pending / already
  // applied / suppressed / limited / bot. Only "busy" (the site-wide daily cap, decided before anything
  // about the address) is said out loud: it reveals nothing about any person.
  const PARTNER_OK = { ok: true, message: "check_inbox" } as const;
  async function partner(req: Request): Promise<Response> {
    requireOrigin(req, cfg.siteOrigin);
    if (!(req.headers.get("content-type") ?? "").startsWith("application/json")) throw new HttpError(415, "invalid_body");
    const body = parseJsonObject(await readBodyCapped(req, 8192));
    onlyKeys(body, ["email", "name", "handles", "pitch", "consent", "age_18_plus", "consent_version", "website", "elapsed_ms", "turnstile"]);
    const done = (reason: string) => { log("waitlist.partner", 202, reason); return json(202, PARTNER_OK, cors); };

    if (typeof body.website === "string" && body.website !== "") return done("honeypot");
    if (typeof body.elapsed_ms !== "number" || body.elapsed_ms < cfg.minFillMs) return done("too_fast");
    if (body.consent !== true || body.age_18_plus !== true) throw new HttpError(400, "consent_required");
    if (typeof body.consent_version !== "string" || !/^partners-v[0-9]{1,3}$/.test(body.consent_version)) throw new HttpError(409, "reload_page");

    const email = normalizeEmail(body.email);
    if (isDisposable(email, DISPOSABLE)) throw new HttpError(400, "use_another_email");
    const app = { email, name: partnerName(body.name), handles: partnerHandles(body.handles), pitch: partnerPitch(body.pitch) };

    await verifyTurnstile(body.turnstile, { secret: cfg.turnstileSecret, hostnames: cfg.turnstileHostnames, action: "partner_apply", fetchFn: d.fetchFn });

    const r = await rpc<{ action: string; reason?: string; id?: string; token?: string; tag?: string; send_no?: number; hour?: string }>(cfg, "waitlist_partner_apply",
      { p_email: email, p_name: app.name, p_handles: app.handles, p_pitch: app.pitch, p_consent_version: body.consent_version }, d.fetchFn);
    if (r.action === "none" && r.reason === "stale_consent_version") throw new HttpError(409, "reload_page");
    if (r.action === "none" && r.reason === "invalid_fields") throw new HttpError(400, "invalid_fields");
    if (r.action === "none" && r.reason === "busy") throw new HttpError(429, "busy");

    if (r.action === "send" && r.id && isUuid(r.id) && isToken(r.token) && isTag(r.tag) && Number.isInteger(r.send_no) && r.hour) {
      d.background(sendPartnerConfirm(r.id, email, r.token, r.tag, r.send_no!, r.hour));
    }
    return done(r.action === "send" ? "sent" : (r.reason ?? r.action));
  }

  // The person pressed "Confirm application" on site/partners-confirm.html (never on GET: link scanners).
  // Only now does the application count, and only now is the owner told.
  async function partnerConfirm(req: Request): Promise<Response> {
    requireOrigin(req, cfg.siteOrigin);
    if (!(req.headers.get("content-type") ?? "").startsWith("application/json")) throw new HttpError(415, "invalid_body");
    const body = parseJsonObject(await readBodyCapped(req, 3072));
    onlyKeys(body, ["token", "turnstile"]);
    if (!isToken(body.token)) return json(200, { ok: false }, cors);
    await verifyTurnstile(body.turnstile, { secret: cfg.turnstileSecret, hostnames: cfg.turnstileHostnames, action: "partner_confirm", fetchFn: d.fetchFn });
    type R = { ok: boolean; action?: string; id?: string; hour?: string; email?: string; name?: string; handles?: unknown; pitch?: string };
    const r = await rpc<R>(cfg, "waitlist_partner_confirm", { p_token: body.token }, d.fetchFn);
    log("waitlist.partner_confirm", 200, r.ok ? (r.action ?? "confirmed") : "invalid_or_expired");
    if (r.ok === true && r.action === "send" && isUuid(r.id) && typeof r.hour === "string") {
      let app: PartnerApp | null = null;
      try {   // the stored row passes the same rules as the live form, or no email is built from it
        app = { email: normalizeEmail(r.email), name: partnerName(r.name), handles: partnerHandles(r.handles), pitch: partnerPitch(r.pitch) };
      } catch { log("waitlist.partner_mail", 500, "bad_row"); }
      if (app) d.background(sendPartnerOwner(r.id, r.hour, app));
      else await rpc(cfg, "waitlist_send_failed", { p_hour: r.hour }, d.fetchFn).catch(() => {});
    }
    return json(200, { ok: r.ok === true }, cors);
  }

  // Audit #15: a requeue that fails or is refused (queue full) is logged, never silent. The application
  // itself is always in the database, and the owner gets the partner_mail_skipped alert.
  // Returns whether the application is back in the queue (re-check R6: refusals are not counted as waiting).
  async function requeue(id: string, token?: string): Promise<boolean> {
    const ok = await rpc<boolean>(cfg, "waitlist_partner_requeue", { p_id: id, p_token: token ?? null }, d.fetchFn).catch(() => false);
    if (ok !== true) log("waitlist.partner_mail", 500, "requeue_failed");
    return ok === true;
  }

  // Asked right before EVERY email is handed to the provider, live or queued (re-check 2 #1): the
  // do-not-email list, the kill switch AND the current state of the signup / application the email is
  // about. Anything unexpected (error, odd answer) counts as "paused": the work is kept, nothing is sent.
  // `token` = the link inside the email (confirmation emails): the database checks it is still the
  // row's CURRENT link, so an email whose link was replaced or used is never sent (re-check 3 #1).
  async function sendAllowed(email: string, kind: "signup" | "partner_confirm" | "partner_owner", id: string, token?: string):
      Promise<"ok" | "paused" | "suppressed" | "cancelled"> {
    const v = await rpc<string>(cfg, "waitlist_send_allowed", { p_email: email, p_kind: kind, p_id: id, p_token: token ?? null }, d.fetchFn)
      .catch(() => "paused");
    return v === "ok" || v === "suppressed" || v === "cancelled" ? v : "paused";
  }

  type PResult = { sent: boolean; down: boolean; requeued: boolean };
  /** The ONE path for a partner email, live or queued. The database already took its send unit.
   *  Same order as the waitlist path: the email is built first, the send-time check is the LAST step
   *  before the provider. Not allowed any more -> unit refunded (paused: back in the queue). Provider
   *  not reached -> unit refunded and back in the queue; the retry is the same email (same link, same
   *  idempotency key), so the provider drops a duplicate. */
  async function partnerSend(id: string, hour: string, email: string, kind: "partner_confirm" | "partner_owner",
      mail: Mail, code: string, token?: string): Promise<PResult> {
    const refund = () => rpc(cfg, "waitlist_send_failed", { p_hour: hour }, d.fetchFn).catch(() => {});
    const allowed = await sendAllowed(email, kind, id, token);
    if (allowed !== "ok") {
      await refund();
      log("waitlist.partner_mail", 200, `${code}_${allowed}`);
      return { sent: false, down: false, requeued: allowed === "paused" ? await requeue(id, token) : false };
    }
    try { await sendMail(cfg, mail, d.fetchFn); log("waitlist.partner_mail", 200, `${code}_sent`); return { sent: true, down: false, requeued: false }; }
    catch (e) {
      log("waitlist.partner_mail", 500, `${code}_failed`);
      if (!(e instanceof ProviderNotReached)) return { sent: false, down: false, requeued: false };
      await refund();
      return { sent: false, down: true, requeued: await requeue(id, token) };
    }
  }
  const sendPartnerConfirm = (id: string, email: string, token: string, tag: string, sendNo: number, hour: string) =>
    partnerSend(id, hour, email, "partner_confirm", partnerConfirmMail(cfg, email, token, id, sendNo, tag), "confirm", token);
  async function sendPartnerOwner(id: string, hour: string, app: PartnerApp): Promise<PResult> {
    if (!cfg.alertTo) {   // no owner inbox configured: the confirmed application is in the database
      await rpc(cfg, "waitlist_send_failed", { p_hour: hour }, d.fetchFn).catch(() => {});
      return { sent: false, down: false, requeued: false };
    }
    const to = cfg.alertTo;
    return await partnerSend(id, hour, app.email, "partner_owner", partnerOwnerMail(to, id, app), "owner");
  }
  const isTag = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f]{16}$/.test(v);

  async function confirm(req: Request): Promise<Response> {
    requireOrigin(req, cfg.siteOrigin);
    if (!(req.headers.get("content-type") ?? "").startsWith("application/json")) throw new HttpError(415, "invalid_body");
    const body = parseJsonObject(await readBodyCapped(req, 3072));
    onlyKeys(body, ["token", "turnstile"]);
    if (!isToken(body.token)) return json(200, { ok: false }, cors);
    // a link scanner that also clicks buttons must still solve Turnstile
    await verifyTurnstile(body.turnstile, { secret: cfg.turnstileSecret, hostnames: cfg.turnstileHostnames, action: "waitlist_confirm", fetchFn: d.fetchFn });
    const r = await rpc<{ ok: boolean }>(cfg, "waitlist_confirm", { p_token: body.token }, d.fetchFn);
    log("waitlist.confirm", 200, r.ok ? "confirmed" : "invalid_or_expired");
    return json(200, { ok: r.ok === true }, cors);
  }

  async function unsubscribe(req: Request, url: URL): Promise<Response> {
    let id: unknown, token: unknown;
    const ct = req.headers.get("content-type") ?? "";
    if (ct.startsWith("application/x-www-form-urlencoded")) {
      // RFC 8058: the mailbox provider POSTs "List-Unsubscribe=One-Click" to the URL in the header.
      const form = new URLSearchParams(decodeUtf8(await readBodyCapped(req, 512)));
      if (form.get("List-Unsubscribe") !== "One-Click") throw new HttpError(400, "invalid_body");
      id = url.searchParams.get("id"); token = url.searchParams.get("t");
    } else if (ct.startsWith("application/json")) {
      requireOrigin(req, cfg.siteOrigin);   // our unsubscribe page
      const body = parseJsonObject(await readBodyCapped(req, 1024));
      onlyKeys(body, ["id", "t"]);
      id = body.id; token = body.t;
    } else {
      throw new HttpError(415, "invalid_body");
    }
    if (!isUuid(id) || !isToken(token)) return json(200, { ok: false }, cors);
    const r = await rpc<{ ok: boolean }>(cfg, "waitlist_unsubscribe", { p_signup_id: id, p_token: token }, d.fetchFn);
    log("waitlist.unsubscribe", 200, r.ok ? "unsubscribed" : "bad_token");
    return json(200, { ok: r.ok === true }, cors);
  }

  // "Delete my data": browser only (our unsubscribe page, explicit button), same signed link as
  // unsubscribe. No one-click/form path: deletion is never triggered by a mail provider or scanner.
  async function erase(req: Request): Promise<Response> {
    requireOrigin(req, cfg.siteOrigin);
    if (!(req.headers.get("content-type") ?? "").startsWith("application/json")) throw new HttpError(415, "invalid_body");
    const body = parseJsonObject(await readBodyCapped(req, 1024));
    onlyKeys(body, ["id", "t"]);
    if (!isUuid(body.id) || !isToken(body.t)) return json(200, { ok: false }, cors);
    const r = await rpc<{ ok: boolean }>(cfg, "waitlist_erase_by_token", { p_signup_id: body.id, p_token: body.t }, d.fetchFn);
    log("waitlist.erase", 200, r.ok ? "erased" : "bad_token");
    return json(200, { ok: r.ok === true }, cors);
  }

  // Scheduled job (pg_cron + pg_net every ~10 min). Same answer as an unknown route when the key
  // is missing or wrong, so the route is invisible to scanners.
  async function drain(req: Request): Promise<Response> {
    if (!cfg.cronSecret || !safeEqual(req.headers.get("x-cron-key") ?? "", cfg.cronSecret)) throw new HttpError(404, "not_found");
    type Send = { email: string; token: string; signup_id: string; send_no: number; hour: string };
    const r = await rpc<{ sends: Send[]; left: number; paused: boolean }>(cfg, "waitlist_drain_queue", {}, d.fetchFn);
    let sent = 0, failed = 0, providerDown = false;
    for (const s of Array.isArray(r.sends) ? r.sends : []) {
      let email: string;
      try { email = normalizeEmail(s.email); } catch { failed++; continue; }
      if (!isToken(s.token) || !isUuid(s.signup_id) || !Number.isInteger(s.send_no)) { failed++; continue; }
      if (providerDown) {   // after one "provider not reached", do not wait on the rest: give back + requeue
        failed++;
        await rpc(cfg, "waitlist_send_failed", { p_hour: s.hour }, d.fetchFn).catch(() => {});
        await rpc(cfg, "waitlist_signup_requeue", { p_signup_id: s.signup_id, p_token: s.token }, d.fetchFn).catch(() => {});
        continue;
      }
      // the same path as a live signup: send-time check, then the provider (re-check 2 #1)
      const res = await sendSignupConfirmation(email, s.token, s.signup_id, s.send_no, s.hour);
      if (res === "sent") sent++; else failed++;
      if (res === "down") providerDown = true;   // the shared path already refunded and requeued it
    }

    // 0007/0009: then the partner queue (waitlist confirmations keep priority). Each row is ONE email:
    // "confirm" = the applicant's confirmation link, "owner" = the notice of a confirmed application.
    // Every row is re-validated with the live form's rules; a bad row is dropped, never mailed.
    // If the provider was unreachable for the waitlist part, the partner queue is not touched this run.
    type PSend = { kind: string; id: string; email: string; token?: string; tag?: string; send_no?: number; name?: string; handles?: unknown; pitch?: string; hour: string };
    let pSent = 0, pFailed = 0, pLeft = 0;
    if (!providerDown) {
      try {
        const pr = await rpc<{ sends: PSend[]; left: number }>(cfg, "waitlist_drain_partner_queue", {}, d.fetchFn);
        pLeft = Number(pr.left) | 0;
        let down = false;
        for (const s of Array.isArray(pr.sends) ? pr.sends : []) {
          if (!isUuid(s.id) || typeof s.hour !== "string") { pFailed++; continue; }
          if (down) {   // provider went down mid-run: give the unit back and put the rest back in the queue
            await rpc(cfg, "waitlist_send_failed", { p_hour: s.hour }, d.fetchFn).catch(() => {});
            if (await requeue(s.id, s.kind === "confirm" && isToken(s.token) ? s.token : undefined)) pLeft++;
            pFailed++; continue;
          }
          let email: string;
          try { email = normalizeEmail(s.email); } catch { pFailed++; continue; }
          // partnerSend does the send-time check (paused -> back in the queue; deleted/cancelled -> dropped)
          let r2: PResult;
          try {
            if (s.kind === "confirm") {
              if (!isToken(s.token) || !isTag(s.tag) || !Number.isInteger(s.send_no)) throw new Error("row");
              r2 = await sendPartnerConfirm(s.id, email, s.token, s.tag, s.send_no!, s.hour);
            } else if (s.kind === "owner") {
              const app = { email, name: partnerName(s.name), handles: partnerHandles(s.handles), pitch: partnerPitch(s.pitch) };
              r2 = await sendPartnerOwner(s.id, s.hour, app);
            } else throw new Error("kind");
          } catch { pFailed++; continue; }   // a row that fails the live form's rules is never mailed
          if (r2.sent) pSent++; else pFailed++;
          if (r2.requeued) pLeft++;
          if (r2.down) down = true;
        }
      } catch { log("waitlist.drain", 500, "partner_queue_failed"); }
    }

    // Alerts are marked as handed out by the RPC. If the alert email fails they stay readable
    // in private.alerts (and the log line below says so).
    const alerts = await rpc<Alert[]>(cfg, "waitlist_take_alerts", {}, d.fetchFn).catch(() => [] as Alert[]);
    let alerted = false;
    if (alerts.length && cfg.alertTo) {
      try { await sendMail(cfg, await alertMail(cfg, cfg.alertTo, alerts, r.left, r.paused), d.fetchFn); alerted = true; }
      catch { log("waitlist.drain", 500, "alert_mail_failed"); }
    }
    log("waitlist.drain", 200, "ok", { sent, failed, left: r.left, paused: r.paused, alerts: alerts.length, alerted,
                                       partner_sent: pSent, partner_failed: pFailed, partner_left: pLeft });
    return json(200, { sent, failed, left: r.left, paused: r.paused, alerts: alerts.length,
                       partner_sent: pSent, partner_failed: pFailed, partner_left: pLeft });
  }

  // tiny per-instance cache: a flood of GET /count does not become a flood of DB calls.
  // Audit #12: the refresh itself is shared, so 100 requests arriving together start ONE query.
  let cached: { n: number; at: number } | null = null;
  let refreshing: Promise<number> | null = null;
  async function count(): Promise<Response> {
    const now = (d.now ?? Date.now)();
    if (!cached || now - cached.at > 60_000) {
      refreshing ??= rpc<number>(cfg, "waitlist_public_count", {}, d.fetchFn).finally(() => { refreshing = null; });
      cached = { n: await refreshing, at: now };
    }
    return json(200, { count: cached.n }, { ...cors, "cache-control": "public, max-age=300" });
  }

  return async (req: Request): Promise<Response> => {
    const url = new URL(req.url);
    const last = url.pathname.replace(/\/+$/, "").split("/").pop() ?? "";
    const route = ["signup", "partner", "partner-confirm", "confirm", "unsubscribe", "erase", "count", "drain"].includes(last) ? last : "unknown"; // never log raw paths
    try {
      if (req.method === "OPTIONS") {
        // preflight only for our own site; others get no CORS grant
        return new Response(null, { status: 204, headers: req.headers.get("origin") === cfg.siteOrigin ? cors : {} });
      }
      if (route === "count" && req.method === "GET") return await count();
      if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");  // GET never changes state
      if (route === "signup") return await signup(req);
      if (route === "partner") return await partner(req);
      if (route === "partner-confirm") return await partnerConfirm(req);
      if (route === "confirm") return await confirm(req);
      if (route === "unsubscribe") return await unsubscribe(req, url);
      if (route === "erase") return await erase(req);
      if (route === "drain") return await drain(req);
      throw new HttpError(404, "not_found");
    } catch (e) {
      if (e instanceof HttpError) {
        log(`waitlist.${route}`, e.status, e.code);
        return json(e.status, { error: e.code }, cors);
      }
      log(`waitlist.${route}`, 500, "internal");   // class only, never details
      return json(500, { error: "try_later" }, cors);
    }
  };
}
