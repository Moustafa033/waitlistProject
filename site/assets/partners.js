"use strict";
// "Work with us" form. The server re-checks everything; these checks only give quick, friendly feedback.
(function () {
  const cfg = window.WAITLIST;
  const form = document.getElementById("pa-form");
  const name = document.getElementById("pa-name");
  const email = document.getElementById("pa-email");
  const pitch = document.getElementById("pa-pitch");
  const age = document.getElementById("pa-age");
  const consent = document.getElementById("pa-consent");
  const btn = document.getElementById("pa-submit");
  const status = document.getElementById("pa-status");
  const startedAt = Date.now();
  let tsToken = null, widgetId = null, busy = false, sent = false;

  // Output uses textContent only (no HTML-parsing sinks) => no DOM XSS.
  const say = (msg) => { status.textContent = msg; };
  const MESSAGES = {
    application_received: "Thanks! We received your application. Check your inbox for our email.",
    invalid_email: "Please enter a valid email address.",
    use_another_email: "Please use a permanent email address.",
    invalid_fields: "Please check your name, usernames (letters, numbers, . _ - only) and the text (10 to 1,000 characters).",
    need_handle: "Please add at least one social media account (platform and username).",
    consent_required: "Please tick both boxes.",
    reload_page: "This page was updated. Please reload it and try again.",
    verification_failed: "Verification failed. Please try again.",
    busy: "We received many applications today. Please try again tomorrow.",
    try_later: "Something went wrong on our side. Please try again in a few minutes.",
  };
  const refresh = () => { btn.disabled = sent || busy || !tsToken || !consent.checked || !age.checked; };
  consent.addEventListener("change", refresh);
  age.addEventListener("change", refresh);

  (function waitForTurnstile(n) {
    if (window.turnstile) {
      widgetId = window.turnstile.render("#pa-turnstile", {
        sitekey: cfg.turnstileSiteKey,
        action: "partner_apply",             // the server checks this exact value
        appearance: "interaction-only",
        callback: (t) => { tsToken = t; refresh(); },
        "expired-callback": () => { tsToken = null; refresh(); },
        "error-callback": () => { tsToken = null; refresh(); },
      });
    } else if (n < 100) setTimeout(() => waitForTurnstile(n + 1), 100);
    else say("Could not load the verification step. Please disable blockers for this page and reload.");
  })(0);

  // rows where a username was typed; a typed username needs a platform
  function handles() {
    const out = [];
    for (let i = 1; i <= 3; i++) {
      const p = document.getElementById("pa-p" + i).value;
      const u = document.getElementById("pa-u" + i).value.trim();
      if (u === "") continue;
      if (p === "" || !/^@?[A-Za-z0-9._-]{1,50}$/.test(u)) return null;
      out.push({ platform: p, username: u });
    }
    return out;
  }

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    if (busy || sent) return;
    const h = handles();
    const text = pitch.value.trim();
    if (!email.value || email.value.length > 254 || !email.validity.valid) return say(MESSAGES.invalid_email);
    if (h === null) return say(MESSAGES.invalid_fields);
    if (h.length === 0) return say(MESSAGES.need_handle);
    if (name.value.trim() === "" || text.length < 10) return say(MESSAGES.invalid_fields);
    if (!consent.checked || !age.checked) return say(MESSAGES.consent_required);
    busy = true; refresh(); say("Sending…");
    try {
      const res = await fetch(cfg.api + "/partner", {
        method: "POST",
        headers: { "content-type": "application/json" },
        credentials: "omit",                 // no cookies, ever
        body: JSON.stringify({
          name: name.value, email: email.value, handles: h, pitch: text,
          consent: true, age_18_plus: true,
          consent_version: form.dataset.consentVersion,
          website: document.getElementById("pa-website").value,
          elapsed_ms: Date.now() - startedAt,
          turnstile: tsToken,
        }),
      });
      const data = await res.json().catch(() => ({}));
      if (res.status === 202) { form.reset(); sent = true; say(MESSAGES.application_received); }
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
