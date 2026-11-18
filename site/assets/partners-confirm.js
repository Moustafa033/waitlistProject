"use strict";
// "Confirm application" page (0009). Same pattern as confirm.js: nothing happens until a person presses
// the button (email scanners open links and run JS too), the token comes from the #fragment and is
// removed from the address bar at once, and the server checks Turnstile for this exact action.
(function () {
  const cfg = window.WAITLIST;
  const btn = document.getElementById("pc-confirm");
  const status = document.getElementById("pc-status");
  const say = (m) => { status.textContent = m; };   // textContent only: no HTML sinks

  const token = new URLSearchParams(location.hash.slice(1)).get("t");
  history.replaceState(null, "", location.pathname);
  if (!token || !/^[A-Za-z0-9_-]{43}$/.test(token)) {
    say("This link is incomplete. Please open the newest email from us and tap the button again.");
    return;
  }

  let tsToken = null, widgetId = null, done = false, busy = false, wanted = false;
  btn.disabled = false;

  (function waitForTurnstile(n) {
    if (window.turnstile) {
      widgetId = window.turnstile.render("#pc-turnstile", {
        sitekey: cfg.turnstileSiteKey,
        action: "partner_confirm",           // the server checks this exact value
        appearance: "interaction-only",
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

  function retry(msg) {
    say(msg);
    btn.disabled = false;
    if (window.turnstile && widgetId !== null) window.turnstile.reset(widgetId);   // a fresh check token for the retry
  }

  async function send() {
    if (done || busy || !tsToken) return;
    busy = true; wanted = false; btn.disabled = true; say("Confirming…");
    const ts = tsToken; tsToken = null;        // a check token is single-use
    try {
      const res = await fetch(cfg.api + "/partner-confirm", {
        method: "POST", credentials: "omit",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ token, turnstile: ts }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok && data.ok === true) {
        done = true;
        say("Application received. We'll review it and get in touch as soon as possible.");
      } else if (res.ok && data.ok === false) {
        // the server looked the link up and refused it: expired, used or replaced by a newer application
        done = true;
        say("This link has expired or was already used. You can apply again on the Work with us page.");
      } else {
        // a temporary problem (verification, network, server): the link may still be valid, so allow a retry
        retry(data.error === "verification_failed" ? "Verification failed. Please try again." : "Something went wrong on our side. Please try again in a moment.");
      }
    } catch {
      retry("Something went wrong. Please try again.");
    } finally {
      busy = false;
    }
  }

  btn.addEventListener("click", () => {
    if (done || busy || wanted) return;
    if (tsToken) { send(); return; }
    wanted = true; btn.disabled = true; say("Confirming…");
    setTimeout(() => { if (wanted && !busy && !done) say("Almost there. If a box appears above, tick it."); }, 5000);
  });
})();
