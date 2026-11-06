// HTTP helpers: capped body, exact-origin CORS, generic errors, safe logs.
export class HttpError extends Error {
  constructor(public status: number, public code: string) { super(code); }
}

const SECURITY_HEADERS = {
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
};

export function json(status: number, body: unknown, extra: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...SECURITY_HEADERS, ...extra },
  });
}

/** CORS for ONE exact origin. Never "*", never reflect whatever Origin was sent. */
export function corsHeaders(origin: string): Record<string, string> {
  return {
    "access-control-allow-origin": origin,
    "access-control-allow-methods": "POST, GET, OPTIONS",
    "access-control-allow-headers": "content-type",
    "access-control-max-age": "600",
    "vary": "Origin",
  };
}

/** Browser-only endpoints: Origin must be exactly our site. (Stops cross-site
 *  form posts; it is NOT bot protection — bots can fake headers. Turnstile is.) */
export function requireOrigin(req: Request, siteOrigin: string): void {
  if (req.headers.get("origin") !== siteOrigin) throw new HttpError(403, "forbidden");
}

export async function readBodyCapped(req: Request, maxBytes: number): Promise<Uint8Array> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (!Number.isFinite(declared) || declared > maxBytes) throw new HttpError(413, "body_too_large");
  if (!req.body) return new Uint8Array();
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) { await reader.cancel(); throw new HttpError(413, "body_too_large"); }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { out.set(c, off); off += c.byteLength; }
  return out;
}

export function decodeUtf8(b: Uint8Array): string {
  try { return new TextDecoder("utf-8", { fatal: true }).decode(b); } catch { throw new HttpError(400, "invalid_body"); }
}

export function parseJsonObject(b: Uint8Array): Record<string, unknown> {
  let v: unknown;
  try { v = JSON.parse(decodeUtf8(b)); } catch { throw new HttpError(400, "invalid_body"); }
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw new HttpError(400, "invalid_body");
  return v as Record<string, unknown>;
}

/** Only fields we know; anything else => 400 (no mass-assignment surprises). */
export function onlyKeys(o: Record<string, unknown>, allowed: string[]): void {
  for (const k of Object.keys(o)) if (!allowed.includes(k)) throw new HttpError(400, "invalid_body");
}

// Never log emails, tokens, keys, IPs, user agents or request bodies.
export function log(fn: string, status: number, code?: string, extra: Record<string, string | number | boolean> = {}): void {
  console.log(JSON.stringify({ fn, status, code, ...extra }));
}
