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
export function confirmationMail(cfg: Config, to: string, token: string, signupId: string, sendNo: number): Mail {
  const link = `${cfg.siteOrigin}/confirm#t=${token}`;
  return {
    to,
    subject: "Confirm your spot on the waitlist",
    text: `Tap the link, then press the "Confirm" button:\n${link}\n\nDidn't sign up? Ignore this email. Without confirmation we will not email you again, and the address is deleted automatically.`,
    html: `<p>Tap the link, then press the <b>Confirm</b> button:</p><p><a href="${link}">Confirm my email</a></p><p>Didn't sign up? Ignore this email. Without confirmation we will not email you again, and the address is deleted automatically.</p>`,
    idempotencyKey: `confirm/${signupId}/${sendNo}`,
  };
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
    subject: "Brand AI is live",
    text: `It's here. [launch text written by the owner]\n\nUnsubscribe: ${page}`,
    html: `<p>It's here. [launch text written by the owner]</p><p style="font-size:12px"><a href="${page}">Unsubscribe</a></p>`,
    headers: bulkHeaders(cfg, signupId, unsubToken),
    idempotencyKey: `${campaign}/${signupId}`,   // re-running the send job never doubles an email
  };
}
