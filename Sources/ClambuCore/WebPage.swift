enum WebPage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="theme-color" content="#0e0e0f">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <title>clambu</title>
    <style>
      :root {
        --bg: #0e0e0f;
        --text: #ecebe8;
        --dim: #8a8985;
        --faint: #2a2a2b;
        --sand: #c9a35a;
        --good: #7ec480;
        --busy: #7aa2f7;
        --warn: #e8a84e;
        --bad: #e5604d;
        --aspect: 1680 / 1080;
        color-scheme: dark;
      }
      * { box-sizing: border-box; }
      html, body { height: 100%; }
      body {
        margin: 0;
        background: var(--bg);
        color: var(--text);
        font: 15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        -webkit-font-smoothing: antialiased;
        font-variant-numeric: tabular-nums;
      }
      main {
        min-height: 100%;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        padding: max(16px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right))
                 max(16px, env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left));
      }
      figure { margin: 0; width: min(100%, 1100px, calc((100vh - 140px) * var(--aspect))); }
      .frame {
        position: relative;
        aspect-ratio: var(--aspect);
        border-radius: 12px;
        overflow: hidden;
        background: #050505;
      }
      .frame img {
        position: absolute; inset: 0;
        width: 100%; height: 100%;
        object-fit: contain;
        opacity: 0; transition: opacity .4s ease;
      }
      .frame img.shown { opacity: 1; }
      .frame .empty[hidden] { display: none; }
      .frame .empty {
        position: absolute; inset: 0;
        display: grid; place-items: center;
        color: var(--dim); font-size: 13px;
      }
      .track { height: 2px; margin-top: 14px; background: var(--faint); border-radius: 1px; overflow: hidden; }
      .track > div { height: 100%; width: 0; background: var(--sand); transition: width .8s ease; }
      figcaption {
        display: flex; justify-content: space-between; align-items: baseline; gap: 16px;
        margin-top: 12px;
      }
      .left { display: flex; align-items: baseline; gap: 10px; min-width: 0; }
      .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--dim); flex: none; transform: translateY(-1px); }
      .job { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .state { color: var(--dim); white-space: nowrap; }
      .right { color: var(--dim); white-space: nowrap; }
      .right b { color: var(--text); font-weight: 500; }
      .alert { margin-top: 10px; color: var(--bad); font-size: 13px; }
      .alert:empty { display: none; }
      .good { background: var(--good); } .busy { background: var(--busy); } .warn { background: var(--warn); }
      .bad { background: var(--bad); } .done { background: var(--sand); }
      .live .dot.good { animation: pulse 2.4s ease-in-out infinite; }
      @keyframes pulse { 50% { opacity: .35; } }
      @media (max-width: 560px) {
        .frame { border-radius: 10px; }
        figcaption { flex-direction: column; gap: 4px; }
      }
      @media (prefers-reduced-motion: reduce) { * { transition: none !important; animation: none !important; } }
    </style>
    </head>
    <body>
    <main>
      <figure>
        <div class="frame">
          <img id="a" alt="The printer's camera"><img id="b" alt="">
          <div class="empty" id="empty">Waiting for the camera</div>
        </div>
        <div class="track"><div id="bar"></div></div>
        <figcaption>
          <div class="left"><span class="dot" id="dot"></span><span class="job" id="job">clambu</span><span class="state" id="state">connecting</span></div>
          <div class="right" id="right"></div>
        </figcaption>
        <div class="alert" id="alert"></div>
      </figure>
    </main>
    <script>
      const $ = id => document.getElementById(id);
      const two = n => String(n).padStart(2, "0");
      const timeOfDay = iso => { const d = new Date(iso); return two(d.getHours()) + ":" + two(d.getMinutes()); };
      const tone = s => {
        if (!s.state || (s.alerts && s.alerts.length) || s.state === "FAILED") return s.state ? "bad" : "";
        return { RUNNING: "good", PREPARE: "busy", PAUSE: "warn", FINISH: "done" }[s.state] || "";
      };
      let frameAt = "", front = "a";

      function showState(s, connected) {
        document.title = s.busy && s.percent != null ? s.percent + "% " + (s.job || "clambu") : (s.job || "clambu");
        $("job").textContent = s.job || "clambu";
        $("state").textContent = connected === false ? "lost the printer" : s.label;
        $("dot").className = "dot " + tone(s);
        document.body.classList.toggle("live", s.state === "RUNNING");
        $("bar").style.width = (s.busy ? s.percent || 0 : s.state === "FINISH" ? 100 : 0) + "%";
        let right = "";
        if (s.busy) {
          if (s.layer != null && s.total_layers) right += "layer <b>" + s.layer + "</b> of " + s.total_layers;
          if (s.remaining_minutes != null) {
            const m = s.remaining_minutes, left = m >= 60 ? Math.floor(m / 60) + "h " + two(m % 60) + "m" : m + "m";
            right += (right ? " · " : "") + left + " left";
          }
          if (s.finish_at) right += " · done <b>" + timeOfDay(s.finish_at) + "</b>";
        } else {
          right = s.nozzle + "° nozzle · " + s.bed + "° bed";
        }
        $("right").innerHTML = right;
        $("alert").textContent = (s.alerts || []).map(a => "The printer says " + a).join(" · ");
      }

      function showFrame(at) {
        if (!at || at === frameAt) return;
        frameAt = at;
        const back = front === "a" ? "b" : "a";
        const img = $(back);
        img.onload = () => {
          if (img.naturalWidth) document.documentElement.style.setProperty("--aspect", img.naturalWidth + " / " + img.naturalHeight);
          img.classList.add("shown"); $(front).classList.remove("shown"); front = back; $("empty").hidden = true; };
        img.src = "/api/frame.jpg?t=" + encodeURIComponent(at);
      }

      async function poll() {
        try {
          const s = await (await fetch("/api/status", { cache: "no-store" })).json();
          showState(s.state, s.connected);
          showFrame(s.frame_at);
        } catch (e) {
          $("state").textContent = "clambu has stopped";
          $("dot").className = "dot";
        }
      }

      function listen() {
        const es = new EventSource("/api/events");
        es.addEventListener("status", e => { const d = JSON.parse(e.data); if (d.state) showState(d.state, true); });
        es.addEventListener("frame", e => showFrame(JSON.parse(e.data).at));
        es.onerror = () => { es.close(); poll(); setTimeout(listen, 5000); };
      }

      poll();
      listen();
      setInterval(poll, 30000);
    </script>
    </body>
    </html>
    """#
}
