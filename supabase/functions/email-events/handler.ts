// Email provider webhook (Resend / Svix-signed): hard bounces and spam
// complaints go to the suppression list immediately. Keeps the complaint rate
// far below the 0.3% Gmail/Yahoo limit and honors "stop emailing me".
import type { Config } from "../_shared/env.ts";
import { decodeUtf8, HttpError, json, log, readBodyCapped } from "../_shared/http.ts";
import { verifySvix } from "../_shared/svix.ts";
import { rpc } from "../_shared/db.ts";
import { normalizeEmail } from "../_shared/validate.ts";

export interface EventDeps { cfg: Config; webhookSecret: string; fetchFn: typeof fetch; now?: () => number; }

export function makeEventHandler(d: EventDeps): (req: Request) => Promise<Response> {
  return async (req) => {
    try {
      if (req.method !== "POST") throw new HttpError(405, "method_not_allowed");
      const raw = decodeUtf8(await readBodyCapped(req, 64 * 1024));
      // verify the RAW body before parsing anything
      await verifySvix(d.webhookSecret, req.headers, raw, d.now ? d.now() : undefined);
      let ev: { type?: string; data?: { to?: unknown; bounce?: { type?: string } } };
      try { ev = JSON.parse(raw); } catch { throw new HttpError(400, "invalid_body"); }
      let reason: "hard_bounce" | "complaint" | null = null;
      if (ev.type === "email.complained") reason = "complaint";
      if (ev.type === "email.bounced") {
        const t = ev.data?.bounce?.type;
        // transient/soft bounces are retried by the provider; only permanent ones suppress
        reason = !t || /permanent|hard/i.test(t) ? "hard_bounce" : null;
      }
      if (!reason) { log("email-events", 200, "ignored"); return json(200, { ok: true }); }
      const to = Array.isArray(ev.data?.to) ? ev.data!.to : [ev.data?.to];
      for (const addr of to.slice(0, 50)) {
        let email: string;
        try { email = normalizeEmail(addr); } catch { continue; }
        await rpc(d.cfg, "waitlist_suppress", { p_email: email, p_reason: reason }, d.fetchFn);
      }
      log("email-events", 200, reason);
      return json(200, { ok: true });
    } catch (e) {
      if (e instanceof HttpError) { log("email-events", e.status, e.code); return json(e.status, { error: e.code }); }
      log("email-events", 500, "internal");
      return json(500, { error: "internal" });   // provider will retry
    }
  };
}
