// The ONE public endpoint of the waitlist (deployed with verify_jwt = false,
// because visitors have no account). Everything it does is bounded:
//   POST /signup       browser only (exact Origin) + Turnstile + honeypot + validation
//   POST /confirm      browser only, called by the explicit "Confirm" button (never on GET)
//   POST /unsubscribe  RFC 8058 one-click (mail providers, no Origin) or our page
//   GET  /count        coarse public counter, cacheable
// Every signup answer is the SAME 202 whether the email is new, pending,
// confirmed, suppressed, rate-limited or a detected bot (no enumeration, no
// feedback that teaches a bot what worked).
import type { Config } from "../_shared/env.ts";
import { corsHeaders, decodeUtf8, HttpError, json, log, onlyKeys, parseJsonObject, readBodyCapped, requireOrigin } from "../_shared/http.ts";
import { isDisposable, isToken, isUuid, normalizeEmail } from "../_shared/validate.ts";
import { verifyTurnstile } from "../_shared/turnstile.ts";
import { rpc } from "../_shared/db.ts";
import { confirmationMail, ProviderNotReached, sendMail } from "../_shared/mailer.ts";
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

    if (r.action === "send" && r.token && r.signup_id && r.send_no && r.hour) {
      const { token, signup_id, send_no, hour } = r;
      d.background((async () => {
        try {
          await sendMail(cfg, confirmationMail(cfg, email, token, signup_id, send_no), d.fetchFn);
          log("waitlist.mail", 200, "sent");
        } catch (e) {
          if (e instanceof ProviderNotReached) {
            await rpc(cfg, "waitlist_send_failed", { p_hour: hour }, d.fetchFn).catch(() => {});
          }
          log("waitlist.mail", 500, "mail_failed");
        }
      })());
    }
    return accepted(r.action === "send" ? "sent" : (r.reason ?? "none"));
  }

  function accepted(reason: string): Response {
    log("waitlist.signup", 202, reason);   // reason is internal metrics only
    return json(202, ACCEPTED, cors);
  }

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

  // tiny per-instance cache: a flood of GET /count does not become a flood of DB calls
  let cached: { n: number; at: number } | null = null;
  async function count(): Promise<Response> {
    const now = (d.now ?? Date.now)();
    if (!cached || now - cached.at > 60_000) cached = { n: await rpc<number>(cfg, "waitlist_public_count", {}, d.fetchFn), at: now };
    const n = cached.n;
    return json(200, { count: n }, { ...cors, "cache-control": "public, max-age=300" });
  }

  return async (req: Request): Promise<Response> => {
    const url = new URL(req.url);
    const last = url.pathname.replace(/\/+$/, "").split("/").pop() ?? "";
    const route = ["signup", "confirm", "unsubscribe", "count"].includes(last) ? last : "unknown"; // never log raw paths
    try {
      if (req.method === "OPTIONS") {
        // preflight only for our own site; others get no CORS grant
        return new Response(null, { status: 204, headers: req.headers.get("origin") === cfg.siteOrigin ? cors : {} });
      }
      if (route === "count" && req.method === "GET") return await count();
      if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");  // GET never changes state
      if (route === "signup") return await signup(req);
      if (route === "confirm") return await confirm(req);
      if (route === "unsubscribe") return await unsubscribe(req, url);
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
