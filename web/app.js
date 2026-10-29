/**
 * app.js: CampusKart escrow console - frontend controller.
 * Vanilla JavaScript, zero external libraries, zero CDN dependencies.
 * Every value from the database is rendered with textContent (XSS-safe).
 * Interaction engine (spotlight edges, depth layers, decrypt verdicts,
 * network canvas, small-element tilt) inherited from the AI-TOG observatory.
 */
(function () {
  "use strict";

  // ======================================================================
  // STATE
  // ======================================================================
  const state = {
    theme: safeGet("ck-theme") || "dark",
    me: Number(safeGet("ck-actor")) || 108,
    users: [],
    categories: [],
    meta: null,
    status: null,
    selectedListing: null,
    traces: [],
    shownTraceId: null,
    activeTab: "market",
    stage: 5,
    reportKey: null,
    presetResults: {},
    busy: false,
    isReducedMotion: window.matchMedia("(prefers-reduced-motion: reduce)").matches,
  };

  const MEETUPS = ["SJT Ground Floor", "Library Entrance", "TT Food Court", "Main Gate", "Anna Auditorium",
    "Indoor Stadium", "SMV Block Entrance", "PRP Block Entrance", "GDN Block Entrance"];

  const TONES = {
    ACTIVE: "pass", RESERVED: "review", SOLD: "info", WITHDRAWN: "dim",
    PENDING: "review", ACCEPTED: "pass", REJECTED: "fail",
    CREATED: "info", HANDED_OVER: "review", COMPLETED: "pass", DISPUTED: "fail", REFUNDED: "info", CANCELLED: "dim",
    HOLD: "review", RELEASE: "pass", REFUND: "info",
    OPEN: "fail", RESOLVED_BUYER: "info", RESOLVED_SELLER: "pass",
    OK: "pass", MISMATCH: "fail", YES: "pass", NO: "dim",
    COMMIT: "pass", ROLLBACK: "fail", REPORT: "info", "NO CHANGE": "review",
    STUDENT: "accent", ADMIN: "fail", Y: "fail", N: "dim", VALID: "pass", INVALID: "fail",
  };
  const PILL_COLUMNS = new Set(["status", "order_status", "listing_status", "txn_type", "dispute_status", "check_result",
    "window_over", "role", "is_blocked", "item_condition"]);
  const MONEY_COLUMNS = /(price|amount|fee|payout|balance|wallet|value|spent|revenue|held|released|refunded|escrow|should_hold)/;

  const $ = (id) => document.getElementById(id);

  function safeGet(k) { try { return localStorage.getItem(k); } catch { return null; } }
  function safeSet(k, v) { try { localStorage.setItem(k, v); } catch { /* ignore */ } }

  // ======================================================================
  // DOM + FORMAT HELPERS
  // ======================================================================
  function el(tag, cls, text, attrs) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = String(text);
    if (attrs) for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v);
    return n;
  }
  function clear(node) { node.replaceChildren(); return node; }
  function money(v) {
    if (v === null || v === undefined || v === "") return "—";
    return "₹" + Number(v).toLocaleString("en-IN", { maximumFractionDigits: 2 });
  }
  function pill(text, tone) {
    const p = el("span", "pill", text);
    const t = tone || TONES[text];
    if (t) p.classList.add("tone-" + t);
    return p;
  }
  function trustText(v) { return v === null || v === undefined ? "new" : Number(v).toFixed(1); }
  function trustClass(v) { return v === null || v === undefined ? "none" : v < 70 ? "low" : ""; }
  function me() { return state.users.find((u) => u.user_id === state.me) || null; }
  function userName(id) { const u = state.users.find((x) => x.user_id === id); return u ? u.full_name : String(id); }

  function cellNode(col, v) {
    if (v === null || v === undefined || v === "") return el("span", "tone-dim", "—");
    if (PILL_COLUMNS.has(col) && typeof v === "string") return pill(v);
    if (MONEY_COLUMNS.test(col) && typeof v === "number") return document.createTextNode(money(v));
    return document.createTextNode(String(v));
  }

  // tiny SQL / PL-SQL highlighter (builds spans; never uses innerHTML)
  const KW = new Set(("SELECT FROM WHERE AND OR NOT IN IS NULL JOIN LEFT RIGHT OUTER INNER ON AS ORDER BY GROUP HAVING " +
    "INSERT INTO VALUES UPDATE SET DELETE CREATE OR REPLACE VIEW TABLE PROCEDURE FUNCTION TRIGGER BEGIN END IF THEN ELSE " +
    "ELSIF CASE WHEN RETURN RETURNS IS DECLARE CURSOR OPEN FETCH CLOSE LOOP EXIT FOR EACH ROW BEFORE AFTER EXCEPTION " +
    "RAISE COMMIT ROLLBACK DISTINCT EXISTS UNION ALL INTERSECT MINUS LIKE BETWEEN DESC ASC COUNT SUM AVG MAX MIN ROUND " +
    "NVL COALESCE UPPER RANK OVER WITH OF NEW OTHERS NO_DATA_FOUND RAISE_APPLICATION_ERROR DBMS_OUTPUT PUT_LINE INTO " +
    "NUMBER VARCHAR2 DATE TYPE ROWTYPE CONSTRAINT PRIMARY KEY FOREIGN REFERENCES CHECK UNIQUE DEFAULT SYSDATE TO_CHAR " +
    "SQL ROWCOUNT NOTFOUND ISOPEN LPAD RPAD SUBSTR DUAL").split(" "));
  function highlight(code, target) {
    clear(target);
    const re = /(--[^\n]*)|('(?:[^']|'')*')|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_$#%]*)|(\s+|[^\sA-Za-z0-9_']+)/g;
    let m;
    const frag = document.createDocumentFragment();
    while ((m = re.exec(code)) !== null) {
      if (m[1]) frag.appendChild(el("span", "tok-com", m[1]));
      else if (m[2]) frag.appendChild(el("span", "tok-str", m[2]));
      else if (m[3]) frag.appendChild(el("span", "tok-num", m[3]));
      else if (m[4]) {
        const w = m[4];
        const up = w.toUpperCase().replace(/%.*/, "");
        if (KW.has(up)) frag.appendChild(el("span", "tok-kw", w));
        else if (/^(ACCEPT_OFFER|RESOLVE_DISPUTE|AUTO_RELEASE_ESCROW|MARK_HANDED_OVER|SELLER_STATEMENT|CALC_PLATFORM_FEE|SELLER_TRUST_SCORE|ESCROW_BALANCE|TRG_\w+)$/i.test(w))
          frag.appendChild(el("span", "tok-fn", w));
        else frag.appendChild(document.createTextNode(w));
      } else frag.appendChild(document.createTextNode(m[0]));
    }
    target.appendChild(frag);
  }

  function renderTable(headEl, bodyEl, columns, rows, emptyText) {
    clear(headEl); clear(bodyEl);
    const tr = el("tr");
    columns.forEach((c) => tr.appendChild(el("th", null, c)));
    headEl.appendChild(tr);
    if (!rows.length) {
      const r = el("tr"); const td = el("td", "table-empty", emptyText || "No rows selected.");
      td.colSpan = Math.max(1, columns.length); r.appendChild(td); bodyEl.appendChild(r); return;
    }
    rows.forEach((row) => {
      const r = el("tr");
      columns.forEach((c) => {
        const td = el("td");
        if (typeof row[c] === "number") td.classList.add("num");
        if (typeof row[c] === "string" && row[c].length > 40) td.classList.add("wrap");
        td.appendChild(cellNode(c, row[c]));
        r.appendChild(td);
      });
      bodyEl.appendChild(r);
    });
  }

  // ======================================================================
  // API
  // ======================================================================
  async function api(path, opts) {
    const res = await fetch(path, opts);
    let data = null;
    try { data = await res.json(); } catch { /* ignore */ }
    if (!res.ok) throw new Error((data && data.error) || `HTTP ${res.status}`);
    return data;
  }
  const post = (path, body) => api(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });

  // ======================================================================
  // NOTIFICATIONS
  // ======================================================================
  let notifTimer = null;
  function notify(msg, type = "info", traceId = null) {
    $("notificationMessage").textContent = msg;
    const box = $("systemNotification");
    box.className = `system-notification ${type}`;
    const tb = $("notifTraceBtn");
    tb.classList.toggle("hidden", !traceId || state.activeTab === "trace");
    tb.onclick = () => { switchTab("trace"); showTrace(traceId); box.classList.add("hidden"); };
    clearTimeout(notifTimer);
    notifTimer = setTimeout(() => box.classList.add("hidden"), type === "error" ? 9000 : 6000);
  }

  // ======================================================================
  // VISUAL ENGINE (from AI-TOG, recoloured)
  // ======================================================================
  function initTheme() {
    document.documentElement.setAttribute("data-theme", state.theme);
    $("themeToggle").addEventListener("click", () => {
      state.theme = state.theme === "dark" ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", state.theme);
      safeSet("ck-theme", state.theme);
    });
  }

  function initCanvas() {
    const canvas = $("ambientCanvas");
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    let w, h, nodes = [], raf = null, running = false, scan = 0;
    const mouse = { x: 0, y: 0, tx: 0, ty: 0 };
    function resize() { w = canvas.width = innerWidth; h = canvas.height = innerHeight; }
    function create() {
      nodes = [];
      const n = Math.min(44, Math.max(18, Math.floor(w / 36)));
      for (let i = 0; i < n; i++) {
        nodes.push({ x: Math.random() * w, y: Math.random() * h, vx: (Math.random() - 0.5) * 0.26, vy: (Math.random() - 0.5) * 0.26,
          r: Math.random() * 1.6 + 1, magenta: i % 3 === 0, a: Math.random() * 0.4 + 0.2, square: i % 5 === 0 });
      }
    }
    function frame() {
      if (document.hidden || state.isReducedMotion) { running = false; return; }
      ctx.clearRect(0, 0, w, h);
      mouse.x += (mouse.tx - mouse.x) * 0.05; mouse.y += (mouse.ty - mouse.y) * 0.05;
      const dark = state.theme === "dark";
      const A = dark ? "255, 178, 63" : "194, 86, 12";
      const B = dark ? "255, 62, 154" : "192, 19, 107";
      scan = (scan + 0.45) % h;
      ctx.fillStyle = `rgba(${A}, ${dark ? 0.03 : 0.025})`; ctx.fillRect(0, scan, w, 2);
      for (const n of nodes) {
        n.x += n.vx; n.y += n.vy;
        if (n.x < -10) n.x = w + 10; if (n.x > w + 10) n.x = -10;
        if (n.y < -10) n.y = h + 10; if (n.y > h + 10) n.y = -10;
        n.rx = n.x + mouse.x * n.r * 1.2; n.ry = n.y + mouse.y * n.r * 1.2;
      }
      ctx.lineWidth = 0.75;
      for (let i = 0; i < nodes.length; i++) for (let j = i + 1; j < nodes.length; j++) {
        const dx = nodes[i].rx - nodes[j].rx, dy = nodes[i].ry - nodes[j].ry, d2 = dx * dx + dy * dy;
        if (d2 < 9025) {
          const al = (1 - Math.sqrt(d2) / 95) * 0.17;
          ctx.strokeStyle = `rgba(${nodes[i].magenta ? B : A}, ${al})`;
          ctx.beginPath(); ctx.moveTo(nodes[i].rx, nodes[i].ry); ctx.lineTo(nodes[j].rx, nodes[j].ry); ctx.stroke();
        }
      }
      for (const n of nodes) {
        ctx.fillStyle = `rgba(${n.magenta ? B : A}, ${n.a * (dark ? 0.8 : 0.5)})`;
        if (n.square) { ctx.save(); ctx.translate(n.rx, n.ry); ctx.rotate(Math.PI / 4); ctx.fillRect(-n.r, -n.r, n.r * 2, n.r * 2); ctx.restore(); }
        else { ctx.beginPath(); ctx.arc(n.rx, n.ry, n.r, 0, Math.PI * 2); ctx.fill(); }
      }
      raf = requestAnimationFrame(frame);
    }
    function start() { if (!running && !document.hidden && !state.isReducedMotion) { running = true; raf = requestAnimationFrame(frame); } }
    document.addEventListener("visibilitychange", () => { if (document.hidden) { cancelAnimationFrame(raf); running = false; } else start(); });
    addEventListener("resize", () => { resize(); create(); });
    addEventListener("mousemove", (e) => { mouse.tx = (e.clientX / w - 0.5) * 18; mouse.ty = (e.clientY / h - 0.5) * 18; });
    resize(); create(); start();
  }

  function initSpotlight() {
    if (state.isReducedMotion) return;
    const target = { x: -1000, y: -1000 }, cur = { x: -1000, y: -1000 };
    addEventListener("pointermove", (e) => { target.x = e.clientX; target.y = e.clientY; }, { passive: true });
    function tick() {
      if (!document.hidden) {
        cur.x += (target.x - cur.x) * 0.08; cur.y += (target.y - cur.y) * 0.08;
        const vh = innerHeight;
        document.querySelectorAll(".view-panel.active .card, .verdict-card").forEach((card) => {
          const r = card.getBoundingClientRect();
          if (r.bottom < -50 || r.top > vh + 50) return;
          const lx = cur.x - r.left, ly = cur.y - r.top;
          card.style.setProperty("--mx", `${lx.toFixed(1)}px`);
          card.style.setProperty("--my", `${ly.toFixed(1)}px`);
          const hov = lx >= 0 && lx <= r.width && ly >= 0 && ly <= r.height;
          const tx = hov ? (lx - r.width / 2) / (r.width / 2) : 0, ty = hov ? (ly - r.height / 2) / (r.height / 2) : 0;
          card._nx = (card._nx || 0) + (tx - (card._nx || 0)) * 0.08;
          card._ny = (card._ny || 0) + (ty - (card._ny || 0)) * 0.08;
          const layers = card.querySelectorAll(":scope > [data-depth]");
          if (Math.abs(card._nx) > 0.002 || Math.abs(card._ny) > 0.002) {
            layers.forEach((L) => {
              const d = Number(L.getAttribute("data-depth")) || 1, mx = d === 1 ? 1.5 : d === 2 ? 3 : 5;
              L.style.transform = `translate3d(${(card._nx * mx).toFixed(2)}px, ${(card._ny * mx).toFixed(2)}px, 0)`;
            });
            card._moved = true;
          } else if (card._moved) { layers.forEach((L) => { L.style.transform = ""; }); card._moved = false; }
        });
      }
      requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  }

  function initTilt() {
    if (state.isReducedMotion) return;
    document.addEventListener("pointermove", (e) => {
      const t = e.target.closest && e.target.closest(".verdict-badge, .stat-number, .kpi-chip");
      if (!t) return;
      const r = t.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width - 0.5, y = (e.clientY - r.top) / r.height - 0.5;
      t.style.transition = "transform 0.05s ease-out";
      t.style.transform = `perspective(500px) rotateX(${(-y * 16).toFixed(2)}deg) rotateY(${(x * 16).toFixed(2)}deg)`;
      if (!t._leave) {
        t._leave = true;
        t.addEventListener("pointerleave", () => {
          t.style.transition = "transform 0.6s cubic-bezier(0.175, 0.885, 0.32, 1.275)";
          t.style.transform = "perspective(500px) rotateX(0) rotateY(0)";
        });
      }
    });
  }

  function scramble(text, node, duration, done) {
    if (state.isReducedMotion) { node.textContent = text; if (done) done(); return; }
    const chars = "0123456789ABCDEF#@%&*<>[]:/~₹";
    const t0 = performance.now();
    (function step(now) {
      const p = Math.min(1, (now - t0) / duration), k = Math.floor(p * text.length);
      let s = "";
      for (let i = 0; i < text.length; i++) s += i < k || text[i] === " " ? text[i] : chars[Math.floor(Math.random() * chars.length)];
      node.textContent = s;
      if (p < 1) requestAnimationFrame(step); else { node.textContent = text; if (done) done(); }
    })(t0);
  }

  function countUp(node, value, fmt) {
    const target = Number(value);
    if (!isFinite(target) || state.isReducedMotion) { node.textContent = fmt(value); return; }
    const start = node._val !== undefined ? node._val : target;
    node._val = target;
    if (start === target) { node.textContent = fmt(target); return; }
    const t0 = performance.now();
    (function step(now) {
      const p = Math.min(1, (now - t0) / 420), e = 1 - Math.pow(1 - p, 3);
      node.textContent = fmt(start + (target - start) * e);
      if (p < 1) requestAnimationFrame(step); else node.textContent = fmt(target);
    })(t0);
  }

  // ======================================================================
  // NAVIGATION
  // ======================================================================
  function switchTab(tab) {
    state.activeTab = tab;
    document.querySelectorAll(".tab-btn").forEach((b) => {
      const on = b.dataset.tab === tab;
      b.classList.toggle("active", on); b.setAttribute("aria-selected", on ? "true" : "false");
    });
    document.querySelectorAll(".view-panel").forEach((p) => p.classList.toggle("active", p.id === `view-${tab}`));
    loadTab(tab);
  }
  function loadTab(tab) {
    if (tab === "market") return loadListings();
    if (tab === "orders") return Promise.all([loadOrders(), loadAdmin()]).then(() => renderStage(state.stage));
    if (tab === "ledger") return loadLedger();
    if (tab === "trace") return renderHistory();
    if (tab === "reports") { if (!state.reportKey) openReport("Q6"); }
    return Promise.resolve();
  }

  // ======================================================================
  // SESSION STRIP
  // ======================================================================
  async function loadUsers() {
    state.users = await api("/api/users");
    const sel = $("actorSelect");
    const keep = state.me;
    clear(sel);
    const gS = el("optgroup"); gS.label = "Students";
    const gA = el("optgroup"); gA.label = "Administrators";
    state.users.forEach((u) => {
      const o = el("option", null, `${u.user_id} · ${u.full_name}${u.is_blocked === "Y" ? "  [BLOCKED]" : ""}`);
      o.value = u.user_id;
      (u.role === "ADMIN" ? gA : gS).appendChild(o);
    });
    sel.append(gS, gA);
    if (!state.users.some((u) => u.user_id === keep)) state.me = state.users[0].user_id;
    sel.value = String(state.me);
    renderActor();
    // dependent selects
    const blk = $("blockUser"), stm = $("statementSeller");
    const bv = blk.value, sv = stm.value;
    clear(blk); clear(stm);
    state.users.filter((u) => u.role === "STUDENT").forEach((u) => {
      const o = el("option", null, `${u.user_id} · ${u.full_name}${u.is_blocked === "Y" ? " (blocked)" : ""}`); o.value = u.user_id; blk.appendChild(o);
      const o2 = el("option", null, `${u.user_id} · ${u.full_name}`); o2.value = u.user_id; stm.appendChild(o2);
    });
    blk.value = bv || "115"; stm.value = sv || "110";
  }
  function renderActor() {
    const u = me();
    if (!u) return;
    const role = $("actorRole");
    role.textContent = u.role; role.className = "pill tone-" + (u.role === "ADMIN" ? "fail" : "accent");
    countUp($("actorWallet"), u.wallet_balance, money);
    $("actorTrust").textContent = trustText(u.trust_score);
    $("actorBlocked").classList.toggle("hidden", u.is_blocked !== "Y");
  }
  async function loadOverview() {
    const o = await api("/api/overview");
    countUp($("kpiListings"), o.active_listings, (v) => Math.round(v));
    countUp($("kpiOffers"), o.pending_offers, (v) => Math.round(v));
    countUp($("kpiOrders"), o.open_orders, (v) => Math.round(v));
    countUp($("kpiEscrow"), o.in_escrow, money);
    countUp($("kpiDisputes"), o.open_disputes, (v) => Math.round(v));
    countUp($("kpiRevenue"), o.platform_revenue, money);
    const b = $("disputeBadge"); b.textContent = o.open_disputes; b.classList.toggle("hidden", !o.open_disputes);
    state.overview = o;
    const counts = { 1: `${o.active_listings} active`, 2: `${o.pending_offers} pending`, 3: `${o.created_orders} held`,
      4: `${o.handed_over_orders} waiting`, 5: `${o.open_disputes} disputed` };
    for (let i = 1; i <= 5; i++) $("slabCount" + i).textContent = counts[i];
  }
  async function loadStatus() {
    const s = await api("/api/status");
    state.status = s;
    const chip = $("dbChip");
    chip.classList.remove("oracle", "mirror"); chip.classList.add(s.mode);
    $("dbLabel").textContent = `DB: ${s.label} (${s.detail})`;
    chip.title = s.driver;
    if (s.note) notify(s.note, "info");
    if (!s.schema_ready) notify("CampusKart tables were not found in this schema. Click 'Reset database' on the Trace tab to build them.", "error");
  }

  async function refreshAfterChange() {
    await Promise.all([loadUsers(), loadOverview()]);
    if (state.activeTab === "market") { await loadListings(); if (state.selectedListing) await selectListing(state.selectedListing, true); }
    else if (state.activeTab === "orders") { await loadOrders(); await loadAdmin(); }
    else if (state.activeTab === "ledger") await loadLedger();
  }

  // ======================================================================
  // TRANSACTIONS
  // ======================================================================
  async function runTx(kind, params, opts = {}) {
    const body = Object.assign({ actor: state.me }, params);
    let trace;
    try {
      trace = await post(`/api/tx/${kind}`, body);
    } catch (err) {
      notify(`Application check: ${err.message}`, "error");
      return null;
    }
    state.traces.unshift(trace);
    if (!opts.silent) {
      const ok = trace.status === "COMMIT" || trace.status === "REPORT";
      const msg = ok ? `${trace.code} ${trace.status}: ${trace.result}` :
        `${trace.code} ${trace.status}: ${trace.error ? trace.error.text : trace.result}`;
      notify(msg, ok ? "success" : "error", trace.id);
    }
    if (state.activeTab === "trace" || opts.showTrace) showTrace(trace.id);
    renderHistory();
    await refreshAfterChange();
    return trace;
  }

  // ======================================================================
  // 01 MARKET
  // ======================================================================
  let listingTimer = null;
  function scheduleListings() { clearTimeout(listingTimer); listingTimer = setTimeout(loadListings, 220); }

  async function loadListings() {
    const qs = new URLSearchParams();
    if ($("fSearch").value.trim()) qs.set("q", $("fSearch").value.trim());
    if ($("fCategory").value) qs.set("category", $("fCategory").value);
    if ($("fCondition").value) qs.set("condition", $("fCondition").value);
    if ($("fMax").value) qs.set("max_price", $("fMax").value);
    qs.set("status", $("fStatus").value);
    const data = await api(`/api/listings?${qs}`);
    highlight(data.sql, $("catalogSql"));
    $("listingCount").textContent = `${data.rows.length} ROWS`;
    const grid = clear($("listingGrid"));
    if (!data.rows.length) { grid.appendChild(el("p", "empty-note", "No listing matches these filters.")); return; }
    data.rows.forEach((l) => {
      const t = el("button", "listing-tile");
      t.type = "button";
      if (l.seller_id === state.me) t.classList.add("mine");
      if (l.listing_id === state.selectedListing) t.classList.add("selected");
      const top = el("div", "tile-top");
      top.append(el("span", "tile-cat", `#${l.listing_id} · ${l.category_name}`), pill(l.status));
      const meta = el("div", "tile-meta");
      meta.append(el("span", "price", Number(l.asking_price).toLocaleString("en-IN")), el("span", "pill", l.item_condition));
      const seller = el("div", "tile-seller");
      seller.append(el("span", null, `${l.seller}${l.hostel_block ? " · " + l.hostel_block : ""}`),
        el("span", "trust-chip " + trustClass(l.seller_trust), `★ ${trustText(l.seller_trust)}`));
      t.append(top, el("div", "tile-title", l.title), meta, seller);
      if (l.pending_offers) t.appendChild(el("span", "hint", `${l.pending_offers} pending offer(s)`));
      t.addEventListener("click", () => selectListing(l.listing_id));
      grid.appendChild(t);
    });
  }

  async function selectListing(id, quiet) {
    state.selectedListing = id;
    document.querySelectorAll(".listing-tile").forEach((t) => t.classList.toggle("selected", t.textContent.startsWith(`#${id} `)));
    let data;
    try { data = await api(`/api/listings/${id}`); } catch (e) { if (!quiet) notify(e.message, "error"); return; }
    renderDetail(data);
  }

  function renderDetail({ listing: l, offers }) {
    $("detailTag").textContent = `LISTING #${l.listing_id} // ${l.category_name.toUpperCase()}`;
    $("detailTitle").textContent = l.title;
    const body = clear($("detailBody"));
    const row = el("div", "detail-price-row");
    row.append(el("span", "price", Number(l.asking_price).toLocaleString("en-IN")), pill(l.status), el("span", "pill", l.item_condition));
    body.appendChild(row);
    if (l.description) body.appendChild(el("p", "listing-desc", l.description));
    const kv = el("div", "kv-grid");
    [["Seller", `${l.seller} (${l.seller_id})`], ["Hostel", l.hostel_block || "—"], ["Trust score", trustText(l.seller_trust)],
      ["Fee %", `${l.fee_percent}%`], ["Fee at asking", money(l.fee_at_asking)], ["Listed on", l.listed_on]].forEach(([k, v]) => {
      const d = el("div", "kv"); d.append(el("span", "kv-l", k), el("span", "kv-v", v)); kv.appendChild(d);
    });
    body.appendChild(kv);
    body.appendChild(el("p", "hint", "Fee at asking = CALC_PLATFORM_FEE(listing_id, asking_price), computed by the database."));

    const isSeller = l.seller_id === state.me;
    const active = l.status === "ACTIVE";

    // offers
    const sub = el("div", "sub-head"); sub.append(el("span", null, `Offers (${offers.length})`), el("span", "hint", "OFFERS ⋈ USERS"));
    body.appendChild(sub);
    let meetupSel = null;
    if (isSeller && active) {
      const box = el("div", "inline-form");
      box.appendChild(el("span", "field-label", "Meet-up spot"));
      meetupSel = el("select", "form-select");
      MEETUPS.forEach((m) => { const o = el("option", null, m); o.value = m; meetupSel.appendChild(o); });
      box.appendChild(meetupSel);
      body.appendChild(box);
    }
    const scroller = el("div", "table-scroller");
    const table = el("table", "data-table");
    const thead = el("thead"), tbody = el("tbody");
    const htr = el("tr");
    ["Offer", "Buyer", "Wallet", "Offered", "Status", ""].forEach((h) => htr.appendChild(el("th", null, h)));
    thead.appendChild(htr);
    if (!offers.length) {
      const r = el("tr"); const td = el("td", "table-empty", "No offers yet."); td.colSpan = 6; r.appendChild(td); tbody.appendChild(r);
    }
    offers.forEach((f) => {
      const r = el("tr");
      r.append(el("td", null, f.offer_id), el("td", null, `${f.buyer} (${f.buyer_id})`), el("td", "num", money(f.buyer_wallet)),
        el("td", "num", money(f.offered_price)));
      const st = el("td"); st.appendChild(pill(f.status)); r.appendChild(st);
      const act = el("td");
      if (isSeller && active && f.status === "PENDING") {
        const b = el("button", "btn btn-good btn-xs", "Accept");
        b.addEventListener("click", () => runTx("accept_offer", { offer_id: f.offer_id, meetup_location: meetupSel.value }));
        act.appendChild(b);
      } else if (f.buyer_id === state.me && f.status === "PENDING") {
        const b = el("button", "btn btn-danger btn-xs", "Withdraw");
        b.addEventListener("click", () => runTx("withdraw_offer", { offer_id: f.offer_id }));
        act.appendChild(b);
      }
      r.appendChild(act);
      tbody.appendChild(r);
    });
    table.append(thead, tbody); scroller.appendChild(table); body.appendChild(scroller);
    if (isSeller && active && offers.some((f) => f.status === "PENDING"))
      body.appendChild(el("p", "hint", "Accept calls ACCEPT_OFFER: order + escrow HOLD + wallet debit + competing offers rejected, in one COMMIT."));

    // actions
    if (isSeller && active) {
      const box = el("div", "action-box");
      box.appendChild(el("span", "action-title", "Seller actions (T1b / T1c)"));
      const f = el("div", "inline-form");
      const inp = el("input", "form-input mono"); inp.type = "number"; inp.value = l.asking_price;
      const b1 = el("button", "btn btn-secondary btn-sm", "Update price");
      b1.addEventListener("click", () => runTx("update_price", { listing_id: l.listing_id, asking_price: inp.value }));
      const b2 = el("button", "btn btn-danger btn-sm", "Withdraw listing");
      b2.addEventListener("click", () => runTx("withdraw_listing", { listing_id: l.listing_id }));
      f.append(inp, b1, b2); box.appendChild(f); body.appendChild(box);
    } else if (!isSeller && active) {
      const box = el("div", "action-box");
      box.appendChild(el("span", "action-title", `Make an offer as ${me() ? me().full_name : "—"} (T2)`));
      const f = el("div", "inline-form");
      const inp = el("input", "form-input mono"); inp.type = "number"; inp.value = Math.round(l.asking_price * 0.9);
      const b = el("button", "btn btn-primary btn-sm", "Send offer");
      b.addEventListener("click", () => runTx("make_offer", { listing_id: l.listing_id, offered_price: inp.value }));
      f.append(inp, b); box.appendChild(f);
      box.appendChild(el("span", "hint", "TRG_VALIDATE_OFFER checks: not your own listing, listing ACTIVE, you are not blocked."));
      body.appendChild(box);
    } else if (!active) {
      const box = el("div", "action-box");
      box.appendChild(el("span", "action-title", `Listing is ${l.status}`));
      const b = el("button", "btn btn-ghost btn-sm", "Try to offer anyway (expect ORA-20002)");
      b.addEventListener("click", () => runTx("make_offer", { listing_id: l.listing_id, offered_price: l.asking_price }));
      if (!isSeller) box.appendChild(b);
      body.appendChild(box);
    }
  }

  async function createListing() {
    const t = await runTx("create_listing", {
      title: $("nlTitle").value, category_id: $("nlCategory").value, item_condition: $("nlCondition").value,
      asking_price: $("nlPrice").value, description: $("nlDesc").value,
    });
    if (t && t.status === "COMMIT") { $("nlTitle").value = ""; $("nlPrice").value = ""; $("nlDesc").value = ""; }
  }

  // ======================================================================
  // 02 ORDERS
  // ======================================================================
  function lifecycle(o) {
    const wrap = el("div", "lifecycle");
    const steps = o.dispute_id ? ["CREATED", "HANDED_OVER", "DISPUTED", o.order_status === "DISPUTED" ? "DECISION" : o.order_status]
      : ["CREATED", "HANDED_OVER", "COMPLETED"];
    const order = { CREATED: 0, HANDED_OVER: 1, DISPUTED: 2, COMPLETED: o.dispute_id ? 3 : 2, REFUNDED: 3 };
    const cur = order[o.order_status] ?? 0;
    steps.forEach((s, i) => {
      const st = el("div", "lc-step");
      if (i < cur) st.classList.add("done");
      if (i === cur) {
        st.classList.add(o.order_status === "COMPLETED" ? "good" : o.order_status === "DISPUTED" ? "bad" : "current");
        if (o.order_status === "REFUNDED") { st.classList.remove("current"); st.classList.add("done"); }
      }
      if (s === "HANDED_OVER" && !o.handed_over_at && o.dispute_id) st.classList.remove("done");
      st.append(el("span", "lc-dot"), el("span", "lc-name", s.replace("_", " ")));
      wrap.appendChild(st);
    });
    return wrap;
  }

  async function loadOrders() {
    const u = me();
    const rows = await api(u && u.role === "ADMIN" ? "/api/orders" : `/api/orders?user=${state.me}`);
    $("orderCount").textContent = u && u.role === "ADMIN" ? `${rows.length} (ALL)` : `${rows.length}`;
    const list = clear($("orderList"));
    if (!rows.length) { list.appendChild(el("p", "empty-note", "No orders for this user yet. Accept an offer in the Market to create one.")); return; }
    rows.forEach((o) => {
      const role = o.seller_id === state.me ? "seller" : o.buyer_id === state.me ? "buyer" : null;
      const card = el("div", "order-card" + (role ? " role-" + role : ""));
      const top = el("div", "order-top");
      const left = el("div");
      left.append(el("div", "order-title", `#${o.order_id} · ${o.title}`),
        el("div", "order-sub", `Buyer ${o.buyer_name} → Seller ${o.seller_name} · ${o.category_name}`));
      const right = el("div", "chip-row");
      if (role) right.appendChild(el("span", "role-tag " + role, role.toUpperCase()));
      right.appendChild(pill(o.order_status));
      top.append(left, right);
      card.appendChild(top);
      card.appendChild(lifecycle(o));
      const m = el("div", "order-money");
      [["Price", money(o.final_price)], ["Fee", money(o.platform_fee)], ["Seller gets", money(o.seller_payout)],
        ["Created", o.created_at], ["Handed over", o.handed_over_at || "—"]].forEach(([k, v]) => {
        const s = el("span", null, k + " "); s.appendChild(el("b", null, v)); m.appendChild(s);
      });
      card.appendChild(m);
      if (o.dispute_id) card.appendChild(el("div", "dispute-note", `Dispute #${o.dispute_id} (${o.dispute_status}): ${o.dispute_reason}`));
      if (o.rating) card.appendChild(el("div", "hint", `Rated ${"★".repeat(o.rating)}${"☆".repeat(5 - o.rating)} ${o.review_comment ? "— " + o.review_comment : ""}`));

      const acts = el("div", "order-actions");
      if (role === "seller" && o.order_status === "CREATED") {
        const b = el("button", "btn btn-primary btn-sm", "Mark handed over (T4)");
        b.addEventListener("click", () => runTx("mark_handed_over", { order_id: o.order_id }));
        acts.appendChild(b);
      }
      if (role && (o.order_status === "CREATED" || o.order_status === "HANDED_OVER")) {
        const f = el("div", "inline-form");
        const inp = el("input", "form-input"); inp.placeholder = "Reason for dispute"; inp.maxLength = 300;
        const b = el("button", "btn btn-danger btn-sm", "Raise dispute (T5)");
        b.addEventListener("click", () => runTx("raise_dispute", { order_id: o.order_id, reason: inp.value }));
        f.append(inp, b); acts.appendChild(f);
      }
      if (role === "buyer" && o.order_status === "COMPLETED" && !o.rating) {
        const f = el("div", "inline-form");
        const stars = el("div", "star-input"); let rating = 5;
        const paint = () => stars.querySelectorAll(".star-btn").forEach((s, i) => s.classList.toggle("on", i < rating));
        for (let i = 1; i <= 5; i++) {
          const s = el("button", "star-btn", "★", { type: "button", "aria-label": `${i} stars` });
          s.addEventListener("click", () => { rating = i; paint(); });
          stars.appendChild(s);
        }
        paint();
        const inp = el("input", "form-input"); inp.placeholder = "Comment (optional)";
        const b = el("button", "btn btn-good btn-sm", "Rate seller (T8)");
        b.addEventListener("click", () => runTx("submit_review", { order_id: o.order_id, rating, comment: inp.value }));
        f.append(stars, inp, b); acts.appendChild(f);
      }
      if (acts.childNodes.length) card.appendChild(acts);
      list.appendChild(card);
    });
  }

  async function loadAdmin() {
    const data = await api("/api/admin");
    const desk = clear($("disputeDesk"));
    if (!data.disputes.length) desk.appendChild(el("p", "empty-note", "No open disputes."));
    data.disputes.forEach((d) => {
      const item = el("div", "desk-item");
      const r1 = el("div", "desk-row");
      r1.append(el("b", null, `Dispute #${d.dispute_id} · Order #${d.order_id} · ${d.title}`), el("span", "monospace", d.raised_on));
      item.append(r1, el("div", "reason", `“${d.reason}” — raised by ${d.raised_by}`));
      const r2 = el("div", "desk-row");
      r2.appendChild(el("span", null, `Buyer ${d.buyer} · Seller ${d.seller} · Price ${money(d.price)} · Fee ${money(d.platform_fee)}`));
      const btns = el("div", "inline-form");
      const b1 = el("button", "btn btn-info btn-xs", "Refund buyer");
      b1.addEventListener("click", () => runTx("resolve_dispute", { dispute_id: d.dispute_id, decision: "BUYER" }));
      const b2 = el("button", "btn btn-good btn-xs", "Pay seller");
      b2.addEventListener("click", () => runTx("resolve_dispute", { dispute_id: d.dispute_id, decision: "SELLER" }));
      btns.append(b1, b2); r2.appendChild(btns);
      item.appendChild(r2);
      desk.appendChild(item);
    });
    const q = clear($("releaseQueue"));
    const scroller = el("div", "table-scroller auto");
    const table = el("table", "data-table"); const th = el("thead"), tb = el("tbody");
    renderTable(th, tb, ["order_id", "title", "seller", "handed_over_at", "window_over", "payout"], data.handed_over, "No order is waiting for release.");
    table.append(th, tb); scroller.appendChild(table); q.appendChild(scroller);
    q.appendChild(el("p", "hint", "window_over = handed_over_at <= SYSDATE - 3. Only those rows are fetched by cursor C_DUE_ORDERS; disputed orders are excluded by NOT EXISTS."));
  }

  const STAGE_KINDS = { 1: ["create_listing", "update_price", "withdraw_listing"], 2: ["make_offer", "withdraw_offer"],
    3: ["accept_offer"], 4: ["mark_handed_over"], 5: ["raise_dispute", "resolve_dispute", "auto_release", "submit_review", "seller_statement"] };
  const STAGE_NAMES = { 1: "Listing", 2: "Offer", 3: "Escrow Hold", 4: "Handover", 5: "Settlement" };

  function renderStage(n) {
    state.stage = n;
    document.querySelectorAll(".iso-slab").forEach((s) => s.classList.toggle("active", Number(s.dataset.stage) === n));
    $("stageTitle").textContent = `Stage ${String(n).padStart(2, "0")}: ${STAGE_NAMES[n]}`;
    const box = clear($("stageInspector"));
    if (!state.meta) return;
    STAGE_KINDS[n].forEach((k) => {
      const m = state.meta.transactions[k];
      const item = el("div", "action-box");
      const head = el("div", "sub-head");
      head.append(el("span", "color-accent", `${m.code} · ${m.title}`));
      item.append(head, el("p", "op-text", m.operation));
      const comps = el("div", "comp-list");
      m.components.forEach(([type, name, role]) => comps.appendChild(componentRow(type, name, role)));
      item.appendChild(comps);
      box.appendChild(item);
    });
  }

  // ======================================================================
  // 03 TRACE
  // ======================================================================
  function objectFor(name) {
    if (!state.meta) return null;
    const token = String(name).toUpperCase().match(/[A-Z_]+/g) || [];
    return state.meta.objects.find((o) => token.includes(o.name)) || null;
  }
  function componentRow(type, name, role) {
    const row = el("div", "comp-row");
    row.appendChild(el("span", "type-badge type-" + type, type));
    const mid = el("div");
    mid.append(el("div", "comp-name", name));
    if (role) mid.appendChild(el("div", "comp-role", role));
    row.appendChild(mid);
    let obj = objectFor(name);
    if (!obj && type === "CURSOR") obj = { name: /C_ORDERS/.test(name) ? "SELLER_STATEMENT" : "AUTO_RELEASE_ESCROW" };
    if (obj) {
      const b = el("button", "btn btn-ghost btn-xs", "Source");
      b.addEventListener("click", () => openSource(obj.name));
      row.appendChild(b);
    } else row.appendChild(el("span"));
    return row;
  }

  function renderPresets() {
    const box = clear($("presetList"));
    const groups = {};
    state.meta.presets.forEach((p) => { (groups[p.group] = groups[p.group] || []).push(p); });
    Object.entries(groups).forEach(([g, list]) => {
      const grp = el("div", "preset-group");
      grp.appendChild(el("span", "preset-group-title", g));
      const chips = el("div", "preset-chips");
      list.forEach((p) => {
        const c = el("button", `preset-chip chip-${p.expect}`, null, { type: "button", "data-preset": p.id });
        c.append(el("span", "chip-dot"), el("span", "preset-code", state.meta.transactions[p.kind].code),
          el("span", "preset-label", p.label), el("span", "preset-result", ""));
        c.addEventListener("click", () => runPreset(p));
        chips.appendChild(c);
      });
      grp.appendChild(chips);
      box.appendChild(grp);
    });
    paintPresetResults();
  }
  function paintPresetResults() {
    document.querySelectorAll(".preset-chip").forEach((c) => {
      const r = state.presetResults[c.dataset.preset];
      const tag = c.querySelector(".preset-result");
      c.classList.toggle("done", !!r);
      if (!r) { tag.textContent = ""; return; }
      tag.textContent = r.ok ? `✓ ${r.status}` : `✕ ${r.status}`;
      tag.className = "preset-result " + (r.ok ? "color-pass" : "color-fail");
    });
  }
  async function runPreset(p, opts = {}) {
    const chip = document.querySelector(`.preset-chip[data-preset="${p.id}"]`);
    if (chip) chip.classList.add("running");
    if (p.params.actor && p.params.actor !== state.me) {
      state.me = p.params.actor; safeSet("ck-actor", state.me); $("actorSelect").value = String(state.me); renderActor();
    }
    const t = await runTx(p.kind, p.params, { showTrace: true, silent: opts.silent });
    if (chip) chip.classList.remove("running");
    if (t) state.presetResults[p.id] = { status: t.status, ok: t.status === p.expect };
    paintPresetResults();
    return t;
  }
  async function autopilot() {
    if (state.busy) return;
    state.busy = true;
    const btn = $("autopilotBtn"); btn.disabled = true;
    try {
      await doReset(true);
      state.presetResults = {}; paintPresetResults();
      let ok = 0;
      for (const p of state.meta.presets) {
        const t = await runPreset(p, { silent: true });
        if (t && t.status === p.expect) ok++;
        await new Promise((r) => setTimeout(r, state.isReducedMotion ? 50 : 750));
      }
      notify(`Viva script finished: ${ok}/${state.meta.presets.length} transactions behaved exactly as expected.`, ok === state.meta.presets.length ? "success" : "error");
    } finally { state.busy = false; btn.disabled = false; }
  }

  function renderHistory() {
    const list = clear($("historyList"));
    $("historyCount").textContent = state.traces.length;
    if (!state.traces.length) { list.appendChild(el("p", "empty-note", "No transaction in this session yet.")); return; }
    state.traces.forEach((t) => {
      const b = el("button", "history-item" + (t.id === state.shownTraceId ? " active" : ""), null, { type: "button" });
      b.append(el("span", "history-id", `#${t.id}`), el("span", "history-code", t.code), el("span", "history-title", t.title), pill(t.status));
      b.addEventListener("click", () => showTrace(t.id));
      list.appendChild(b);
    });
  }

  function showTrace(id) {
    const t = state.traces.find((x) => x.id === id);
    if (!t) return;
    state.shownTraceId = id;
    renderHistory();
    const card = $("verdictCard");
    $("verdictStandby").classList.add("hidden");
    $("verdictBody").classList.remove("hidden");
    const vcls = "v-" + t.status.replace(" ", "");
    card.className = "verdict-card";
    const sweep = $("scanlineSweep");
    if (!state.isReducedMotion) { sweep.classList.remove("sweeping"); void sweep.offsetWidth; sweep.classList.add("sweeping"); }
    scramble(t.status, $("verdictBadge"), 600, () => {
      card.classList.add(vcls, "glow-" + t.status.replace(" ", ""));
      if (t.status === "ROLLBACK" && !state.isReducedMotion) {
        $("verdictBadge").classList.add("glitch-active");
        setTimeout(() => $("verdictBadge").classList.remove("glitch-active"), 150);
      }
    });
    $("verdictId").textContent = `TX #${t.id} · ${t.code}`;
    $("verdictActor").textContent = `${t.actor.full_name} (${t.actor.user_id}, ${t.actor.role})`;
    $("verdictTime").textContent = `${t.elapsed_ms} ms · ${t.mode.toUpperCase()}`;
    $("verdictTitle").textContent = t.title;
    const rail = clear($("stageRail"));
    const names = state.meta ? state.meta.stages : {};
    Object.keys(names).forEach((k) => rail.appendChild(el("span", "stage-cell" + (Number(k) === t.stage ? " on" : ""), names[k])));
    const eb = $("verdictError");
    eb.classList.toggle("hidden", !t.error);
    eb.textContent = t.error ? t.error.text : "";
    $("verdictResult").textContent = t.result;

    // anatomy
    $("anatomyCard").classList.remove("hidden");
    $("qOperation").textContent = t.operation;
    const tables = clear($("qTables"));
    t.tables.forEach(([name, how]) => { const c = el("span", "table-chip"); c.append(el("b", null, name), document.createTextNode(how)); tables.appendChild(c); });
    const comps = clear($("qComponents"));
    t.components.forEach(([type, name, role]) => comps.appendChild(componentRow(type, name, role)));
    highlight(t.executed_sql, $("qSql"));

    const sum = clear($("qEffectSummary"));
    if (!t.diffs.length) sum.appendChild(pill("READ-ONLY: NO TABLE CHANGED", "info"));
    t.summary.forEach((s) => sum.appendChild(pill(`${s.table}: ${s.text}`, s.text === "no change" ? null : "accent")));
    const diffs = clear($("qDiffs"));
    t.diffs.forEach((d) => diffs.appendChild(diffBlock(d)));

    const out = clear($("qOutput"));
    const line = (text, cls) => { out.appendChild(el("span", cls || null, text)); out.appendChild(document.createTextNode("\n")); };
    line("SQL> SET SERVEROUTPUT ON", "t-dim");
    t.executed_sql.split("\n").forEach((l, i) => line((i === 0 ? "SQL> " : "  2  ").replace("  2  ", "     ") + l, "t-prompt"));
    if (t.dbms_output.length) t.dbms_output.forEach((l) => line(l));
    if (t.rowcounts && t.rowcounts.length) t.rowcounts.forEach((n, i) => line(`${n} row${n === 1 ? "" : "s"} affected (statement ${i + 1}).`));
    if (t.error) line(t.error.text, "t-err");
    if (t.status === "COMMIT") line(t.dbms_output.length ? "PL/SQL procedure successfully completed. COMMIT complete." : "Commit complete.");
    else if (t.status === "REPORT") line("PL/SQL procedure successfully completed.");
    else line("Rollback complete: no row was changed.", "t-err");
  }

  function diffBlock(d) {
    const block = el("div", "diff-block");
    const head = el("div", "diff-head");
    head.append(el("span", "diff-table-name", d.table), el("span", "diff-label", d.label));
    Object.entries(d.counts).forEach(([k, n]) => { if (n && k !== "unchanged") head.appendChild(pill(`${n} ${k}`, k === "inserted" ? "pass" : k === "deleted" ? "fail" : "accent")); });
    block.appendChild(head);
    const scroller = el("div", "table-scroller auto");
    const table = el("table", "data-table diff-table");
    const thead = el("thead"), tbody = el("tbody");
    const htr = el("tr");
    d.columns.forEach((c) => htr.appendChild(el("th", null, c)));
    thead.appendChild(htr);
    if (!d.rows.length) {
      const r = el("tr"); const td = el("td", "table-empty", "No row before or after."); td.colSpan = Math.max(1, d.columns.length); r.appendChild(td); tbody.appendChild(r);
    }
    d.rows.forEach((row) => {
      const tr = el("tr", "ch-" + row.change);
      d.columns.forEach((c, i) => {
        const [oldV, newV] = row.cells[c] || [null, null];
        const td = el("td");
        if (row.change === "updated" && oldV !== newV) {
          td.classList.add("cell-changed");
          td.append(el("span", "cell-old", oldV === null ? "NULL" : String(oldV)), el("span", "cell-arrow", "→"), el("span", "cell-new", newV === null ? "NULL" : String(newV)));
        } else {
          const v = row.change === "deleted" ? oldV : newV;
          td.appendChild(v === null || v === undefined ? el("span", "tone-dim", "NULL") : document.createTextNode(String(v)));
        }
        if (i === 0 && row.change !== "unchanged") td.appendChild(el("span", "ch-tag", row.change.toUpperCase()));
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
    table.append(thead, tbody); scroller.appendChild(table); block.appendChild(scroller);
    return block;
  }

  // ======================================================================
  // 04 LEDGER
  // ======================================================================
  async function loadLedger() {
    const d = await api("/api/ledger");
    const t = d.totals;
    countUp($("ledHeld"), t.total_held, money);
    countUp($("ledReleased"), t.total_released, money);
    countUp($("ledRefunded"), t.total_refunded, money);
    countUp($("ledInEscrow"), t.currently_in_escrow, money);
    const total = Math.max(1, t.total_held);
    const pct = (v) => (100 * v) / total;
    $("gRelease").style.width = pct(t.total_released).toFixed(2) + "%";
    $("gRefund").style.width = pct(t.total_refunded).toFixed(2) + "%";
    $("gHeld").style.width = pct(t.currently_in_escrow).toFixed(2) + "%";
    $("gaugeLegend").textContent = `Of ${money(t.total_held)} ever held: ${pct(t.total_released).toFixed(1)}% released, ` +
      `${pct(t.total_refunded).toFixed(1)}% refunded, ${pct(t.currently_in_escrow).toFixed(1)}% still in escrow.`;

    const bars = clear($("categoryBars"));
    const max = Math.max(1, ...d.by_category.map((c) => c.platform_revenue));
    d.by_category.forEach((c) => {
      const r = el("div", "bar-row");
      const rail = el("div", "bar-rail"); const fill = el("div", "bar-fill"); fill.style.width = "0%"; rail.appendChild(fill);
      r.append(el("span", "bar-name", `${c.category_name} (${c.items_sold})`), rail, el("span", "bar-val", money(c.platform_revenue)));
      bars.appendChild(r);
      requestAnimationFrame(() => { fill.style.width = ((100 * c.platform_revenue) / max).toFixed(1) + "%"; });
    });

    const bad = d.reconciliation.filter((r) => r.check_result !== "OK").length;
    const banner = clear($("reconBanner"));
    banner.className = "recon-banner " + (bad ? "tone-fail" : "tone-pass");
    banner.append(el("span", null, bad ? "✕" : "✓"),
      el("span", null, bad ? `${bad} order(s) do not reconcile` : `All ${d.reconciliation.length} orders reconcile: no rupee lost or counted twice.`));
    const rb = clear($("reconBody"));
    d.reconciliation.forEach((r) => {
      const tr = el("tr");
      tr.append(el("td", null, r.order_id));
      const s = el("td"); s.appendChild(pill(r.status)); tr.appendChild(s);
      tr.append(el("td", "num", money(r.price)), el("td", "num", money(r.held_now)), el("td", "num", money(r.should_hold)));
      const c = el("td"); c.appendChild(pill(r.check_result)); tr.appendChild(c);
      rb.appendChild(tr);
    });
    const tb = clear($("txnBody"));
    $("txnCount").textContent = d.txns.length;
    d.txns.forEach((x) => {
      const tr = el("tr");
      tr.append(el("td", null, x.txn_id), el("td", null, x.order_id));
      const ty = el("td"); ty.appendChild(pill(x.txn_type)); tr.appendChild(ty);
      tr.append(el("td", "num", money(x.amount)), el("td", "wrap", x.title), el("td", "monospace", x.txn_time));
      tb.appendChild(tr);
    });
    const wb = clear($("walletBody"));
    d.wallets.forEach((u) => {
      const tr = el("tr");
      tr.append(el("td", null, u.user_id), el("td", null, u.full_name));
      const r = el("td"); r.appendChild(pill(u.role)); tr.appendChild(r);
      tr.appendChild(el("td", "num", money(u.wallet_balance)));
      const b = el("td"); b.appendChild(pill(u.is_blocked)); tr.appendChild(b);
      wb.appendChild(tr);
    });
  }

  // ======================================================================
  // 05 REPORTS
  // ======================================================================
  function renderReportList() {
    const list = clear($("reportList"));
    const order = ["Retrieval", "Joins", "Subqueries", "Aggregation", "Analytics", "Set operations", "Views", "Review III"];
    const sorted = state.meta.reports.slice().sort((a, b) => order.indexOf(a.group) - order.indexOf(b.group));
    let group = null;
    sorted.forEach((r) => {
      if (r.group !== group) { group = r.group; list.appendChild(el("div", "report-group-title", group)); }
      const b = el("button", "report-item" + (r.key === state.reportKey ? " active" : ""), null, { type: "button", "data-key": r.key });
      const right = el("span"); right.append(document.createTextNode(r.title), el("span", "report-concept", r.concept));
      b.append(el("span", "report-key", r.key), right);
      b.addEventListener("click", () => openReport(r.key));
      list.appendChild(b);
    });
  }
  async function openReport(key) {
    state.reportKey = key;
    document.querySelectorAll(".report-item").forEach((b) => b.classList.toggle("active", b.dataset.key === key));
    let d;
    try { d = await api(`/api/reports/${key}`); } catch (e) { notify(e.message, "error"); return; }
    $("reportTitle").textContent = `${d.key}. ${d.title}`;
    $("reportConcept").textContent = d.concept.toUpperCase();
    $("reportRows").textContent = `${d.rows.length} ROWS`;
    const ub = $("reportUsedBy");
    ub.classList.toggle("hidden", !d.used_by);
    ub.textContent = d.used_by ? `USED BY THE APP → ${d.used_by}` : "";
    highlight(d.sql, $("reportSql"));
    renderTable($("reportHead"), $("reportBody"), d.columns, d.rows, "no rows selected");
  }
  function renderObjects() {
    const g = clear($("objectGrid"));
    state.meta.objects.forEach((o) => {
      const item = el("div", "object-item");
      const b = el("button", "btn btn-ghost btn-xs", "Source");
      b.addEventListener("click", () => openSource(o.name));
      item.append(el("span", "type-badge type-" + o.type, o.type), el("span", "object-name", o.name), b,
        el("span", "object-purpose", o.purpose));
      item.appendChild(el("span", "review-tag" + (o.review === "III" ? " r3" : ""), `REVIEW ${o.review}`));
      g.appendChild(item);
    });
  }
  async function runStatement() {
    const t = await runTx("seller_statement", { seller_id: Number($("statementSeller").value) }, { silent: true });
    const out = clear($("statementOut"));
    if (!t) return;
    const line = (s, c) => { out.appendChild(el("span", c || null, s)); out.appendChild(document.createTextNode("\n")); };
    line("SQL> SET SERVEROUTPUT ON", "t-dim");
    line(`SQL> EXEC seller_statement(${$("statementSeller").value});`, "t-prompt");
    t.dbms_output.forEach((l) => line(l));
    if (t.error) line(t.error.text, "t-err"); else line("PL/SQL procedure successfully completed.", "t-dim");
  }
  async function openSource(name) {
    try {
      const s = await api(`/api/source/${name}`);
      $("sourceType").textContent = `${s.type} // database/CampusKart_Review3.sql`;
      $("sourceTitle").textContent = s.name;
      highlight(s.source, $("sourceCode"));
      $("sourceModal").classList.remove("hidden");
    } catch (e) { notify(e.message, "error"); }
  }

  // ======================================================================
  // RESET
  // ======================================================================
  async function doReset(quiet) {
    $("confirmResetBtn").disabled = true;
    try {
      const r = await post("/api/reset");
      state.traces = []; state.presetResults = {}; state.shownTraceId = null;
      $("verdictStandby").classList.remove("hidden"); $("verdictBody").classList.add("hidden");
      $("verdictCard").className = "verdict-card"; $("anatomyCard").classList.add("hidden");
      paintPresetResults(); renderHistory();
      $("resetModal").classList.add("hidden");
      if (!quiet) notify(r.message, "success");
      if (r.compile_errors && r.compile_errors.length) notify(`${r.compile_errors.length} compile error(s): ${r.compile_errors[0].name} line ${r.compile_errors[0].line}`, "error");
      await refreshAfterChange();
    } catch (e) { notify(`Reset failed: ${e.message}`, "error"); }
    finally { $("confirmResetBtn").disabled = false; }
  }

  // ======================================================================
  // EVENTS + BOOT
  // ======================================================================
  function initEvents() {
    document.querySelectorAll(".tab-btn").forEach((b) => b.addEventListener("click", () => switchTab(b.dataset.tab)));
    $("actorSelect").addEventListener("change", (e) => {
      state.me = Number(e.target.value); safeSet("ck-actor", state.me); renderActor();
      loadTab(state.activeTab);
      if (state.activeTab === "market" && state.selectedListing) selectListing(state.selectedListing, true);
    });
    ["fSearch", "fMax"].forEach((id) => $(id).addEventListener("input", scheduleListings));
    ["fCategory", "fCondition", "fStatus"].forEach((id) => $(id).addEventListener("change", loadListings));
    $("createListingBtn").addEventListener("click", createListing);
    document.querySelectorAll(".iso-slab").forEach((s) => s.addEventListener("click", () => renderStage(Number(s.dataset.stage))));
    $("runBatchBtn").addEventListener("click", () => runTx("auto_release", { days: 3 }));
    $("topupBtn").addEventListener("click", () => runTx("topup_wallet", { amount: $("topupAmount").value }));
    $("blockBtn").addEventListener("click", () => runTx("block_user", { user_id: $("blockUser").value, blocked: "Y" }));
    $("unblockBtn").addEventListener("click", () => runTx("block_user", { user_id: $("blockUser").value, blocked: "N" }));
    $("autopilotBtn").addEventListener("click", autopilot);
    $("resetBtn").addEventListener("click", () => $("resetModal").classList.remove("hidden"));
    $("cancelResetBtn").addEventListener("click", () => $("resetModal").classList.add("hidden"));
    $("confirmResetBtn").addEventListener("click", () => doReset(false));
    $("closeSourceBtn").addEventListener("click", () => $("sourceModal").classList.add("hidden"));
    $("sourceModal").addEventListener("click", (e) => { if (e.target.id === "sourceModal") $("sourceModal").classList.add("hidden"); });
    $("closeNotifBtn").addEventListener("click", () => $("systemNotification").classList.add("hidden"));
    $("statementBtn").addEventListener("click", runStatement);
    $("copySqlBtn").addEventListener("click", () => {
      navigator.clipboard.writeText($("reportSql").textContent).then(() => notify("SQL copied to clipboard.", "success"), () => {});
    });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") { $("sourceModal").classList.add("hidden"); $("resetModal").classList.add("hidden"); } });
  }

  async function init() {
    initTheme(); initCanvas(); initSpotlight(); initTilt(); initEvents();
    try {
      await loadStatus();
      const [meta, cats] = await Promise.all([api("/api/meta"), api("/api/categories")]);
      state.meta = meta; state.categories = cats;
      cats.forEach((c) => {
        const o = el("option", null, `${c.category_name} (${c.fee_percent}% fee)`); o.value = c.category_id; $("nlCategory").appendChild(o);
        const o2 = el("option", null, c.category_name); o2.value = c.category_id; $("fCategory").appendChild(o2);
      });
      renderPresets(); renderReportList(); renderObjects(); renderStage(5);
      state.traces = await api("/api/traces");
      renderHistory();
      await Promise.all([loadUsers(), loadOverview()]);
      const want = (location.hash || "").replace("#", "");
      if (["market", "orders", "trace", "ledger", "reports"].includes(want)) switchTab(want); else await loadListings();
      if (state.traces.length) showTrace(state.traces[0].id);
    } catch (e) {
      notify(`Cannot reach the CampusKart server: ${e.message}`, "error");
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
})();
