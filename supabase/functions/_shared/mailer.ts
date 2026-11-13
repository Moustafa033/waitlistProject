// Outgoing email. No user-controlled text is ever placed in a header, subject or
// body (only our own link with a random token), so there is nothing to inject.
import type { Config } from "./env.ts";

export class ProviderNotReached extends Error {}

export interface Mail {
  to: string;
  subject: string;
  text: string;
  html: string;
  headers?: Record<string, string>;
  idempotencyKey: string;
}

export async function sendMail(cfg: Config, m: Mail, fetchFn: typeof fetch = fetch): Promise<void> {
  if (/[\r\n]/.test(m.to + m.subject + Object.values(m.headers ?? {}).join(""))) throw new Error("header injection blocked");
  let res: Response;
  try {
    res = await fetchFn("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "authorization": `Bearer ${cfg.resendApiKey}`,
        "content-type": "application/json",
        "idempotency-key": m.idempotencyKey,   // a retry never sends a second copy
      },
      body: JSON.stringify({ from: cfg.mailFrom, to: [m.to], subject: m.subject, text: m.text, html: m.html, headers: m.headers,
        ...(cfg.mailReplyTo ? { reply_to: cfg.mailReplyTo } : {}) }),   // replies land in the owner's real mailbox
      signal: AbortSignal.timeout(8000),
    });
  } catch {
    throw new ProviderNotReached();   // network/timeout before the provider answered
  }
  if (!res.ok) throw new Error(`mail ${res.status}`);
}

/** Confirmation email. The token goes in the URL FRAGMENT (#): browsers never
 *  send fragments to servers, so it is not in any log, proxy or Referer. */
export function confirmationMail(cfg: Config, to: string, token: string, signupId: string, sendNo: number, unsubToken: string): Mail {
  const link = `${cfg.siteOrigin}/confirm#t=${token}`;
  // Personal "unsubscribe / delete my data" page (signed link, in the fragment like the token).
  const manage = `${cfg.siteOrigin}/unsubscribe#id=${encodeURIComponent(signupId)}&t=${encodeURIComponent(unsubToken)}`;
  const ignore = "Didn't sign up? Just ignore this email. We won't email you again, and your address is deleted automatically.";
  return {
    to,
    subject: "You acted on it",
    text: `You acted on it\n\nThanks for signing up. One more tap and you're on the list.\n\nConfirm: ${link}\n\n${ignore}\n\nCreating in Public\nUnsubscribe or delete your data: ${manage}`,
    html: confirmationHtml(cfg, esc(link), esc(manage), ignore),
    idempotencyKey: `confirm/${signupId}/${sendNo}`,
  };
}

/** Escapes a value for an HTML attribute or text. Every value here is already ours (validated origin,
 *  random URL-safe tokens, a UUID), so this is defence in depth, not the main protection. */
function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

/** Email-safe HTML (tables + inline styles: Gmail/Outlook ignore <style> blocks and SVG).
 *  No tracking pixel, no outside fonts; the only image is the logo from our own site. */
function confirmationHtml(cfg: Config, link: string, manage: string, ignore: string): string {
  const font = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
  const logo = `${esc(cfg.siteOrigin)}/email-logo.png`;   // the one image allowed cross-origin (see site/.htaccess)
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>You acted on it</title></head>
<body style="margin:0;padding:0;background:#f4f4f3;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;mso-hide:all;">One more tap and you're on the list.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#f4f4f3;"><tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:480px;background:#ffffff;border:1px solid #ececea;border-radius:14px;">
<tr><td style="padding:28px 26px;font-family:${font};color:#111111;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td style="padding-right:8px;vertical-align:middle;"><img src="${logo}" width="20" height="20" alt="" style="display:block;border:0;"></td>
<td style="vertical-align:middle;font-size:15px;font-weight:600;letter-spacing:-0.2px;color:#111111;">Creating in Public</td>
</tr></table>
<h1 style="margin:22px 0 0;font-size:24px;line-height:1.2;font-weight:700;letter-spacing:-0.6px;color:#111111;">You acted on it</h1>
<div style="margin:8px 0 16px;width:150px;height:3px;border-radius:3px;background-color:#8f7cf0;background-image:linear-gradient(90deg,#ff8a3d,#6b7bff);line-height:3px;font-size:0;">&nbsp;</div>
<p style="margin:0 0 20px;font-size:15px;line-height:1.55;color:#2b2b2b;">Thanks for signing up. One more tap and you're on the list.</p>
<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td style="border-radius:999px;background:#111111;">
<a href="${link}" style="display:inline-block;padding:13px 28px;font-family:${font};font-size:15px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:999px;">Confirm</a>
</td></tr></table>
<p style="margin:22px 0 0;font-size:12px;line-height:1.5;color:#6b6b6b;">${esc(ignore)}</p>
<p style="margin:18px 0 0;padding-top:14px;border-top:1px solid #ececea;font-size:12px;line-height:1.5;color:#6b6b6b;">Creating in Public &middot; <a href="${manage}" style="color:#6b6b6b;">Unsubscribe or delete your data</a></p>
</td></tr></table>
</td></tr></table>
</body></html>`;
}

/** Headers every marketing/launch email MUST carry (Gmail/Yahoo/Microsoft bulk rules, RFC 8058). */
export function bulkHeaders(cfg: Config, signupId: string, unsubToken: string): Record<string, string> {
  const url = `${cfg.functionBaseUrl}/unsubscribe?id=${encodeURIComponent(signupId)}&t=${encodeURIComponent(unsubToken)}`;
  return {
    "List-Unsubscribe": `<${url}>`,
    "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
  };
}

/** Launch / news email (bulk). Only for rows from waitlist_export_confirmed().
 *  Carries BOTH the RFC 8058 one-click header and a visible unsubscribe link. */
export function launchMail(cfg: Config, to: string, signupId: string, unsubToken: string, campaign: string): Mail {
  if (!/^[a-z0-9-]{1,40}$/.test(campaign)) throw new Error("campaign id");
  const page = `${cfg.siteOrigin}/unsubscribe#id=${encodeURIComponent(signupId)}&t=${encodeURIComponent(unsubToken)}`;
  return {
    to,
    subject: "We're live",
    text: `It's here. [launch text written by the owner]\n\nUnsubscribe: ${page}`,
    html: `<p>It's here. [launch text written by the owner]</p><p style="font-size:12px"><a href="${page}">Unsubscribe</a></p>`,
    headers: bulkHeaders(cfg, signupId, unsubToken),
    idempotencyKey: `${campaign}/${signupId}`,   // re-running the send job never doubles an email
  };
}

/** Safety-net alert for the OWNER. Built only from fixed alert kinds and numbers from our own
 *  database: no visitor text and no email address ever appears in it. */
export interface Alert { kind: string; period: string; hits: number; first_at: string; last_at: string }
const ALERT_TEXT: Record<string, string> = {
  global_send_cap: "Hourly confirmation-email cap was full (people were queued)",
  global_send_day_cap: "Daily confirmation-email cap was full (people were queued)",
  global_new_cap: "Daily new-signup cap was full (new signups were refused)",
  queue_full: "The waiting queue was full (some people could not be queued)",
  paused_signups: "Sending is paused and people are signing up (they are queued)",
  auto_paused: "SENDING WAS PAUSED AUTOMATICALLY: bounce or spam-complaint spike",
};
export async function alertMail(_cfg: Config, to: string, alerts: Alert[], queued: number, paused: boolean): Promise<Mail> {
  const known = alerts.filter((a) => a.kind in ALERT_TEXT);
  const urgent = known.some((a) => a.kind === "auto_paused");
  const lines = known.map((a) => `- ${ALERT_TEXT[a.kind]}: ${Number(a.hits) | 0} time(s), ${String(a.first_at).slice(0, 16)} to ${String(a.last_at).slice(0, 16)} UTC`);
  const text = [
    urgent ? "Your waitlist stopped sending confirmation emails to protect your sending domain." : "Your waitlist safety net was triggered.",
    "", ...lines, "",
    `People waiting in the queue: ${queued | 0}`,
    `Sending paused: ${paused ? "YES" : "no"}`,
    "", paused
      ? "Check the bounce/complaint list in your email provider first. To resume, run in the Supabase SQL editor:\n  select public.waitlist_set_paused(false);"
      : "Nothing to do unless this keeps happening (then raise the caps or look for a bot).",
  ].join("\n");
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(known.map((a) => a.kind + a.period).join("|"))));
  return {
    to,
    subject: urgent ? "Waitlist: sending PAUSED" : "Waitlist: safety net triggered",
    text,
    html: `<pre style="font-family:monospace;font-size:13px">${esc(text)}</pre>`,
    idempotencyKey: `alert/${Array.from(digest.slice(0, 16), (b) => b.toString(16).padStart(2, "0")).join("")}`,
  };
}
