// The ONLY place the secret key is used: calling the waitlist RPCs.
import type { Config } from "./env.ts";

export async function rpc<T>(cfg: Config, fn: string, args: Record<string, unknown>, fetchFn: typeof fetch = fetch): Promise<T> {
  if (!/^waitlist_[a-z_]+$/.test(fn)) throw new Error("rpc name");
  const res = await fetchFn(`${cfg.supabaseUrl}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { "content-type": "application/json", "apikey": cfg.secretKey, "authorization": `Bearer ${cfg.secretKey}` },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(6000),
  });
  if (!res.ok) throw new Error(`rpc ${fn} ${res.status}`);   // status only, never the body
  return await res.json() as T;
}
