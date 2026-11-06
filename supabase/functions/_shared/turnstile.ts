// Cloudflare Turnstile server-side check. The widget alone protects nothing.
// Rules: verify every token exactly once, check hostname AND action, fail closed.
import { HttpError } from "./http.ts";

export interface TurnstileOpts {
  secret: string;
  hostnames: string[];
  action: string;
  fetchFn?: typeof fetch;
}

export async function verifyTurnstile(token: unknown, o: TurnstileOpts): Promise<void> {
  if (typeof token !== "string" || token.length < 10 || token.length > 2048) throw new HttpError(400, "verification_failed");
  const form = new FormData();
  form.append("secret", o.secret);
  form.append("response", token);
  form.append("idempotency_key", crypto.randomUUID()); // retry-safe if the network blips
  // remoteip is optional and deliberately NOT sent (owner policy P-1: no IP use).
  let out: Record<string, unknown>;
  try {
    const res = await (o.fetchFn ?? fetch)("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST", body: form, signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) throw new Error(String(res.status));
    out = await res.json();
  } catch {
    throw new HttpError(503, "try_later");   // outage => no signup, never "let it through"
  }
  const host = typeof out.hostname === "string" ? out.hostname.toLowerCase() : "";
  if (out.success !== true || !o.hostnames.includes(host) || out.action !== o.action) {
    throw new HttpError(400, "verification_failed");
  }
}
