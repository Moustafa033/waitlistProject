"use strict";
(function () {
  const cfg = window.WAITLIST;
  const unsubBtn = document.getElementById("wl-unsub");
  const eraseBtn = document.getElementById("wl-erase");
  const status = document.getElementById("wl-status");
  const say = (m) => { status.textContent = m; };   // textContent only: no HTML is ever parsed
  const p = new URLSearchParams(location.hash.slice(1));
  const id = p.get("id"), t = p.get("t");
  history.replaceState(null, "", location.pathname);   // remove the signed link from the address bar
  const setDisabled = (v) => { unsubBtn.disabled = v; eraseBtn.disabled = v; };
  if (!id || !t) { setDisabled(true); say("This link is incomplete. Use the link in our email."); return; }

  async function post(path) {
    const res = await fetch(cfg.api + path, {
      method: "POST", credentials: "omit",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ id, t }),
    });
    const data = await res.json().catch(() => ({}));
    return res.ok && data.ok === true;
  }

  // Nothing happens on page load (link scanners open every link): only a person's click acts.
  unsubBtn.addEventListener("click", async () => {
    setDisabled(true); say("Working…");
    try {
      if (await post("/unsubscribe")) say("Done. You will not receive any more emails from us.");
      else { say("This link is not valid. Use the link in our latest email."); setDisabled(false); }
    } catch { say("Something went wrong. Please try again."); setDisabled(false); }
  });

  // Deleting cannot be undone, so it needs a second click.
  let armed = false;
  eraseBtn.addEventListener("click", async () => {
    if (!armed) {
      armed = true;
      eraseBtn.textContent = "Yes, delete my data permanently";
      say("Press the button again to confirm. This cannot be undone.");
      return;
    }
    setDisabled(true); say("Deleting…");
    try {
      if (await post("/erase")) say("Done. Your data has been deleted and we will never email you again.");
      else { say("This link is not valid. Use the link in our latest email."); setDisabled(false); }
    } catch { say("Something went wrong. Please try again."); setDisabled(false); }
  });
})();
