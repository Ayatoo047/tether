/// The page the phone opens in its browser. Self-contained: no external resources.
enum WebLinkPage {
    static let locked = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Tether</title><style>body{font:17px system-ui,sans-serif;display:grid;place-items:center;min-height:90vh;margin:0 24px;text-align:center;color:#333}</style>
    </head><body><div><h2>Almost there</h2><p>Scan the QR code shown in Tether on your Mac to open this page with its access key.</p></div></body></html>
    """

    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="theme-color" content="#0b78cc">
    <title>Tether</title>
    <style>
      :root { --bg:#f3f5f8; --card:#fff; --text:#15181d; --muted:#6a717c; --accent:#0b78cc; --ok:#1f9d55; --bad:#d64545; --line:#e4e7ec; }
      @media (prefers-color-scheme: dark) { :root { --bg:#0f1115; --card:#1a1d23; --text:#eef0f3; --muted:#9aa1ab; --line:#2a2e36; --accent:#3a9bff; } }
      * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
      body { margin:0; background:var(--bg); color:var(--text); font:16px/1.4 system-ui,-apple-system,Roboto,sans-serif; }
      header { padding:22px 18px 8px; }
      header h1 { margin:0; font-size:24px; }
      header p { margin:4px 0 0; color:var(--muted); font-size:14px; }
      main { padding:8px 14px 40px; max-width:640px; margin:0 auto; }
      .card { background:var(--card); border-radius:18px; padding:16px; margin:12px 0; border:1px solid var(--line); }
      .card h2 { margin:0 0 12px; font-size:17px; display:flex; align-items:center; gap:8px; }
      .send { display:block; width:100%; padding:18px; border:0; border-radius:14px; background:var(--accent); color:#fff; font-size:18px; font-weight:600; }
      .send:active { opacity:.85; }
      input[type=file] { display:none; }
      .row { display:flex; align-items:center; gap:12px; padding:10px 0; border-top:1px solid var(--line); }
      .row:first-of-type { border-top:0; }
      .thumb { width:46px; height:46px; border-radius:10px; background:var(--line); flex:none; object-fit:cover; display:grid; place-items:center; font-size:20px; }
      .info { flex:1; min-width:0; }
      .name { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; font-weight:500; }
      .meta { color:var(--muted); font-size:13px; }
      .btn { flex:none; padding:9px 14px; border-radius:10px; background:var(--accent); color:#fff; text-decoration:none; font-weight:600; font-size:14px; }
      .btn.ghost { background:transparent; color:var(--accent); border:1px solid var(--line); }
      .bar { height:6px; background:var(--line); border-radius:3px; overflow:hidden; margin-top:6px; }
      .bar i { display:block; height:100%; width:0; background:var(--accent); transition:width .2s; }
      .ok { color:var(--ok); } .bad { color:var(--bad); }
      .empty { color:var(--muted); font-size:14px; padding:6px 0; }
      .status { font-size:13px; color:var(--muted); text-align:center; margin-top:18px; }
    </style>
    </head>
    <body>
    <header>
      <h1>Tether</h1>
      <p id="mac">Connected to your Mac</p>
    </header>
    <main>
      <section class="card">
        <h2>⬆︎ Send to Mac</h2>
        <button class="send" id="pick">Choose photos &amp; files</button>
        <input type="file" id="files" multiple>
        <div id="uploads"></div>
      </section>
      <section class="card">
        <h2>⬇︎ From your Mac</h2>
        <div id="shared"><div class="empty">Files you drop into Tether on your Mac will appear here.</div></div>
      </section>
      <div class="status" id="status">Keep this page open while files are sending.</div>
    </main>
    <script>
    const key = new URLSearchParams(location.search).get('k');
    const $ = id => document.getElementById(id);
    const esc = s => s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const fmt = n => { const u=['B','KB','MB','GB','TB']; let i=0; while (n>=1000 && i<u.length-1) { n/=1000; i++; } return (i?n.toFixed(1):n)+' '+u[i]; };
    const icon = k => ({image:'🖼️', video:'🎬', audio:'🎵'}[k] || '📄');

    $('pick').onclick = () => $('files').click();
    $('files').onchange = e => { queue.push(...e.target.files); e.target.value=''; next(); };

    const queue = []; let busy = false;
    function next() {
      if (busy || !queue.length) return;
      busy = true;
      const file = queue.shift();
      const row = document.createElement('div');
      row.className = 'row';
      row.innerHTML = `<div class="thumb">${icon(file.type.split('/')[0])}</div><div class="info"><div class="name">${esc(file.name)}</div><div class="meta">Waiting…</div><div class="bar"><i></i></div></div>`;
      $('uploads').prepend(row);
      const meta = row.querySelector('.meta'), bar = row.querySelector('.bar i');
      const xhr = new XMLHttpRequest();
      xhr.open('PUT', `/up?k=${encodeURIComponent(key)}&name=${encodeURIComponent(file.name)}`);
      xhr.upload.onprogress = e => { if (e.lengthComputable) { bar.style.width = (e.loaded/e.total*100)+'%'; meta.textContent = `${fmt(e.loaded)} of ${fmt(e.total)}`; } };
      xhr.onload = () => {
        const ok = xhr.status === 200;
        bar.parentElement.remove();
        meta.innerHTML = ok ? `<span class="ok">✓ Saved on Mac</span> · ${fmt(file.size)}` : `<span class="bad">Failed (${xhr.status})</span>`;
        busy = false; next();
      };
      xhr.onerror = () => { bar.parentElement.remove(); meta.innerHTML = '<span class="bad">Connection lost. Is the Mac still on this Wi-Fi?</span>'; busy = false; next(); };
      xhr.send(file);
    }

    let lastShared = '';
    async function refresh() {
      try {
        const r = await fetch(`/api/state?k=${encodeURIComponent(key)}`, {cache:'no-store'});
        const s = await r.json();
        $('mac').textContent = `Connected to ${s.mac}`;
        $('status').textContent = 'Keep this page open while files are sending.';
        const sig = JSON.stringify(s.files);
        if (sig === lastShared) return;
        lastShared = sig;
        $('shared').innerHTML = s.files.length ? s.files.map(f => {
          const url = `/dl/${f.id}?k=${encodeURIComponent(key)}`;
          const thumb = f.kind === 'image' ? `<img class="thumb" loading="lazy" src="${url}&inline=1" alt="">` : `<div class="thumb">${icon(f.kind)}</div>`;
          return `<div class="row">${thumb}<div class="info"><div class="name">${esc(f.name)}</div><div class="meta">${fmt(f.size)}</div></div>
                  <a class="btn ghost" href="${url}&inline=1" target="_blank">View</a><a class="btn" href="${url}" download="${esc(f.name)}">Save</a></div>`;
        }).join('') : '<div class="empty">Files you drop into Tether on your Mac will appear here.</div>';
      } catch (e) {
        $('status').textContent = 'Can’t reach your Mac. Check that both are on the same Wi-Fi and Tether is open.';
      }
    }
    refresh(); setInterval(refresh, 2500);
    </script>
    </body>
    </html>
    """#
}
