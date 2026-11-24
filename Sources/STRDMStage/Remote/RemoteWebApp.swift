import Foundation

/// STRDM Live — the phone & iPad control app, served by the Mac on the venue network.
/// "Add to Home Screen" makes it full-screen like a native app. Phone: one column. iPad: GO column + control panes.
enum RemoteWebApp {
    static let manifest = ##"""
    {
      "name": "STRDM Live",
      "short_name": "STRDM Live",
      "start_url": "/",
      "display": "standalone",
      "orientation": "any",
      "background_color": "#07070c",
      "theme_color": "#07070c",
      "icons": [{ "src": "/icon.png", "sizes": "180x180", "type": "image/png" }]
    }
    """##

    static let html = ##"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="STRDM Live">
<meta name="theme-color" content="#07070c">
<link rel="apple-touch-icon" href="/icon.png">
<link rel="manifest" href="/manifest.json">
<title>STRDM Live</title>
<style>
  :root { --bg:#07070c; --card:#14141d; --card2:#1b1b27; --line:#262635; --text:#f4f4f8; --dim:#8b8ba0; --go:#22d462;
          --pink:#ff1493; --purple:#7a00ff; --red:#ff3b30; --amber:#ffb020; --cyan:#5ad1ff; }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; -webkit-user-select:none; user-select:none; }
  html,body { margin:0; background:var(--bg); color:var(--text); font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display",sans-serif; height:100%; overscroll-behavior:none; }
  body { padding: env(safe-area-inset-top) 14px 0; }
  #app { display:flex; flex-direction:column; height:100%; }
  #side { display:flex; flex-direction:column; }
  #main { display:flex; flex-direction:column; flex:1; min-height:0; }
  header { display:flex; align-items:center; gap:8px; padding:10px 2px 8px; }
  .brand { font-weight:900; font-size:15px; letter-spacing:.14em; background:linear-gradient(90deg,var(--pink),#b04bff); -webkit-background-clip:text; color:transparent; }
  header .title { font-weight:700; font-size:14px; flex:1; color:var(--dim); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  header .clock { font-variant-numeric:tabular-nums; color:var(--dim); font-size:14px; }
  .dot { width:9px; height:9px; border-radius:50%; background:var(--red); flex:none; }
  .dot.ok { background:var(--go); box-shadow:0 0 8px var(--go); }
  .card { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:12px 14px; }
  .standby .label { color:var(--go); font-size:11px; font-weight:800; letter-spacing:.08em; display:flex; justify-content:space-between; }
  .standby .cue { font-size:22px; font-weight:800; margin-top:2px; display:flex; gap:10px; align-items:baseline; }
  .standby .num { font-variant-numeric:tabular-nums; color:var(--dim); }
  .standby .notes { color:var(--dim); font-size:14px; margin-top:4px; }
  #go { margin:10px 0; width:100%; height:20vh; min-height:120px; border:none; border-radius:22px; background:var(--go); color:#04140a; font-size:60px; font-weight:900; letter-spacing:.04em; box-shadow:0 10px 40px rgba(34,212,98,.35); transition:transform .06s, filter .06s; }
  #go:active, #go.hit { transform:scale(.97); filter:brightness(1.25); }
  #go.locked { background:#2a2a36; color:#666; box-shadow:none; }
  .row { display:flex; gap:10px; }
  .row > button { flex:1; }
  button.btn { height:52px; border-radius:14px; border:1px solid var(--line); background:var(--card); color:var(--text); font-size:16px; font-weight:700; }
  button.btn:active { filter:brightness(1.4); }
  button.stop { background:#2b1416; border-color:#5a2026; color:#ff8a8a; }
  button.stop.armed { background:var(--red); color:#fff; }
  button.panic { background:var(--red); border-color:var(--red); color:white; }
  .running { display:flex; gap:8px; overflow-x:auto; margin:10px 0 4px; min-height:46px; scrollbar-width:none; }
  .running::-webkit-scrollbar { display:none; }
  .chip { flex:none; background:var(--card); border:1px solid var(--line); border-radius:12px; padding:6px 10px; min-width:150px; }
  .chip .t { font-size:13px; font-weight:700; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; max-width:190px; }
  .chip .bar { height:4px; background:#2a2a36; border-radius:2px; margin-top:5px; overflow:hidden; }
  .chip .bar i { display:block; height:100%; background:var(--go); }
  .chip .s { font-size:11px; color:var(--dim); margin-top:3px; font-variant-numeric:tabular-nums; }
  .empty { color:#555566; font-size:13px; padding:12px 2px; }
  nav { display:flex; gap:4px; margin:8px 0; background:var(--card); border-radius:12px; padding:4px; border:1px solid var(--line); overflow-x:auto; scrollbar-width:none; flex:none; }
  nav::-webkit-scrollbar { display:none; }
  nav button { flex:1 0 auto; border:none; background:none; color:var(--dim); font-size:14px; font-weight:700; padding:9px 12px; border-radius:9px; white-space:nowrap; }
  nav button.on { background:linear-gradient(135deg,rgba(255,20,147,.35),rgba(122,0,255,.35)); color:var(--text); }
  .pane { flex:1; overflow-y:auto; -webkit-overflow-scrolling:touch; padding-bottom:calc(env(safe-area-inset-bottom) + 24px); }
  .cue-row { display:flex; align-items:center; gap:10px; padding:12px 10px; border-bottom:1px solid var(--line); }
  .cue-row.sb { background:rgba(34,212,98,.12); border-radius:10px; }
  .cue-row .n { width:34px; font-weight:800; color:var(--dim); font-variant-numeric:tabular-nums; }
  .cue-row .k { width:24px; text-align:center; }
  .cue-row .nm { flex:1; font-size:15px; }
  .cue-row .ac { font-size:11px; color:var(--cyan); font-weight:800; }
  .cue-row .live { width:8px; height:8px; border-radius:50%; background:var(--go); box-shadow:0 0 6px var(--go); }
  .section-title { color:var(--dim); font-size:12px; font-weight:800; letter-spacing:.06em; margin:16px 2px 8px; display:flex; justify-content:space-between; }
  .grid { display:grid; grid-template-columns:repeat(2,1fr); gap:8px; }
  .grid button { min-height:56px; border-radius:12px; border:1px solid var(--line); background:var(--card); color:var(--text); font-weight:700; font-size:15px; padding:6px; }
  .grid button.on { border-color:var(--pink); box-shadow:inset 0 0 0 1px var(--pink); background:#2a1424; }
  input[type=range] { width:100%; height:44px; accent-color:var(--pink); }
  .toggle { width:100%; height:60px; border-radius:16px; border:none; font-size:18px; font-weight:800; }
  .toggle.on { background:linear-gradient(135deg,var(--pink),var(--purple)); color:white; }
  .toggle.off { background:#22222d; color:#aaa; }
  .toggle.danger { background:var(--red); color:white; }
  .song { background:linear-gradient(135deg,rgba(255,20,147,.22),rgba(122,0,255,.22)); border:1px solid #4a2a5a; }
  .song .nm { font-weight:800; font-size:17px; }
  .song .meta { color:#d7c8ea; font-size:13px; margin-top:3px; font-variant-numeric:tabular-nums; }
  .beats { display:flex; gap:6px; margin-top:8px; }
  .beats i { width:14px; height:14px; border-radius:50%; background:rgba(255,255,255,.15); }
  .beats i.on { background:white; } .beats i.on.one { background:var(--pink); }
  /* EQ faders */
  .eq { display:flex; gap:6px; justify-content:space-between; background:var(--card); border:1px solid var(--line); border-radius:16px; padding:12px 8px; }
  .fader { flex:1; display:flex; flex-direction:column; align-items:center; gap:6px; min-width:0; }
  .fader .val { font-size:11px; color:var(--dim); font-variant-numeric:tabular-nums; height:14px; }
  .fader .lab { font-size:11px; font-weight:800; color:#ccc; }
  .track { position:relative; width:30px; height:190px; border-radius:15px; background:#0d0d14; border:1px solid var(--line); touch-action:none; }
  .track .zero { position:absolute; left:3px; right:3px; top:50%; height:1px; background:#3a3a4a; }
  .track .fill { position:absolute; left:11px; width:8px; border-radius:4px; background:linear-gradient(var(--pink),var(--purple)); }
  .track .knob { position:absolute; left:-3px; width:36px; height:22px; border-radius:8px; background:#e9e9f2; box-shadow:0 2px 8px rgba(0,0,0,.6); }
  .meter { height:10px; background:#0d0d14; border-radius:5px; overflow:hidden; border:1px solid var(--line); }
  .meter i { display:block; height:100%; background:linear-gradient(90deg,var(--go),var(--amber) 75%,var(--red)); }
  canvas#map { width:100%; border-radius:16px; background:#050508; border:1px solid var(--line); display:block; }
  .pill { display:inline-block; padding:3px 9px; border-radius:20px; font-size:12px; font-weight:800; }
  .pill.red { background:rgba(255,59,48,.2); color:#ff8a8a; } .pill.green { background:rgba(34,212,98,.18); color:#7ef0a8; }
  .sheet-bg { position:fixed; inset:0; background:rgba(0,0,0,.55); display:none; align-items:flex-end; justify-content:center; z-index:10; }
  .sheet { width:100%; max-width:520px; background:#1b1b26; border-radius:20px 20px 0 0; padding:16px 14px calc(env(safe-area-inset-bottom) + 14px); }
  .sheet h3 { margin:2px 4px 12px; font-size:17px; }
  .sheet button { width:100%; margin-bottom:8px; }
  #pin { position:fixed; inset:0; background:var(--bg); display:none; flex-direction:column; align-items:center; justify-content:center; gap:16px; padding:30px; z-index:20; text-align:center; }
  #pin input { font-size:40px; width:200px; text-align:center; letter-spacing:.4em; background:var(--card); color:var(--text); border:1px solid var(--line); border-radius:14px; padding:10px; -webkit-user-select:text; user-select:text; }
  .muted { color:var(--dim); font-size:14px; }
  .lockrow { display:flex; align-items:center; justify-content:space-between; color:var(--dim); font-size:14px; padding:8px 2px; }
  .list-item { display:flex; justify-content:space-between; align-items:center; padding:12px 4px; border-bottom:1px solid var(--line); font-size:15px; }

  /* iPad / wide screens: GO column on the left, controls on the right */
  @media (min-width: 760px) {
    body { padding: env(safe-area-inset-top) 18px 0; }
    #app { flex-direction:row; gap:18px; }
    #side { width:min(400px, 40vw); flex:none; height:100%; overflow-y:auto; padding-bottom:calc(env(safe-area-inset-bottom) + 16px); }
    #main { padding-top:10px; }
    #go { height:30vh; min-height:200px; font-size:84px; }
    .standby .cue { font-size:28px; }
    button.btn { height:62px; font-size:18px; }
    .running { flex-wrap:wrap; overflow:visible; }
    nav { margin-top:0; }
    nav button { font-size:16px; padding:12px 14px; }
    .grid { grid-template-columns:repeat(auto-fill,minmax(170px,1fr)); }
    .grid button { min-height:72px; font-size:17px; }
    .track { height:300px; width:40px; border-radius:20px; }
    .track .fill { left:16px; }
    .track .knob { width:48px; left:-5px; height:26px; }
    .fader .lab { font-size:13px; } .fader .val { font-size:12px; }
    .cue-row { padding:16px 12px; } .cue-row .nm { font-size:17px; }
    .two { display:grid; grid-template-columns:1fr 1fr; gap:16px; }
  }
</style>
</head>
<body>
<div id="app">
  <div id="side">
    <header><div class="dot" id="conn"></div><div class="brand">STRDM LIVE</div><div class="title" id="show"></div><div class="clock" id="clock"></div></header>
    <div class="card standby">
      <div class="label"><span>STANDBY</span><span id="sfxPill"></span></div>
      <div class="cue"><span class="num" id="sbNum">–</span><span id="sbName">Connecting…</span></div>
      <div class="notes" id="sbNotes"></div>
    </div>
    <button id="go">GO</button>
    <div class="row">
      <button class="btn" data-a="prev">▲ Prev</button>
      <button class="btn" data-a="next">▼ Next</button>
    </div>
    <div class="row" style="margin-top:10px">
      <button class="btn stop" id="stop">Stop All</button>
      <button class="btn panic" data-a="panic">Panic</button>
      <button class="btn panic" data-a="sfxStop">SFX E-STOP</button>
    </div>
    <div class="running" id="running"></div>
  </div>
  <div id="main">
    <nav id="nav">
      <button data-tab="cues" class="on">Cues</button>
      <button data-tab="lights">Lights</button>
      <button data-tab="map">Live Map</button>
      <button data-tab="sound">Sound</button>
      <button data-tab="screens">Screens</button>
      <button data-tab="fx">Effects</button>
      <button data-tab="crew">Crew</button>
    </nav>
    <div class="pane" id="pane"></div>
  </div>
</div>

<div class="sheet-bg" id="sheetBg"><div class="sheet" id="sheet"></div></div>

<div id="pin">
  <div class="brand" style="font-size:34px">STRDM LIVE</div>
  <div class="muted">Enter the 4-digit PIN shown on the Mac in <b>Control &amp; Log → Phone Remote</b>, or scan the QR code there.</div>
  <input id="pinInput" inputmode="numeric" maxlength="4" autocomplete="one-time-code">
  <button class="btn" style="width:200px;background:var(--go);color:#04140a" id="pinGo">Connect</button>
</div>

<script>
  const KIND = { audio:"🎵", lights:"💡", video:"🎬", videoBlack:"⬛", fade:"🔉", vocalFX:"🎤", wait:"⏳", memo:"📝", layered:"🧩", effect:"🔥" };
  const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));
  const fmt = s => { s = Math.max(0, s || 0); const m = Math.floor(s / 60), r = Math.floor(s % 60); return m + ":" + String(r).padStart(2, "0"); };
  const $ = id => document.getElementById(id);

  const params = new URLSearchParams(location.search);
  if (params.get("t")) localStorage.setItem("strdmToken", params.get("t"));
  let token = localStorage.getItem("strdmToken") || "";
  let state = null, tab = localStorage.getItem("strdmTab") || "cues", goLocked = localStorage.getItem("strdmGoLock") === "1";
  let lastGo = 0, stopArmedUntil = 0, failures = 0, dragging = false;

  async function api(path, body) {
    const res = await fetch(path, { method: body ? "POST" : "GET",
      headers: { "X-Remote-Token": token, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined, cache: "no-store" });
    if (res.status === 401) { showPin(); throw new Error("pin"); }
    if (!res.ok) throw new Error("http " + res.status);
    return res.json();
  }
  async function act(action, extra) { try { state = await api("/api/action", Object.assign({ action }, extra || {})); render(); } catch (e) {} }
  async function poll() {
    try { state = await api("/api/state"); failures = 0; $("conn").classList.add("ok"); render(); }
    catch (e) { failures++; if (failures > 2) $("conn").classList.remove("ok"); }
  }
  function showPin() { $("pin").style.display = "flex"; setTimeout(() => $("pinInput").focus(), 50); }
  $("pinGo").onclick = () => { token = $("pinInput").value.trim(); localStorage.setItem("strdmToken", token); $("pin").style.display = "none"; poll(); };

  $("go").addEventListener("touchstart", e => { e.preventDefault(); fireGo(); }, { passive: false });
  $("go").addEventListener("click", fireGo);
  function fireGo() {
    if (goLocked) return;
    const now = Date.now(); if (now - lastGo < 400) return; lastGo = now;
    $("go").classList.add("hit"); setTimeout(() => $("go").classList.remove("hit"), 140);
    if (navigator.vibrate) navigator.vibrate(15);
    act("go");
  }
  $("stop").onclick = () => {
    if (Date.now() < stopArmedUntil) { stopArmedUntil = 0; act("stop"); renderStop(); return; }
    stopArmedUntil = Date.now() + 2000; renderStop(); setTimeout(renderStop, 2050);
  };
  function renderStop() { const armed = Date.now() < stopArmedUntil; $("stop").classList.toggle("armed", armed); $("stop").textContent = armed ? "Tap again" : "Stop All"; }
  document.querySelectorAll("[data-a]").forEach(b => b.onclick = () => act(b.dataset.a));

  function selectTab(t) {
    tab = t; localStorage.setItem("strdmTab", t);
    document.querySelectorAll("#nav button").forEach(x => x.classList.toggle("on", x.dataset.tab === t));
    lastKey = ""; render(true);
  }
  document.querySelectorAll("#nav button").forEach(b => b.onclick = () => selectTab(b.dataset.tab));

  function sheet(title, buttons) {
    $("sheet").innerHTML = "<h3>" + esc(title) + "</h3>" + buttons.map((b, i) => '<button class="btn ' + (b.cls || "") + '" data-i="' + i + '">' + esc(b.label) + "</button>").join("") + '<button class="btn" data-i="x">Cancel</button>';
    $("sheetBg").style.display = "flex";
    $("sheet").querySelectorAll("button").forEach(btn => btn.onclick = () => { $("sheetBg").style.display = "none"; const i = btn.dataset.i; if (i !== "x") buttons[+i].run(); });
  }
  $("sheetBg").onclick = e => { if (e.target === $("sheetBg")) $("sheetBg").style.display = "none"; };

  let lastKey = "";
  function render(force) {
    if (!state) return;
    $("show").textContent = state.show;
    $("clock").textContent = state.clock;
    const sb = state.standby;
    $("sbNum").textContent = sb ? sb.number : "";
    $("sbName").textContent = sb ? (KIND[sb.kind] || "") + " " + sb.name : "End of cue list";
    $("sbNotes").textContent = sb ? sb.notes : "";
    $("sfxPill").innerHTML = state.sfxUnits ? (state.sfxArmed ? '<span class="pill red">SFX ARMED</span>' : '<span class="pill green">SFX SAFE</span>') : "";
    $("go").classList.toggle("locked", goLocked);
    $("go").textContent = goLocked ? "LOCKED" : "GO";
    $("running").innerHTML = state.running.length ? state.running.map(r =>
      '<div class="chip"><div class="t">' + (KIND[r.kind] || "") + " " + esc(r.number) + " " + esc(r.title) + '</div>' +
      '<div class="bar"><i style="width:' + Math.round((r.progress ?? 1) * 100) + '%;' + (r.phase === "pre-wait" ? "background:var(--amber)" : r.phase === "fading" ? "background:var(--cyan)" : "") + '"></i></div>' +
      '<div class="s">' + (r.remaining != null ? "-" + fmt(r.remaining) : fmt(r.elapsed) + " ∞") + (r.phase !== "running" ? " · " + r.phase : "") + "</div></div>"
    ).join("") : '<div class="empty">Nothing running</div>';

    if (tab === "map") { drawMap(); if (!force && $("map")) return; }
    if (dragging) return;
    const key = tab + JSON.stringify(keyFor(tab));
    if (!force && key === lastKey) return;
    lastKey = key;
    const p = $("pane");
    ({ cues: renderCues, lights: renderLights, map: renderMap, sound: renderSound, screens: renderScreens, fx: renderFX, crew: renderCrew }[tab] || renderCues)(p);
  }
  function keyFor(t) {
    const s = state;
    switch (t) {
      case "cues": return [s.cues, s.standbyIndex];
      case "lights": return [s.blackout, s.scenes, s.activeScene, s.performers, s.follow, s.song && s.song.section, s.song && s.song.beat, Math.round(s.gm * 100)];
      case "sound": return [s.eq, Math.round(s.masterGain * 2), Math.round(s.outputLevel * 20), s.vocalEnabled, s.vocalBypass, s.vocalPresets];
      case "screens": return [s.screens, s.visualStyle];
      case "fx": return [s.sfxArmed, s.sfxUnits];
      case "crew": return [s.crew];
      default: return [];
    }
  }

  // ── Cues
  function renderCues(p) {
    p.innerHTML = state.cues.map((c, i) =>
      '<div class="cue-row ' + (i === state.standbyIndex ? "sb" : "") + '" data-i="' + i + '">' +
      '<div class="n">' + (i === state.standbyIndex ? "▶" : esc(c.number)) + '</div><div class="k">' + (KIND[c.kind] || "") + '</div>' +
      '<div class="nm">' + esc(c.name) + '</div>' + (c.auto ? '<div class="ac">' + esc(c.auto) + "</div>" : "") + (c.running ? '<div class="live"></div>' : "") + "</div>"
    ).join("") + '<div class="lockrow"><span>GO lock (stops pocket taps)</span><button class="btn" id="lockBtn" style="height:38px;padding:0 14px">' + (goLocked ? "Unlock" : "Lock") + "</button></div>";
    p.querySelectorAll(".cue-row").forEach(row => row.onclick = () => {
      const c = state.cues[+row.dataset.i];
      sheet(c.number + "  " + c.name, [
        { label: "Set as standby", run: () => act("standby", { id: c.id }) },
        { label: "Fire this cue now", run: () => act("fire", { id: c.id }) }
      ]);
    });
    $("lockBtn").onclick = () => { goLocked = !goLocked; localStorage.setItem("strdmGoLock", goLocked ? "1" : "0"); render(true); };
  }

  // ── Lights
  function renderLights(p) {
    const s = state.song;
    let h = "";
    if (s) {
      const beat = s.beat % 4;
      h += '<div class="card song"><div class="nm">' + esc(s.name) + '</div><div class="meta">' + esc(s.section) + " · " + Math.round(s.bpm) + " BPM · " + esc(s.vibe) + " · " + fmt(s.elapsed) + " / " + fmt(s.duration) + '</div><div class="beats">' + [0, 1, 2, 3].map(b => '<i class="' + (b === beat ? "on" : "") + (b === 0 ? " one" : "") + '"></i>').join("") + "</div></div>";
    }
    h += '<div class="section-title">MASTER</div><button class="toggle ' + (state.blackout ? "danger" : "off") + '" id="bo">' + (state.blackout ? "BLACKOUT ON" : "Blackout") + "</button>";
    h += '<div class="section-title"><span>GRAND MASTER</span><span id="gmv" style="font-size:22px;color:var(--text)">' + Math.round(state.gm * 100) + '%</span></div><input type="range" min="0" max="100" step="1" value="' + Math.round(state.gm * 100) + '" id="gm"><div class="row"><button class="btn" data-gm="-10">−10</button><button class="btn" data-gm="-1">−1</button><button class="btn" data-gmset="0">0</button><button class="btn" data-gmset="50">50</button><button class="btn" data-gmset="100">100</button><button class="btn" data-gm="1">+1</button><button class="btn" data-gm="10">+10</button></div>';
    if (state.scenes.length) h += '<div class="section-title">SCENES (2 s fade)</div><div class="grid">' + state.scenes.map(sc => '<button data-scene="' + sc.id + '" class="' + (sc.id === state.activeScene ? "on" : "") + '">' + esc(sc.name) + "</button>").join("") + "</div>";
    if (state.performers.length) h += '<div class="section-title">MOVING HEADS FOLLOW</div><div class="grid"><button data-follow="" class="' + (!state.follow ? "on" : "") + '">Nobody</button>' + state.performers.map(x => '<button data-follow="' + x.id + '" class="' + (x.id === state.follow ? "on" : "") + '">🎯 ' + esc(x.name) + "</button>").join("") + "</div>";
    p.innerHTML = h;
    $("bo").onclick = () => act("blackout", { on: !state.blackout });
    const gm = $("gm");
    gm.oninput = () => { dragging = true; $("gmv").textContent = gm.value + "%"; throttle("gm", { value: gm.value / 100 }); };
    gm.onchange = () => { dragging = false; act("gm", { value: gm.value / 100 }); };
    p.querySelectorAll("[data-gm]").forEach(b => b.onclick = () => act("gm", { value: Math.max(0, Math.min(100, Math.round(state.gm * 100) + +b.dataset.gm)) / 100 }));
    p.querySelectorAll("[data-gmset]").forEach(b => b.onclick = () => act("gm", { value: +b.dataset.gmset / 100 }));
    p.querySelectorAll("[data-scene]").forEach(b => b.onclick = () => act("scene", { id: b.dataset.scene, fade: 2 }));
    p.querySelectorAll("[data-follow]").forEach(b => b.onclick = () => act("follow", b.dataset.follow ? { id: b.dataset.follow } : {}));
  }
  const timers = {};
  function throttle(action, body) {
    timers[action] = timers[action] || {}; timers[action].body = body;
    if (timers[action].t) return;
    timers[action].t = setTimeout(() => { const b = timers[action].body; timers[action].t = null; act(action, b); }, 90);
  }

  // ── Live map
  function renderMap(p) {
    p.innerHTML = '<canvas id="map"></canvas><div class="muted" style="margin:8px 2px">Live view of every fixture, laser and performer. Brighter dots = brighter lights.</div>';
    drawMap();
  }
  function drawMap() {
    const cv = $("map"); if (!cv || !state.map) return;
    const m = state.map, dpr = window.devicePixelRatio || 1;
    const W = cv.clientWidth, pad = 26;
    const minX = Math.min(0, ...m.lights.map(l => l.x), ...m.items.map(i => i.x)) - 1, maxX = Math.max(m.w, ...m.lights.map(l => l.x), ...m.items.map(i => i.x)) + 1;
    const minY = Math.min(-1, ...m.lights.map(l => l.y), ...m.items.map(i => i.y)) - 1, maxY = Math.max(m.d, ...m.lights.map(l => l.y)) + 1;
    const sc = (W - pad * 2) / (maxX - minX);
    const H = Math.min(window.innerHeight * 0.7, (maxY - minY) * sc + pad * 2);
    cv.style.height = H + "px"; cv.width = W * dpr; cv.height = H * dpr;
    const g = cv.getContext("2d"); g.scale(dpr, dpr);
    // upstage at the top, audience at the bottom
    const X = x => pad + (x - minX) * sc, Y = y => H - pad - (y - minY) * sc;
    g.fillStyle = "#050508"; g.fillRect(0, 0, W, H);
    g.fillStyle = "#14141d"; g.strokeStyle = "#2c2c3c"; g.lineWidth = 1;
    g.fillRect(X(0), Y(m.d), m.w * sc, m.d * sc); g.strokeRect(X(0), Y(m.d), m.w * sc, m.d * sc);
    for (const it of m.items) {
      const [w, d, rot] = it.c.split(",").map(Number);
      g.save(); g.translate(X(it.x), Y(it.y)); g.rotate(-rot * Math.PI / 180);
      g.fillStyle = it.kind === "ledWall" ? "rgba(70,110,255,.55)" : it.kind === "truss" ? "rgba(200,200,210,.25)" : "rgba(160,110,70,.35)";
      g.fillRect(-w * sc / 2, -d * sc / 2, w * sc, Math.max(2, d * sc)); g.restore();
    }
    for (const l of m.lights) {
      const x = X(l.x), y = Y(l.y), r = Math.max(4, sc * 0.35);
      if (l.l > 0.02) {
        const grd = g.createRadialGradient(x, y, 0, x, y, r * 4);
        grd.addColorStop(0, hexA(l.c, Math.min(1, l.l))); grd.addColorStop(1, hexA(l.c, 0));
        g.fillStyle = grd; g.beginPath(); g.arc(x, y, r * 4, 0, Math.PI * 2); g.fill();
      }
      g.fillStyle = l.l > 0.02 ? l.c : "#2a2a36"; g.beginPath();
      if (l.kind === "laser") { g.moveTo(x, y - r); g.lineTo(x + r, y + r); g.lineTo(x - r, y + r); } else g.arc(x, y, r, 0, Math.PI * 2);
      g.fill();
    }
    g.font = "600 11px -apple-system"; g.textAlign = "center";
    for (const pe of m.people) {
      g.fillStyle = "#ff4fb0"; g.beginPath(); g.arc(X(pe.x), Y(pe.y), 6, 0, Math.PI * 2); g.fill();
      g.fillStyle = "#e8e8f0"; g.fillText(pe.name, X(pe.x), Y(pe.y) + 18);
    }
    g.fillStyle = "#666"; g.fillText("▼ AUDIENCE", W / 2, H - 8);
  }
  function hexA(hex, a) { const n = parseInt(hex.slice(1), 16); return "rgba(" + (n >> 16 & 255) + "," + (n >> 8 & 255) + "," + (n & 255) + "," + a + ")"; }

  // ── Sound: master EQ, volume, vocals
  function renderSound(p) {
    const e = state.eq;
    let h = '<div class="two"><div>';
    h += '<div class="section-title"><span>MASTER VOLUME</span><span id="mgv">' + (state.masterGain >= 0 ? "+" : "") + state.masterGain.toFixed(1) + ' dB</span></div><input type="range" min="-60" max="6" step="0.5" value="' + state.masterGain + '" id="mg">';
    h += '<div class="meter"><i style="width:' + Math.min(100, Math.round(state.outputLevel * 100)) + '%"></i></div>';
    h += '<div class="section-title">EQ</div><button class="toggle ' + (e.enabled ? "on" : "off") + '" id="eqOn">' + (e.enabled ? "Master EQ ON — " + esc(e.preset) : "Master EQ bypassed") + "</button>";
    h += '<div class="section-title">PRESETS</div><div class="grid">' + e.presets.map(n => '<button data-eqp="' + esc(n) + '" class="' + (n === e.preset ? "on" : "") + '">' + esc(n) + "</button>").join("") + "</div>";
    h += '</div><div>';
    h += '<div class="section-title"><span>10-BAND GRAPHIC EQ</span><span>±12 dB</span></div><div class="eq" style="opacity:' + (e.enabled ? 1 : .45) + '">' + e.gains.map((g, i) =>
      '<div class="fader"><div class="val" id="fv' + i + '">' + (g > 0 ? "+" : "") + g.toFixed(1) + '</div><div class="track" data-band="' + i + '"><div class="zero"></div><div class="fill"></div><div class="knob"></div></div><div class="lab">' + esc(e.labels[i]) + "</div></div>").join("") + "</div>";
    h += '<div class="section-title"><span>LOW CUT</span><span id="lcv">' + (e.lowCut < 20 ? "Off" : Math.round(e.lowCut) + " Hz") + '</span></div><input type="range" min="0" max="150" step="5" value="' + e.lowCut + '" id="lc">';
    h += '<div class="section-title">LIVE VOCAL</div>';
    if (!state.vocalEnabled) h += '<div class="card muted">The vocal rack is off. Turn it on in Audio &amp; Vocals on the Mac.</div>';
    else {
      h += '<button class="toggle ' + (!state.vocalBypass ? "on" : "off") + '" id="fx">' + (!state.vocalBypass ? "🎤 Auto-Tune / FX ON" : "Dry vocal (FX bypassed)") + "</button>";
      h += '<div class="muted" style="margin:8px 2px">' + (state.vocalPlugins.length ? esc(state.vocalPlugins.join(" → ")) : "No plugins loaded") + "</div>";
      if (state.vocalPresets.length) h += '<div class="grid">' + state.vocalPresets.map(v => '<button data-preset="' + v.id + '">' + esc(v.name) + "</button>").join("") + "</div>";
    }
    h += "</div></div>";
    p.innerHTML = h;
    p.querySelectorAll(".track").forEach(t => setupFader(t, e.gains[+t.dataset.band]));
    const mg = $("mg");
    mg.oninput = () => { dragging = true; $("mgv").textContent = (mg.value >= 0 ? "+" : "") + (+mg.value).toFixed(1) + " dB"; throttle("masterGain", { value: +mg.value }); };
    mg.onchange = () => { dragging = false; act("masterGain", { value: +mg.value }); };
    const lc = $("lc");
    lc.oninput = () => { dragging = true; $("lcv").textContent = lc.value < 20 ? "Off" : lc.value + " Hz"; throttle("eqLowCut", { value: +lc.value }); };
    lc.onchange = () => { dragging = false; act("eqLowCut", { value: +lc.value }); };
    $("eqOn").onclick = () => act("eqEnabled", { on: !e.enabled });
    p.querySelectorAll("[data-eqp]").forEach(b => b.onclick = () => act("eqPreset", { name: b.dataset.eqp }));
    if ($("fx")) $("fx").onclick = () => act("vocalBypass", { on: !state.vocalBypass });
    p.querySelectorAll("[data-preset]").forEach(b => b.onclick = () => act("vocalPreset", { id: b.dataset.preset }));
  }
  function setupFader(track, gain) {
    const band = +track.dataset.band, knob = track.querySelector(".knob"), fill = track.querySelector(".fill");
    function place(g) {
      const h = track.clientHeight, kh = knob.offsetHeight, y = (1 - (g + 12) / 24) * (h - kh);
      knob.style.top = y + "px";
      const mid = h / 2, ky = y + kh / 2;
      fill.style.top = Math.min(mid, ky) + "px"; fill.style.height = Math.abs(ky - mid) + "px";
      $("fv" + band).textContent = (g > 0 ? "+" : "") + g.toFixed(1);
    }
    place(gain);
    function fromEvent(ev) {
      const r = track.getBoundingClientRect(), kh = knob.offsetHeight;
      const y = Math.max(0, Math.min(r.height - kh, ev.clientY - r.top - kh / 2));
      return Math.round((12 - y / (r.height - kh) * 24) * 2) / 2;
    }
    track.addEventListener("pointerdown", ev => { dragging = true; track.setPointerCapture(ev.pointerId); const g = fromEvent(ev); place(g); throttle("eqBand", { band, gain: g }); });
    track.addEventListener("pointermove", ev => { if (!track.hasPointerCapture(ev.pointerId)) return; const g = fromEvent(ev); place(g); throttle("eqBand", { band, gain: g }); });
    const end = ev => { if (!track.hasPointerCapture(ev.pointerId)) return; track.releasePointerCapture(ev.pointerId); dragging = false; act("eqBand", { band, gain: fromEvent(ev) }); };
    track.addEventListener("pointerup", end); track.addEventListener("pointercancel", () => { dragging = false; });
    track.addEventListener("dblclick", () => { place(0); act("eqBand", { band, gain: 0 }); });
  }

  // ── Screens
  function renderScreens(p) {
    let h = '<div class="section-title">OUTPUTS</div>';
    h += state.screens.map(s => '<div class="list-item"><span>' + (s.open ? "🟢 " : "⚪️ ") + esc(s.name) + '</span><span class="muted">' + esc(s.showing || "—") + "</span></div>").join("");
    h += '<div class="row" style="margin-top:12px"><button class="btn" id="openOut">Open outputs</button><button class="btn" id="test">Test pattern</button><button class="btn stop" id="black">Screens to black</button></div>';
    h += '<div class="section-title">VISUALS</div><div class="grid"><button data-vis="" class="' + (!state.visualStyle ? "on" : "") + '">Auto (follow the song)</button>' +
      state.visualStyles.map(v => '<button data-vis="' + v.id + '" class="' + (v.id === state.visualStyle ? "on" : "") + '">' + esc(v.name) + "</button>").join("") + "</div>";
    p.innerHTML = h;
    $("openOut").onclick = () => act("openOutputs");
    $("test").onclick = () => act("testPattern");
    $("black").onclick = () => act("screensBlack");
    p.querySelectorAll("[data-vis]").forEach(b => b.onclick = () => act("visual", b.dataset.vis ? { style: b.dataset.vis } : {}));
  }

  // ── Effects (safety only)
  function renderFX(p) {
    let h = '<div class="section-title">SPECIAL EFFECTS</div>';
    if (!state.sfxUnits) h += '<div class="card muted">No effects units patched.</div>';
    else {
      h += '<div class="card" style="text-align:center;font-size:20px;font-weight:800">' + (state.sfxArmed ? '<span class="pill red" style="font-size:18px">ARMED</span>' : '<span class="pill green" style="font-size:18px">SAFE</span>') + '<div class="muted" style="margin-top:8px;font-weight:500">' + state.sfxUnits + " units</div></div>";
      h += '<div style="height:12px"></div><button class="toggle danger" id="estop">E-STOP — kill all effects</button>';
      if (state.sfxArmed) h += '<div style="height:10px"></div><button class="toggle off" id="disarm">Disarm</button>';
      h += '<div class="muted" style="margin-top:12px">For safety the phone can only stop and disarm. Arming and firing stay on the Mac with the licensed operator.</div>';
    }
    p.innerHTML = h;
    if ($("estop")) $("estop").onclick = () => act("sfxStop");
    if ($("disarm")) $("disarm").onclick = () => act("sfxDisarm");
  }

  // ── AI crew checklist
  function renderCrew(p) {
    const c = state.crew;
    let h = '<div class="section-title">PRODUCTION CHECK</div>';
    if (!c) h += '<div class="card muted">Open AI Crew on the Mac once to enable this.</div>';
    else {
      h += '<div class="row"><div class="card" style="flex:1;text-align:center"><div style="font-size:30px;font-weight:900;color:var(--red)">' + c.critical + '</div><div class="muted">critical</div></div><div class="card" style="flex:1;text-align:center"><div style="font-size:30px;font-weight:900;color:var(--amber)">' + c.warnings + '</div><div class="muted">warnings</div></div></div>';
      h += c.top.map(t => '<div class="list-item">' + esc(t) + "</div>").join("") || '<div class="card muted" style="margin-top:10px">All clear ✅</div>';
      h += '<div class="row" style="margin-top:12px"><button class="btn" id="check">Run check</button><button class="btn" style="background:linear-gradient(135deg,var(--pink),var(--purple));border:none" id="fixall"' + (c.fixable ? "" : " disabled") + '>Fix all (' + c.fixable + ")</button></div>";
      h += '<div class="muted" style="margin-top:10px">The Creative Director and full Production Manager chat live on the Mac under AI Crew.</div>';
    }
    p.innerHTML = h;
    if ($("check")) $("check").onclick = () => act("crewCheck");
    if ($("fixall")) $("fixall").onclick = () => sheet("Apply all automatic fixes?", [{ label: "Fix all", run: () => act("crewFixAll") }]);
  }

  async function wake() { try { if ("wakeLock" in navigator) await navigator.wakeLock.request("screen"); } catch (e) {} }
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") { wake(); poll(); } });
  document.addEventListener("touchend", wake, { once: true });
  window.addEventListener("resize", () => { lastKey = ""; render(true); });
  wake();
  selectTab(tab);
  if (!token) showPin();
  poll();
  setInterval(poll, 250);
</script>
</body>
</html>
"""##
}
