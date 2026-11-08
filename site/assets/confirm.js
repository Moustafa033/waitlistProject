"use strict";
(function () {
  const cfg = window.WAITLIST;
  const btn = document.getElementById("wl-confirm");
  const status = document.getElementById("wl-status");
  const say = (m) => { status.textContent = m; };

  // Read the token from the #fragment, then remove it from the address bar
  // (not kept in history, not shared by copy-paste of the URL).
  const token = new URLSearchParams(location.hash.slice(1)).get("t");
  history.replaceState(null, "", location.pathname);
  if (!token || !/^[A-Za-z0-9_-]{43}$/.test(token)) {
    say("This link is incomplete. Please open the newest email from us and tap the link again.");
    return;
  }

  // The button works at once. If it is pressed before Cloudflare's invisible check has finished,
  // the press is remembered and sent the moment the check token arrives. The server still refuses
  // any confirmation without a valid token, so this changes the waiting, not the security.
  let tsToken = null, widgetId = null, done = false, busy = false, wanted = false;
  btn.disabled = false;

  (function waitForTurnstile(n) {
    if (window.turnstile) {
      widgetId = window.turnstile.render("#wl-turnstile", {
        sitekey: cfg.turnstileSiteKey,
        action: "waitlist_confirm",
        appearance: "interaction-only",   // box shows only if Cloudflare needs a click; the token is still verified server-side
        callback: (t) => { tsToken = t; if (wanted) send(); },
        "expired-callback": () => { tsToken = null; },
        "error-callback": () => {
          tsToken = null;
          if (wanted) { wanted = false; btn.disabled = false; say("Verification failed. Please reload the page and try again."); }
        },
      });
    } else if (n < 100) setTimeout(() => waitForTurnstile(n + 1), 100);
    else { btn.disabled = true; say("Could not load the verification step. Please reload."); }
  })(0);

  async function send() {
    if (done || busy || !tsToken) return;
    busy = true; wanted = false; btn.disabled = true; say("Confirming…");
    const ts = tsToken; tsToken = null;        // a check token is single-use
    try {
      const res = await fetch(cfg.api + "/confirm", {
        method: "POST", credentials: "omit",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token, turnstile: ts }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok && data.ok === true) { done = true; say("Confirmed. You're on the list."); }
      else say("This link has expired or was already used. Sign up again on the home page to get a new one.");
    } catch {
      say("Something went wrong. Please try again.");
      btn.disabled = false;
      if (window.turnstile && widgetId !== null) window.turnstile.reset(widgetId);   // fetch a fresh token for the retry
    } finally {
      busy = false;
    }
  }

  // Nothing happens until a person presses the button (no auto-submit: scanners run JS too).
  btn.addEventListener("click", () => {
    if (done || busy || wanted) return;
    if (tsToken) { send(); return; }
    wanted = true; btn.disabled = true; say("Confirming…");
    setTimeout(() => { if (wanted && !busy && !done) say("Almost there. If a box appears above, tick it."); }, 5000);
  });
})();
