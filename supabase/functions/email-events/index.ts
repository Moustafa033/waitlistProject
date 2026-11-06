import { loadConfig } from "../_shared/env.ts";
import { makeEventHandler } from "./handler.ts";

let handler: ((r: Request) => Promise<Response>) | null = null;
Deno.serve((req) => {
  try {
    const secret = Deno.env.get("RESEND_WEBHOOK_SECRET");
    if (!secret || !secret.startsWith("whsec_")) throw new Error("missing webhook secret");
    handler ??= makeEventHandler({ cfg: loadConfig(), webhookSecret: secret, fetchFn: fetch });
  } catch {
    console.log(JSON.stringify({ fn: "email-events", status: 500, code: "config" }));
    return new Response('{"error":"internal"}', { status: 500, headers: { "content-type": "application/json" } });
  }
  return handler(req);
});
