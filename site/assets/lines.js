"use strict";
// Decorative background: thin light lines that glide in random directions and fade in and out.
// Draws on one <canvas> only (no HTML is created from data, nothing is fetched). Off for
// prefers-reduced-motion, paused while the tab is hidden, fewer lines on small screens.
(function () {
  const canvas = document.getElementById("bg-lines");
  if (!canvas || !canvas.getContext) return;
  const ctx = canvas.getContext("2d");
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  const dark = window.matchMedia("(prefers-color-scheme: dark)");
  const DIRS = [0, 45, 90, 135, 180, 225, 270, 315].map((d) => (d * Math.PI) / 180);
  const rand = (a, b) => a + Math.random() * (b - a);
  let w = 0, h = 0, lines = [], raf = 0, last = 0, rgb = "255,255,255", strength = 1;

  function readColor() {
    const s = getComputedStyle(document.documentElement);
    rgb = (s.getPropertyValue("--streak").trim() || "255,255,255").replace(/[^0-9,]/g, "");
    strength = parseFloat(s.getPropertyValue("--streak-strength")) || 1;
  }
  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    w = canvas.clientWidth; h = canvas.clientHeight;
    canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const want = w < 520 ? 9 : 16;
    while (lines.length < want) lines.push(spawn(true));
    lines.length = want;
  }
  function spawn(anyAge) {
    const max = rand(4, 9);
    return {
      x: rand(0, w), y: rand(0, h), a: DIRS[Math.floor(Math.random() * DIRS.length)],
      v: rand(25, 80), len: rand(70, 220), alpha: rand(0.18, 0.45),
      max, life: anyAge ? rand(0, max) : 0,
    };
  }
  function frame(t) {
    const dt = last ? Math.min((t - last) / 1000, 0.05) : 0;
    last = t;
    ctx.clearRect(0, 0, w, h);
    ctx.lineWidth = 1;
    for (let i = 0; i < lines.length; i++) {
      let l = lines[i];
      l.life += dt;
      if (l.life >= l.max) { l = lines[i] = spawn(false); }
      const cx = Math.cos(l.a), cy = Math.sin(l.a);
      l.x += cx * l.v * dt; l.y += cy * l.v * dt;
      const fade = Math.sin((Math.PI * l.life) / l.max);          // 0 -> 1 -> 0 over its life
      const a = (l.alpha * fade * strength).toFixed(3);
      const tx = l.x - cx * l.len, ty = l.y - cy * l.len;
      const g = ctx.createLinearGradient(l.x, l.y, tx, ty);
      g.addColorStop(0, "rgba(" + rgb + "," + a + ")");
      g.addColorStop(1, "rgba(" + rgb + ",0)");
      ctx.strokeStyle = g;
      ctx.beginPath(); ctx.moveTo(l.x, l.y); ctx.lineTo(tx, ty); ctx.stroke();
    }
    raf = requestAnimationFrame(frame);
  }
  function start() { if (!raf && !reduce.matches && !document.hidden) { last = 0; raf = requestAnimationFrame(frame); } }
  function stop() { if (raf) { cancelAnimationFrame(raf); raf = 0; } }
  function sync() { if (reduce.matches) { stop(); ctx.clearRect(0, 0, w, h); } else start(); }

  readColor(); resize();
  window.addEventListener("resize", resize);
  document.addEventListener("visibilitychange", () => (document.hidden ? stop() : start()));
  reduce.addEventListener("change", sync);
  dark.addEventListener("change", readColor);
  sync();
})();
