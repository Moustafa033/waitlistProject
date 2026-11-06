"use strict";
(function () {
  const cfg = window.WAITLIST;
  const btn = document.getElementById("wl-unsub");
  const status = document.getElementById("wl-status");
  const say = (m) => { status.textContent = m; };
  const p = new URLSearchParams(location.hash.slice(1));
  const id = p.get("id"), t = p.get("t");
  history.replaceState(null, "", location.pathname);
  if (!id || !t) { btn.disabled = true; say("This link is incomplete. Use the unsubscribe link in our email."); return; }
  btn.addEventListener("click", async () => {
    btn.disabled = true; say("Working…");
    try {
      const res = await fetch(cfg.api + "/unsubscribe", {
        method: "POST", credentials: "omit",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ id, t }),
      });
      const data = await res.json().catch(() => ({}));
      say(res.ok && data.ok ? "Done. You will not receive any more emails from us." : "This link is not valid. Reply to any of our emails and we will remove you by hand.");
    } catch { say("Something went wrong. Please try again."); btn.disabled = false; }
  });
})();
