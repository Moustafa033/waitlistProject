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

  let tsToken = null, done = false;
  (function waitForTurnstile(n) {
    if (window.turnstile) {
      window.turnstile.render("#wl-turnstile", {
        sitekey: cfg.turnstileSiteKey,
        action: "waitlist_confirm",
        appearance: "interaction-only",   // box shows only if Cloudflare needs a click; the token is still verified server-side
        callback: (t) => { tsToken = t; btn.disabled = done; },
        "expired-callback": () => { tsToken = null; btn.disabled = true; },
      });
    } else if (n < 100) setTimeout(() => waitForTurnstile(n + 1), 100);
    else say("Could not load the verification step. Please reload.");
  })(0);

  // Nothing happens until a person presses the button (no auto-submit: scanners run JS too).
  btn.addEventListener("click", async () => {
    if (done || !tsToken) return;
    btn.disabled = true; say("Confirming…");
    try {
      const res = await fetch(cfg.api + "/confirm", {
        method: "POST", credentials: "omit",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token, turnstile: tsToken }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok && data.ok === true) { done = true; say("Confirmed. You're on the list."); }
      else say("This link has expired or was already used. Sign up again on the home page to get a new one.");
    } catch {
      say("Something went wrong. Please try again.");
      btn.disabled = false;
    }
  });
})();
