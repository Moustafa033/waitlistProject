// TEST-ONLY: drives a real Chrome through signup -> email -> confirm -> unsubscribe.
import { chromium } from "playwright";
const SITE = "http://localhost:8787", API = "http://localhost:8788";
const CHROME = process.env.CHROME_PATH ?? "/usr/bin/google-chrome";
const ok = (c, m) => { if (!c) { console.log("FAIL: " + m); process.exit(1); } console.log("ok   " + m); };
const psql = async (sql) => (await import("node:child_process")).execSync(`psql -h /tmp -p 5433 -U postgres -d ${process.env.DB ?? "waitlist_test"} -qAt -c "${sql}"`).toString().trim();

const browser = await chromium.launch({ executablePath: CHROME });   // Chrome sandbox stays ON
const page = await browser.newPage();
const cspErrors = [];
page.on("console", (m) => { if (/Content Security Policy|Refused to/i.test(m.text())) cspErrors.push(m.text()); });
// fake Turnstile widget (the real one needs Cloudflare's network)
await page.route("https://challenges.cloudflare.com/**", (r) => r.fulfill({ contentType: "text/javascript",
  body: "window.turnstile={render(el,o){setTimeout(()=>o.callback(o.action+'-tok-xxxxxxxx'),50);return 1},reset(){}}" }));

const email = `e2e-${Date.now()}@example.com`;
await page.goto(SITE + "/?src=e2e");
ok(await page.locator("#wl-submit").isDisabled(), "button disabled until both boxes are ticked + captcha solved");
await page.fill("#wl-email", "  " + email.toUpperCase() + " ");
await page.check("#wl-consent"); await page.check("#wl-age");
await page.waitForTimeout(2700);                   // human-like fill time
await page.click("#wl-submit");
await page.waitForFunction(() => document.getElementById("wl-status").textContent.includes("Check your inbox"));
ok(true, "signup shows the neutral 'check your inbox' answer");
ok(await psql(`select status from private.signups where email='${email}'`) === "pending", "row is PENDING (not yet on the list)");

await new Promise((r) => setTimeout(r, 500));   // the email is sent in the background
const mails = await (await fetch(API + "/__mail")).json();
const link = mails.at(-1).text.match(/https?:\/\/\S+\/confirm#t=[A-Za-z0-9_-]{43}/)[0].replace(/^https?:\/\/[^/]+/, SITE);
ok(mails.at(-1).to[0] === email, "email goes to the normalized address");

// a mail scanner opening the link (and running its JS) changes nothing
const scanner = await browser.newPage();
await scanner.route("https://challenges.cloudflare.com/**", (r) => r.fulfill({ contentType: "text/javascript", body: "window.turnstile={render(){return 1},reset(){}}" }));
await scanner.goto(link); await scanner.waitForTimeout(800);
ok(await psql(`select status from private.signups where email='${email}'`) === "pending", "opening the link (GET + JS) does NOT confirm — scanner-safe");
ok(!(await scanner.evaluate(() => location.href)).includes("#t="), "token is removed from the address bar");
await scanner.close();

await page.goto(link);
await page.waitForFunction(() => !document.getElementById("wl-confirm").disabled);
await page.click("#wl-confirm");
await page.waitForFunction(() => document.getElementById("wl-status").textContent.includes("on the list"));
ok(await psql(`select status from private.signups where email='${email}'`) === "confirmed", "pressing the button confirms");
await page.goto("about:blank"); await page.goto(link); await page.waitForFunction(() => !document.getElementById("wl-confirm").disabled);
await page.click("#wl-confirm");
await page.waitForFunction(() => document.getElementById("wl-status").textContent.includes("expired or was already used"));
ok(true, "the same link a second time is refused (single use)");

// one-click unsubscribe exactly like Gmail does it (POST, no Origin, no login)
const id = await psql(`select id from private.signups where email='${email}'`);
const t = await psql(`set role service_role; select public.waitlist_unsub_token('${id}')`);
const r = await fetch(`${API}/functions/v1/waitlist/unsubscribe?id=${id}&t=${t}`, { method: "POST",
  headers: { "content-type": "application/x-www-form-urlencoded" }, body: "List-Unsubscribe=One-Click" });
ok(r.status === 200 && (await psql(`select status from private.signups where email='${email}'`)) === "unsubscribed", "RFC 8058 one-click unsubscribe works");

// XSS probe: a hostile ?src and #fragment must not execute
let dialog = false; page.on("dialog", (d) => { dialog = true; d.dismiss(); });
await page.goto("about:blank"); await page.goto(SITE + "/confirm#t=<img src=x onerror=alert(1)>");
await page.goto(SITE + "/?src=<script>alert(1)</script>");
await page.waitForTimeout(300);
ok(!dialog, "no script runs from URL input");
ok(cspErrors.length === 0, "zero CSP violations from our own pages (" + cspErrors.join(" | ") + ")");
const h = await (await fetch(SITE + "/")).headers;
ok(/script-src 'self' https:\/\/challenges\.cloudflare\.com;/.test(h.get("content-security-policy")) && !/unsafe/.test(h.get("content-security-policy")), "CSP header served, no 'unsafe-*'");
await browser.close();
console.log("E2E PASSED");
