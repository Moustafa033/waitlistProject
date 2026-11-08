"use strict";
(function () {
  const cfg = window.WAITLIST;
  const form = document.getElementById("wl-form");
  const email = document.getElementById("wl-email");
  const consent = document.getElementById("wl-consent");
  const age = document.getElementById("wl-age");
  const btn = document.getElementById("wl-submit");
  const status = document.getElementById("wl-status");
  const startedAt = Date.now();
  let tsToken = null, widgetId = null, busy = false;

  // Output uses textContent only (no HTML-parsing sinks) => no DOM XSS.
  const say = (msg) => { status.textContent = msg; };
  const MESSAGES = {
    check_inbox: "Thanks! Check your inbox and press the button in our email to confirm.",
    invalid_email: "Please enter a valid email address.",
    use_another_email: "Please use a permanent email address.",
    consent_required: "Please tick both boxes.",
    reload_page: "This page was updated. Please reload it and try again.",
    verification_failed: "Verification failed. Please try again.",
    try_later: "Something went wrong on our side. Please try again in a few minutes.",
  };
  const refresh = () => { btn.disabled = busy || !tsToken || !consent.checked || !age.checked; };
  consent.addEventListener("change", refresh);
  age.addEventListener("change", refresh);

  (function waitForTurnstile(n) {
    if (window.turnstile) {
      widgetId = window.turnstile.render("#wl-turnstile", {
        sitekey: cfg.turnstileSiteKey,
        action: "waitlist_signup",           // the server checks this exact value
        appearance: "interaction-only",      // box shows only if Cloudflare needs a click; the token is still verified server-side
        callback: (t) => { tsToken = t; refresh(); },
        "expired-callback": () => { tsToken = null; refresh(); },
        "error-callback": () => { tsToken = null; refresh(); },
      });
    } else if (n < 100) setTimeout(() => waitForTurnstile(n + 1), 100);
    else say("Could not load the verification step. Please disable blockers for this page and reload.");
  })(0);

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    if (busy) return;
    if (!email.value || email.value.length > 254 || !email.validity.valid) return say(MESSAGES.invalid_email);
    if (!consent.checked || !age.checked) return say(MESSAGES.consent_required);
    busy = true; refresh(); say("Sending…");
    try {
      const res = await fetch(cfg.api + "/signup", {
        method: "POST",
        headers: { "content-type": "application/json" },
        credentials: "omit",                 // no cookies, ever
        body: JSON.stringify({
          email: email.value, consent: true, age_16_plus: true,
          consent_version: form.dataset.consentVersion,
          locale: (navigator.language || "").slice(0, 5).replace("_", "-"),
          source: new URLSearchParams(location.search).get("src") || null,
          website: document.getElementById("wl-website").value,
          elapsed_ms: Date.now() - startedAt,
          turnstile: tsToken,
        }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.status === 202) { form.reset(); say(MESSAGES.check_inbox); }
      else say(MESSAGES[data.error] || MESSAGES.try_later);
    } catch {
      say(MESSAGES.try_later);
    } finally {
      busy = false; tsToken = null;
      if (window.turnstile && widgetId !== null) window.turnstile.reset(widgetId); // a token is single-use
      refresh();
    }
  });
})();
