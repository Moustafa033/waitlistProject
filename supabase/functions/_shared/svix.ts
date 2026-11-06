// Webhook signature check for Resend (Svix scheme):
// signature = base64(HMAC_SHA256(base64decode(secret without "whsec_"), `${id}.${timestamp}.${rawBody}`))
// Header "svix-signature" may hold several "v1,<sig>" entries (key rotation).
import { HttpError } from "./http.ts";

const enc = new TextEncoder();

function b64decode(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}
function b64encode(b: Uint8Array): string {
  let s = ""; for (const x of b) s += String.fromCharCode(x); return btoa(s);
}
export function safeEqual(a: string, b: string): boolean {
  const x = enc.encode(a), y = enc.encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) d |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return d === 0;
}

export async function svixSign(secret: string, id: string, ts: string, body: string): Promise<string> {
  const keyBytes = b64decode(secret.replace(/^whsec_/, ""));
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(`${id}.${ts}.${body}`));
  return b64encode(new Uint8Array(sig));
}

export async function verifySvix(secret: string, headers: Headers, rawBody: string, nowSec = Math.floor(Date.now() / 1000), toleranceSec = 300): Promise<void> {
  const id = headers.get("svix-id"), ts = headers.get("svix-timestamp"), sigs = headers.get("svix-signature");
  if (!id || !ts || !sigs || !/^\d{9,11}$/.test(ts)) throw new HttpError(401, "bad_signature");
  if (Math.abs(nowSec - Number(ts)) > toleranceSec) throw new HttpError(401, "bad_signature"); // replay window
  const expected = await svixSign(secret, id, ts, rawBody);
  const ok = sigs.split(" ").some((p) => { const [v, s] = p.split(","); return v === "v1" && !!s && safeEqual(s, expected); });
  if (!ok) throw new HttpError(401, "bad_signature");
}
