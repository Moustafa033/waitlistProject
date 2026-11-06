import { loadConfig } from "../_shared/env.ts";
import { makeHandler } from "./handler.ts";

// Config is read once; a missing secret makes every request fail closed (500).
let handler: ((r: Request) => Promise<Response>) | null = null;
Deno.serve((req) => {
  try {
    // deno-lint-ignore no-explicit-any
    const rt = (globalThis as any).EdgeRuntime;
    handler ??= makeHandler({
      cfg: loadConfig(), fetchFn: fetch,
      background: (p) => (rt?.waitUntil ? rt.waitUntil(p) : p.catch(() => {})),
    });
  } catch {
    console.log(JSON.stringify({ fn: "waitlist", status: 500, code: "config" }));
    return new Response('{"error":"try_later"}', { status: 500, headers: { "content-type": "application/json" } });
  }
  return handler(req);
});
