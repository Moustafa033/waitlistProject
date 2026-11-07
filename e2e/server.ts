// TEST-ONLY end-to-end harness: real static site + real Edge Function handler +
// real Postgres (the migration) — only Turnstile and the email provider are faked.
// deno run -A e2e/server.ts   (needs the test DB from tests/run_all.sh)
import { makeHandler } from "../supabase/functions/waitlist/handler.ts";
import type { Config } from "../supabase/functions/_shared/env.ts";

const SITE = 8787, API = 8788;
// The real project URL in site/ is swapped for the local test API (written without backslashes on purpose).
const SUPABASE_ORIGIN = new RegExp("https://[a-z0-9]+[.]supabase[.]co");
const siteDir = new URL("../site/", import.meta.url).pathname;
const DB = Deno.env.get("DB") ?? "waitlist_test";

const SQL: Record<string, string> = {
  waitlist_signup: "select to_jsonb(public.waitlist_signup(j->>'p_email', j->>'p_consent_version', j->>'p_locale', j->>'p_source'))",
  waitlist_send_failed: "select public.waitlist_send_failed((j->>'p_hour')::timestamptz); select 'null'::jsonb",
  waitlist_confirm: "select to_jsonb(public.waitlist_confirm(j->>'p_token'))",
  waitlist_unsubscribe: "select to_jsonb(public.waitlist_unsubscribe((j->>'p_signup_id')::uuid, j->>'p_token'))",
  waitlist_public_count: "select to_jsonb(public.waitlist_public_count())",
  waitlist_unsub_token: "select to_jsonb(public.waitlist_unsub_token((j->>'p_signup_id')::uuid))",
  waitlist_erase_by_token: "select to_jsonb(public.waitlist_erase_by_token((j->>'p_signup_id')::uuid, j->>'p_token'))",
};
async function psqlRpc(name: string, args: unknown): Promise<string> {
  const sql = SQL[name];
  if (!sql) throw new Error("rpc " + name);
  const cmd = new Deno.Command("psql", { args: ["-h", "/tmp", "-p", "5433", "-U", "postgres", "-d", DB, "-qAt", "-v", "ON_ERROR_STOP=1",
    "-v", `j=${JSON.stringify(args)}`], stdin: "piped", stdout: "piped", stderr: "piped" });
  const p = cmd.spawn();
  const w = p.stdin.getWriter();
  await w.write(new TextEncoder().encode(`set role service_role;\n${sql.replaceAll("j->>", "(:'j'::jsonb)->>").replaceAll("j->", "(:'j'::jsonb)->")};\n`));
  await w.close();
  const out = await p.output();
  if (!out.success) throw new Error(new TextDecoder().decode(out.stderr));
  return new TextDecoder().decode(out.stdout).trim().split("\n").pop()!;
}

const mails: unknown[] = [];
const fakeFetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const url = String(input);
  if (url.includes("challenges.cloudflare.com")) {
    const t = String((init!.body as FormData).get("response"));
    return Response.json({ success: t.endsWith("-tok-xxxxxxxx"), hostname: "localhost", action: t.split("-tok-")[0] });
  }
  if (url.includes("/rest/v1/rpc/")) return new Response(await psqlRpc(url.split("/").pop()!, JSON.parse(String(init!.body))));
  if (url.startsWith("https://api.resend.com")) { mails.push(JSON.parse(String(init!.body))); return Response.json({ id: "e" }); }
  throw new Error("unexpected " + url);
}) as typeof fetch;

// The consent version comes from the page itself (data-consent-version), like production must match it.
const CONSENT_VERSION = (await Deno.readTextFile(siteDir + "index.html")).match(/data-consent-version="([a-z0-9-]+)"/)![1];
const cfg: Config = {
  supabaseUrl: "http://db.invalid", secretKey: "sb_secret_e2e", siteOrigin: `http://localhost:${SITE}`,
  functionBaseUrl: `http://localhost:${API}/functions/v1/waitlist`, turnstileSecret: "x", turnstileHostnames: ["localhost"],
  resendApiKey: "re_e2e", mailFrom: "Brand AI <hello@mail.example.com>", consentVersion: CONSENT_VERSION, minFillMs: 2500,
};
const api = makeHandler({ cfg, fetchFn: fakeFetch, background: (p) => { p.catch(() => {}); } });
// Bind to loopback ONLY. Deno.serve defaults to 0.0.0.0 (every network interface), which
// would expose /__mail (real confirmation tokens) to anyone on the same Wi-Fi — the same
// mistake as the Metro dev-server RCE (gym guide SC-10).
const HOST = "localhost";   // resolves to loopback only; matches the localhost origin the test uses
Deno.serve({ hostname: HOST, port: API, onListen: () => {} }, (req) => {
  if (new URL(req.url).pathname === "/__mail") return Response.json(mails);   // test only
  return api(req);
});

// static site with the headers from site/_headers (CSP connect-src pointed at the local API)
const headersFile = await Deno.readTextFile(siteDir + "_headers");
const global: [string, string][] = [];
let inGlobal = false;
for (const line of headersFile.split("\n")) {
  if (line.startsWith("/*")) { inGlobal = true; continue; }
  if (/^\S/.test(line)) inGlobal = false;
  const m = line.match(/^\s+([A-Za-z-]+):\s*(.*)$/);
  if (inGlobal && m) global.push([m[1], m[2].replace(SUPABASE_ORIGIN, `http://localhost:${API}`).replace("; upgrade-insecure-requests", "")]);
}
const types: Record<string, string> = { html: "text/html; charset=utf-8", js: "text/javascript", css: "text/css", txt: "text/plain" };
Deno.serve({ hostname: HOST, port: SITE, onListen: () => console.log("e2e ready") }, async (req) => {
  let p = new URL(req.url).pathname;
  if (p === "/") p = "/index.html";
  else if (!p.includes(".")) p += ".html";
  if (p.includes("..")) return new Response("no", { status: 400 });
  try {
    let body = await Deno.readTextFile(siteDir + p.slice(1));
    if (p === "/assets/config.js") body = body.replace(SUPABASE_ORIGIN, `http://localhost:${API}`);
    return new Response(body, { headers: [...global, ["content-type", types[p.split(".").pop()!] ?? "text/plain"]] });
  } catch { return new Response("not found", { status: 404 }); }
});
