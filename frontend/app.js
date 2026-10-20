/* =====================================================================
   Apex Trader :: dashboard
   Vanilla JS, no build step. Talks to the FastAPI backend and subscribes
   to the WebSocket stream, which is itself driven by PostgreSQL
   LISTEN/NOTIFY -- so fills appear because the database pushed them, not
   because the page polled.
   ===================================================================== */
'use strict';

const API = '/api';

/*
  The API contract this dashboard was built against. The server reports
  its own at /api/health.

  These drift in exactly one direction and for exactly one reason: a new
  frontend unpacked over an old server that is still running. Unregistered
  /api routes fall through to the StaticFiles mount, which answers 404 to
  a GET and 405 to a POST -- so the symptoms are "Not Found" where search
  should be, "Not Found" where history should be, empty market cards,
  "Watchlist failed: Method Not Allowed", and empty currency dropdowns.
  Six faults, one cause, and none of them name it.

  So check it once, before anything else loads, and say it.
*/
const NEEDS_API_CONTRACT = 3;
const state = {
  token: null, refresh: null, user: null, accountId: null, role: 'trader',
  symbol: 'AAPL', interval: '1h', side: 'buy', tab: 'orders',
  instruments: [], quote: null, book: null, ws: null, charts: {},
  // Currency: baseCcy is what the ACCOUNT is denominated in (fixed);
  // displayCcy is what the viewer wants to read (free to change).
  baseCcy: 'USD', displayCcy: 'USD', fx: {}, ccyMeta: {},
  histKind: 'all',
  // Asset classes. 'watch' is not a class -- it is the watchlist used as
  // a filter, which is how people actually navigate a universe that now
  // contains two session models.
  assetClass: 'all', mkClass: 'all',
  watchlist: null, watchSyms: new Set(), alerts: [], alertFires: [],
  indicators: { ma: true, bb: false, vol: true, rsi: false },
  search: { rows: [], cur: 0, seq: 0, open: false },
  lastTable: { name: 'orders', cols: [], rows: [] },
};

/* ---------------------------------------------------------------- utils */
const $  = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const num = v => (v === null || v === undefined || v === '') ? NaN : Number(v);

function fmt(v, dp = 2) {
  const n = num(v);
  if (!isFinite(n)) return '—';
  return n.toLocaleString(undefined, { minimumFractionDigits: dp, maximumFractionDigits: dp });
}
/**
 * Format an amount in a given currency.
 *
 * Amounts arriving from the API are already in a known currency -- the
 * account's base for portfolio figures, the instrument's quote currency
 * for prices. Nothing is converted implicitly here: `from` says what the
 * number IS, and conversion to the display currency is explicit.
 */
function money(v, dp = 2, ccy = null) {
  const n = num(v);
  if (!isFinite(n)) return '—';
  const code = ccy || state.displayCcy || 'USD';
  const meta = state.ccyMeta[code] || { symbol: '$', minor_units: dp };
  const places = ccy === null && dp !== 2 ? dp : Number(meta.minor_units ?? dp);
  return (n < 0 ? '-' : '') + (meta.symbol || '') +
    Math.abs(n).toLocaleString(undefined,
      { minimumFractionDigits: places, maximumFractionDigits: places });
}

/** Convert an amount between currencies using the loaded FX board. */
function fxConv(v, from, to = null) {
  const n = num(v);
  const dst = to || state.displayCcy || 'USD';
  if (!isFinite(n) || !from || from === dst) return n;
  const perUsdFrom = num(state.fx[from]), perUsdTo = num(state.fx[dst]);
  if (!isFinite(perUsdFrom) || !isFinite(perUsdTo) || perUsdFrom === 0) return n;
  return n * (perUsdTo / perUsdFrom);
}

/** Show an amount that is stored in `from`, rendered in the display currency. */
function moneyIn(v, from, dp = 2) {
  return money(fxConv(v, from), dp);
}
/*
  Quantity formatting.

  Everything was printed with fmt(x, 0) because every quantity on this
  venue used to be a whole share. Crypto broke that: 0.002 BTC rendered
  as "0", so a filled order looked like it had no size and a portfolio
  looked empty. Scale the precision to the magnitude instead -- 1,250
  shares needs no decimals, 0.00184 BTC needs five.
*/
function qty(v) {
  const n = num(v);
  if (!isFinite(n)) return '—';
  const a = Math.abs(n);
  if (a === 0) return '0';
  if (Number.isInteger(n) && a >= 1) return n.toLocaleString();
  if (a >= 1000) return fmt(n, 0);
  if (a >= 1) return fmt(n, 2).replace(/\.00$/, '');
  if (a >= 0.01) return fmt(n, 4);
  return fmt(n, 8).replace(/0+$/, '');
}

/*
  Price formatting has the same problem from the other end: a $92,000
  coin wants 2 decimals and a $0.127 one wants 5. The instrument's own
  tick size is the right authority, so use it when we have it.
*/
function price(v, sym = null) {
  const n = num(v);
  if (!isFinite(n)) return '—';
  const inst = state.instruments.find(i => i.symbol === (sym || state.symbol));
  if (inst) {
    const tick = num(inst.tick_size);
    if (isFinite(tick) && tick > 0) {
      const dp = Math.max(0, Math.round(-Math.log10(tick)));
      return fmt(n, Math.min(dp, 8));
    }
  }
  return fmt(n, Math.abs(n) >= 1 ? 2 : 6);
}

function compact(v) {
  const n = num(v);
  if (!isFinite(n)) return '—';
  const a = Math.abs(n);
  if (a >= 1e9) return (n / 1e9).toFixed(2) + 'B';
  if (a >= 1e6) return (n / 1e6).toFixed(2) + 'M';
  if (a >= 1e3) return (n / 1e3).toFixed(1) + 'K';
  return n.toFixed(0);
}
function pct(v, dp = 2) {
  const n = num(v);
  if (!isFinite(n)) return '—';
  return (n > 0 ? '+' : '') + n.toFixed(dp) + '%';
}
const cls = v => { const n = num(v); return !isFinite(n) || n === 0 ? '' : (n > 0 ? 'up' : 'down'); };
const esc = s => String(s ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const time = ts => ts ? new Date(ts).toLocaleTimeString([], { hour12: false }) : '—';
const date = ts => ts ? new Date(ts).toLocaleDateString([], { month: 'short', day: 'numeric' }) : '—';

function toast(title, body, kind = 'info') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.innerHTML = `<div class="t-title">${esc(title)}</div>` +
                 (body ? `<div class="t-body">${esc(body)}</div>` : '');
  $('#toasts').appendChild(el);
  setTimeout(() => { el.style.opacity = '0'; setTimeout(() => el.remove(), 300); }, 5200);
}

async function api(path, opts = {}) {
  const res = await fetch(API + path, {
    ...opts,
    headers: {
      'Content-Type': 'application/json',
      ...(state.token ? { Authorization: `Bearer ${state.token}` } : {}),
      ...(opts.headers || {}),
    },
  });
  if (res.status === 401 && state.refresh) {
    if (await tryRefresh()) return api(path, opts);
  }
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = { detail: text }; }
  if (!res.ok) {
    const msg = data?.detail
      ? (typeof data.detail === 'string' ? data.detail : JSON.stringify(data.detail))
      : `HTTP ${res.status}`;
    throw new Error(msg);
  }
  return data;
}

async function tryRefresh() {
  try {
    const r = await fetch(`${API}/auth/refresh`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: state.refresh }),
    });
    if (!r.ok) return false;
    const t = await r.json();
    state.token = t.access_token; state.refresh = t.refresh_token;
    sessionStorage.setItem('apex', JSON.stringify({ t: state.token, r: state.refresh }));
    return true;
  } catch { return false; }
}

/* ---------------------------------------------------------------- login */
/**
 * Demo logins come from the API, not from a constant here.
 *
 * This list used to be hardcoded, so reseeding with a different set of
 * accounts left the login screen offering names that did not exist. The
 * database is the single source of truth for who can log in.
 */
async function renderDemoChips() {
  const box = $('#demo-chips');
  try {
    const d = await (await fetch(`${API}/auth/demo-accounts`)).json();
    if (!d.demo_mode || !d.accounts?.length) {
      $('.demo-accounts')?.remove();
      return;
    }

    $('.demo-accounts .hdr').textContent =
      `Demo accounts — password ${d.password}`;

    box.innerHTML = d.accounts.map(a => {
      const tags = [];
      if (a.kind === 'margin') tags.push('margin');
      if (a.allow_short_selling) tags.push('shorts');
      if (a.publishes_strategy) tags.push('strategy');
      if (a.is_flagged) tags.push('flagged');
      if (a.role !== 'trader') tags.push(a.role);
      // The handle, not the first name: these accounts are known by what
      // you sign in as. "Kumar Paritosh" logs in as paritosh.
      const handle = (a.email || '').split('@')[0];
      return `<span class="demo-chip" data-email="${esc(a.email)}"
                title="${esc(a.full_name)} · ${esc(a.email)}">
                <b>${esc(handle)}</b>
                <span class="chip-name">${esc(a.full_name || '')}</span>
                <span class="chip-ccy">${esc(a.currency_symbol || '')} ${esc(a.base_currency)}</span>
                ${tags.length ? `<span class="chip-tag">${esc(tags.join(' · '))}</span>` : ''}
              </span>`;
    }).join('');

    $$('#demo-chips .demo-chip').forEach(c => c.onclick = () => {
      $('#email').value = c.dataset.email;
      $('#password').value = d.password;
      $('#login-form').requestSubmit();
    });

    // Prefill with the first trader so the form is ready to submit.
    if (!$('#email').value) {
      $('#email').value = d.accounts[0].email;
      $('#password').value = d.password;
    }
  } catch (e) {
    box.innerHTML = `<span style="font-size:11px;color:var(--text-faint)">
      could not load demo accounts — is the API running?</span>`;
  }
}

$('#login-form').addEventListener('submit', async e => {
  e.preventDefault();
  const btn = $('#login-btn'); btn.disabled = true; btn.textContent = 'Signing in…';
  $('#login-error').textContent = '';
  try {
    const t = await (await fetch(`${API}/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: $('#email').value, password: $('#password').value }),
    }).then(r => r.ok ? r : Promise.reject(new Error('invalid credentials')))).json();
    state.token = t.access_token; state.refresh = t.refresh_token;
    state.accountId = t.account_id; state.role = t.role; state.user = t.full_name;
    sessionStorage.setItem('apex', JSON.stringify({ t: state.token, r: state.refresh }));
    await boot();
  } catch (err) {
    $('#login-error').textContent = err.message;
  } finally { btn.disabled = false; btn.textContent = 'Sign in'; }
});

$('#logout-btn').onclick = () => { sessionStorage.removeItem('apex'); location.reload(); };
$('#theme-btn').onclick = () => {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  localStorage.setItem('apex-theme', next);
  Object.values(state.charts).forEach(c => c?.applyOptions?.(chartTheme()));
};
try {
  const th = localStorage.getItem('apex-theme');
  if (th) document.documentElement.dataset.theme = th;
} catch {}

/* ---------------------------------------------------------------- boot */
/*
  Refuse to start against a server that cannot serve this dashboard.
  Shown instead of the app, with the command that fixes it, because the
  alternative is six panels failing in six different ways.
*/
async function checkApiContract() {
  let h;
  try {
    h = await (await fetch(`${API}/health`)).json();
  } catch {
    return;   // Server unreachable is a different problem, handled elsewhere.
  }
  const got = h.api_contract;
  if (got === NEEDS_API_CONTRACT) return;

  const stale = got === undefined
    ? 'The server is running an older build that predates version reporting.'
    : `The server speaks contract ${got}; this dashboard needs ${NEEDS_API_CONTRACT}.`;

  document.body.innerHTML = `
    <div style="max-width:720px;margin:12vh auto;padding:28px;font:14px/1.65 var(--sans);
         color:var(--text);background:var(--bg-panel);border:1px solid var(--down);
         border-radius:10px">
      <h2 style="margin-bottom:10px;color:var(--down)">The API server is out of date</h2>
      <p style="color:var(--text-dim)">${esc(stale)} The dashboard files on disk are newer
         than the process serving them &mdash; almost always an API server left running from
         an earlier session, which <code>api.sh start</code> reports as
         &ldquo;already running&rdquo; rather than replacing.</p>
      <p style="color:var(--text-dim);margin-top:10px">Nothing is broken and no data is lost.
         Restart the server:</p>
      <pre style="background:var(--bg);padding:12px 14px;border-radius:6px;margin:12px 0;
           font:13px var(--mono);color:var(--accent)">cd ~/Downloads/apex-trader
./scripts/api.sh restart</pre>
      <p style="color:var(--text-faint);font-size:12px">Then reload this page. If it persists,
         something else is holding port 8000:
         <code>lsof -ti:8000 | xargs kill</code></p>
    </div>`;
  throw new Error('api contract mismatch');
}

async function boot() {
  await checkApiContract();
  const me = await api('/auth/me');
  state.user = me.user.full_name; state.role = me.user.role;
  if (me.accounts?.length) state.accountId = me.accounts[0].account_id;

  $('#who-name').textContent = state.user;
  $('#who-role').textContent = state.role;
  $('#nav-compliance').hidden = !['compliance', 'admin'].includes(state.role);
  $('#login-screen').style.display = 'none';
  $('#app').classList.add('ready');

  state.baseCcy = me.accounts?.[0]?.base_currency || 'USD';
  state.displayCcy = state.baseCcy;
  await loadFx();

  state.instruments = await api('/market/instruments');
  await loadWatchlist();
  loadAlerts();
  renderTape();
  renderAbout();
  renderShortcuts();

  // Connect the stream FIRST and independently. An earlier version
  // awaited selectSymbol() before connectWS(); when the charting library
  // failed to load, loadChart() threw and the WebSocket was never opened
  // -- so a cosmetic failure silently took out real-time updates.
  connectWS();

  try { await selectSymbol(state.symbol); }
  catch (e) { toast('Could not load market view', e.message, 'err'); }

  setInterval(refreshLight, 6000);
}

/* ---------------------------------------------------------------- currency */
async function loadFx() {
  try {
    const board = await api('/market/fx');
    state.fx = {}; state.ccyMeta = {};
    board.forEach(r => {
      state.fx[r.code] = num(r.per_usd);
      state.ccyMeta[r.code] = { symbol: r.symbol, name: r.name,
                                minor_units: r.minor_units };
    });
    const sel = $('#ccy-select');
    sel.innerHTML = board.map(r =>
      `<option value="${esc(r.code)}">${esc(r.symbol)} ${esc(r.code)}</option>`).join('');
    sel.value = state.displayCcy;
    sel.onchange = () => {
      state.displayCcy = sel.value;
      // Re-render whichever page is visible, in the new currency.
      const active = $$('nav button').find(b => b.classList.contains('active'));
      const v = active?.dataset.view;
      if (v === 'portfolio') loadPortfolio();
      else if (v === 'markets') loadMarkets();
      else if (v === 'history') loadHistory();
      loadBuyingPower(); updateEstimate();
    };
  } catch (e) { console.error('fx load failed', e); }
}

/* ---------------------------------------------------------------- nav */
$$('nav button').forEach(b => b.onclick = async () => {
  $$('nav button').forEach(x => x.classList.toggle('active', x === b));
  $$('.view').forEach(v => v.classList.toggle('active', v.id === `view-${b.dataset.view}`));
  if (b.dataset.view === 'portfolio') await loadPortfolio();
  if (b.dataset.view === 'history') await loadHistory();
  if (b.dataset.view === 'markets') await loadMarkets();
  if (b.dataset.view === 'social') await loadSocial();
  if (b.dataset.view === 'compliance') await loadCompliance();
  window.dispatchEvent(new Event('resize'));
});

/* ---------------------------------------------------------------- tape */
/*
  The tape now spans two session models. An equity that is closed and a
  coin that is trading at 3am look identical if all you print is a price,
  so each row carries its class and its session state. 'watch' filters to
  the user's own list, which is how you actually navigate 24 names.
*/
function classOf(i) {
  if (i.kind === 'crypto') return 'crypto';
  if (i.kind === 'etf' || i.sector === 'Index Fund' ||
      ['SPY', 'QQQ'].includes(i.symbol)) return 'etf';
  return 'equity';
}

function visibleInstruments(klass = state.assetClass) {
  if (klass === 'watch') return state.instruments.filter(i => state.watchSyms.has(i.symbol));
  if (klass === 'all') return state.instruments;
  return state.instruments.filter(i => classOf(i) === klass);
}

function renderTape() {
  const rows = visibleInstruments();
  if (!rows.length) {
    $('#tape').innerHTML = state.assetClass === 'watch'
      ? `<div class="empty" style="padding:9px 14px">Your watchlist is empty &mdash; press ☆ on any instrument</div>`
      : `<div class="empty" style="padding:9px 14px">Nothing in this asset class</div>`;
    return;
  }
  $('#tape').innerHTML = rows.map(i => `
    <div class="tape-item ${i.symbol === state.symbol ? 'sel' : ''}" data-sym="${esc(i.symbol)}">
      <span class="sym">${esc(i.symbol)}${state.watchSyms.has(i.symbol) ? ' ★' : ''}</span>
      <span class="px">${price(i.last_price, i.symbol)}</span>
      <span class="${cls(i.change_pct)}" style="font:11px var(--mono)">${pct(i.change_pct)}</span>
      ${i.trades_24x7 ? '<span class="badge c24">24×7</span>'
                      : (i.market_open === false ? '<span class="badge closed">closed</span>' : '')}
    </div>`).join('');
  $$('#tape .tape-item').forEach(el =>
    el.onclick = () => selectSymbol(el.dataset.sym));
}

$$('#class-seg button').forEach(b => b.onclick = async () => {
  $$('#class-seg button').forEach(x => x.classList.toggle('active', x === b));
  state.assetClass = b.dataset.class;
  if (state.assetClass === 'watch') await loadWatchlist();
  renderTape();
});

/* ---------------------------------------------------------------- chart */
function chartTheme() {
  const d = document.documentElement.dataset.theme !== 'light';
  return {
    layout: { background: { color: 'transparent' }, textColor: d ? '#8b97a8' : '#5a6676',
              fontFamily: 'ui-monospace, Menlo, monospace', fontSize: 10 },
    grid: { vertLines: { color: d ? '#1a212c' : '#eceff3' },
            horzLines: { color: d ? '#1a212c' : '#eceff3' } },
    rightPriceScale: { borderColor: d ? '#222b38' : '#dde3ea' },
    timeScale: { borderColor: d ? '#222b38' : '#dde3ea', timeVisible: true, secondsVisible: false },
    crosshair: { mode: 1 },
  };
}

function buildPriceChart() {
  const el = $('#chart');
  el.innerHTML = '';
  const chart = LightweightCharts.createChart(el, {
    ...chartTheme(), width: el.clientWidth, height: el.clientHeight, autoSize: true,
  });
  const candles = chart.addCandlestickSeries({
    upColor: '#00c896', downColor: '#ff4d6a',
    borderUpColor: '#00c896', borderDownColor: '#ff4d6a',
    wickUpColor: '#00c896', wickDownColor: '#ff4d6a',
  });
  const volume = chart.addHistogramSeries({
    priceFormat: { type: 'volume' }, priceScaleId: 'vol',
  });
  chart.priceScale('vol').applyOptions({ scaleMargins: { top: 0.84, bottom: 0 } });
  const line = (color, width = 1, dashed = false) => chart.addLineSeries({
    color, lineWidth: width, priceLineVisible: false, lastValueVisible: false,
    crosshairMarkerVisible: false,
    lineStyle: dashed ? LightweightCharts.LineStyle.Dashed : LightweightCharts.LineStyle.Solid,
  });
  state.charts.price = chart;
  return {
    chart, candles, volume,
    ma10: line('#4d8dff'), ma20: line('#ffb020'),
    bbUp: line('#8b97a8', 1, true), bbLo: line('#8b97a8', 1, true),
  };
}

/*
  RSI lives in its own pane rather than on the price scale. Overlaying a
  0-100 oscillator on a $92,000 price axis compresses the candles to a
  flat line -- the first version did exactly that and the chart was
  unreadable. A second synchronised chart is the conventional answer.
*/
function buildRsiChart() {
  const el = $('#rsi-chart');
  el.innerHTML = '';
  const chart = LightweightCharts.createChart(el, {
    ...chartTheme(), width: el.clientWidth, height: el.clientHeight, autoSize: true,
    rightPriceScale: { ...chartTheme().rightPriceScale, scaleMargins: { top: .1, bottom: .1 } },
    timeScale: { ...chartTheme().timeScale, visible: false },
  });
  const rsi = chart.addLineSeries({ color: '#c47dff', lineWidth: 1, priceLineVisible: false });
  // The conventional 30/70 bands, drawn as price lines so they scroll
  // with the series instead of being painted on at fixed pixels.
  [30, 70].forEach(v => rsi.createPriceLine({
    price: v, color: '#5a6676', lineWidth: 1,
    lineStyle: LightweightCharts.LineStyle.Dotted, axisLabelVisible: true,
  }));

  // Keep the two time axes locked together. Without this, zooming the
  // price chart leaves RSI showing a different window, which is worse
  // than not showing it at all.
  const main = state.charts.price;
  if (main) {
    let syncing = false;
    const sync = (from, to) => r => {
      if (syncing || !r) return;
      syncing = true;
      try { to.timeScale().setVisibleLogicalRange(r); } finally { syncing = false; }
    };
    main.timeScale().subscribeVisibleLogicalRangeChange(sync(main, chart));
    chart.timeScale().subscribeVisibleLogicalRangeChange(sync(chart, main));
  }
  state.charts.rsi = chart;
  return { chart, rsi };
}

async function loadChart() {
  if (typeof LightweightCharts === 'undefined') {
    $('#chart').innerHTML =
      `<div class="empty">Charting library failed to load (vendor/lightweight-charts.js)</div>`;
    return;
  }
  if (!state.charts.priceSeries) state.charts.priceSeries = buildPriceChart();
  const s = state.charts.priceSeries;
  const ind = state.indicators;
  // Indicators are computed in SQL by market.candles_with_indicators(),
  // as window functions over the same aggregated bars -- so a 1h SMA is
  // the mean of the same 1h bars the chart is drawing, not of something
  // the browser re-derived.
  const wantInd = ind.ma || ind.bb || ind.rsi;
  const days = { '1m': 2, '5m': 7, '15m': 20, '1h': 45, '1d': 400 }[state.interval] || 30;

  const d = await api(`/market/candles/${state.symbol}?interval=${state.interval}` +
                      `&days=${days}&indicators=${wantInd}`);
  state.charts.lastBars = d.candles;
  const t = c => Math.floor(new Date(c.bucket).getTime() / 1000);
  const bars = d.candles.map(c => ({
    time: t(c), open: num(c.open), high: num(c.high),
    low: num(c.low), close: num(c.close),
  })).filter(b => isFinite(b.open));

  s.candles.setData(bars);

  s.volume.setData(!ind.vol ? [] : d.candles.map(c => ({
    time: t(c),
    value: num(c.volume) || 0,
    color: num(c.close) >= num(c.open) ? 'rgba(0,200,150,.3)' : 'rgba(255,77,106,.3)',
  })));
  s.chart.priceScale('vol').applyOptions({ visible: ind.vol });

  const pick = k => d.candles
    .filter(c => c[k] !== null && c[k] !== undefined)
    .map(c => ({ time: t(c), value: num(c[k]) }));

  s.ma10.setData(ind.ma ? pick('sma_10') : []);
  s.ma20.setData(ind.ma ? pick('sma_20') : []);
  s.bbUp.setData(ind.bb ? pick('bb_upper') : []);
  s.bbLo.setData(ind.bb ? pick('bb_lower') : []);

  $('#rsi-chart').hidden = !ind.rsi;
  if (ind.rsi) {
    if (!state.charts.rsiSeries) state.charts.rsiSeries = buildRsiChart();
    state.charts.rsiSeries.rsi.setData(pick('rsi_14'));
  }

  s.chart.timeScale().fitContent();
  if (ind.rsi && state.charts.rsi) state.charts.rsi.timeScale().fitContent();
}

$$('#interval-seg button').forEach(b => b.onclick = () => {
  $$('#interval-seg button').forEach(x => x.classList.toggle('active', x === b));
  state.interval = b.dataset.iv; loadChart();
});

$$('#ind-seg button').forEach(b => b.onclick = () => {
  const k = b.dataset.ind;
  state.indicators[k] = !state.indicators[k];
  b.classList.toggle('active', state.indicators[k]);
  loadChart();
});

/* ---------------------------------------------------------------- quote */
function renderQuote() {
  const q = state.quote; if (!q) return;
  const chg = num(q.change_pct);
  const inst = state.instruments.find(i => i.symbol === q.symbol);
  const c24 = inst?.trades_24x7;
  // Where in the day's range the last print sits. One bar says more than
  // "Day 91,480-92,640" does, and it costs nothing we have not fetched.
  const lo = num(q.day_low), hi = num(q.day_high), last = num(q.last_price);
  const posPct = (isFinite(lo) && isFinite(hi) && hi > lo)
    ? Math.min(100, Math.max(0, (last - lo) / (hi - lo) * 100)) : null;

  $('#quote-strip').innerHTML = `
    <span class="q-sym">${esc(q.symbol)}</span>
    <span class="q-px">${price(q.last_price, q.symbol)}</span>
    <span class="q-chg ${cls(chg)}" style="background:${isFinite(chg) && chg >= 0 ? 'var(--up-bg)' : 'var(--down-bg)'}">
      ${pct(chg)}</span>
    ${c24 ? '<span class="badge c24">24×7</span>'
          : `<span class="badge ${q.market_open ? 'open' : 'closed'}">${
               q.market_open ? 'open' : 'closed'}</span>`}
    <span class="kv">Bid <b class="up">${price(q.bid, q.symbol)}</b> × ${qty(q.bid_size)}</span>
    <span class="kv">Ask <b class="down">${price(q.ask, q.symbol)}</b> × ${qty(q.ask_size)}</span>
    <span class="kv">Spread <b>${fmt(q.spread_bps, 1)} bps</b></span>
    <span class="kv">Day <b>${price(q.day_low, q.symbol)}–${price(q.day_high, q.symbol)}</b>
      ${posPct === null ? '' : `<span style="display:inline-block;width:52px;height:4px;
        background:var(--bg-raised);border-radius:2px;vertical-align:middle;margin-left:4px;
        position:relative"><i style="position:absolute;left:${posPct}%;top:-2px;width:2px;
        height:8px;background:var(--accent)"></i></span>`}</span>
    <span class="kv">Vol <b>${compact(q.day_volume)}</b></span>
    <span class="kv">Tick <b>${esc(String(inst?.tick_size ?? '').replace(/0+$/, '') || '—')}</b></span>
    <span class="kv">${esc(q.name || '')} · ${esc(q.sector || '')}</span>`;
  renderStar();
}

/* ---------------------------------------------------------------- book */
function renderBook() {
  const b = state.book; if (!b) return;
  $('#book-sym').textContent = state.symbol;
  const maxCum = Math.max(
    ...b.asks.map(r => num(r.cumulative_qty)),
    ...b.bids.map(r => num(r.cumulative_qty)), 1);

  const row = (r, side) => {
    const w = (num(r.cumulative_qty) / maxCum) * 100;
    return `<div class="book-row ${side}" data-px="${r.price}">
      <div class="depth-bar" style="width:${w}%"></div>
      <span class="price">${price(r.price)}</span>
      <span class="qty">${qty(r.visible_qty)}</span>
      <span class="cum">${qty(r.cumulative_qty)}</span>
    </div>`;
  };

  const spread = (num(b.quote?.ask) - num(b.quote?.bid));
  $('#book').innerHTML =
    `<div class="book-hdr"><span>Price</span><span>Size</span><span>Total</span></div>` +
    [...b.asks].reverse().map(r => row(r, 'ask')).join('') +
    `<div class="book-spread">
       <span>spread <b>${isFinite(spread) ? price(spread) : '—'}</b></span>
       <span>last <b>${price(b.quote?.last_price)}</b></span>
     </div>` +
    b.bids.map(r => row(r, 'bid')).join('');

  // Clicking a price level loads it into the ticket -- the standard
  // one-click-to-price interaction on a real trading ladder.
  $$('#book .book-row').forEach(el => el.onclick = () => {
    $('#o-limit').value = toTick(el.dataset.px);
    updateEstimate();
  });
}

/* ---------------------------------------------------------------- ticket */
function setSide(side) {
  state.side = side;
  $$('.side-toggle button').forEach(x =>
    x.classList.toggle('active', x.dataset.side === side));
  const sub = $('#o-submit');
  sub.textContent = `Place ${side} order`;
  sub.className = side === 'buy' ? 'buy' : 'sell';
  // Flipping side changes which half of the book is marketable.
  applyDefaultPrice();
}

$$('.side-toggle button').forEach(b => b.onclick = () => setSide(b.dataset.side));

function syncTicketFields() {
  const k = $('#o-kind').value;
  $('#wrap-limit').hidden   = !['limit', 'stop_limit', 'iceberg'].includes(k);
  $('#wrap-stop').hidden    = !['stop', 'stop_limit'].includes(k);
  $('#wrap-trail').hidden   = k !== 'trailing_stop';
  $('#wrap-display').hidden = k !== 'iceberg';
  const tif = $('#o-tif');
  // A market order cannot rest on the book, so GTC is meaningless for it.
  [...tif.options].forEach(o => o.disabled = (k === 'market' && o.value === 'gtc'));
  if (k === 'market' && tif.value === 'gtc') tif.value = 'day';
  updateEstimate();
}
$('#o-kind').onchange = syncTicketFields;
['#o-qty', '#o-limit', '#o-stop'].forEach(s => $(s).oninput = updateEstimate);

/**
 * The price a trader actually wants pre-filled.
 *
 * A buy defaults to the ASK and a sell to the BID -- the marketable side.
 * Defaulting both to last_price (as this did originally) means the
 * default order never crosses the spread, so clicking Buy appears to do
 * nothing: the order quietly rests on the book instead of filling.
 */
/*
  Microstructure of the selected instrument. Every price the ticket puts
  on the wire has to be a whole number of ticks and every quantity a whole
  number of lots -- engine.validate_order() rejects anything else. For an
  equity those are 0.01 and 1, which is why the first version simply wrote
  toFixed(2) and step="0.01" everywhere. DOGE-USD's tick is 0.00001 and its
  lot is 0.00000001, so those literals turned a click on the 0.12719 level
  into an order at 0.13.
*/
function micro(sym = state.symbol) {
  const i = state.instruments.find(x => x.symbol === sym);
  const tick = num(i?.tick_size), lot = num(i?.lot_size);
  return {
    tick: isFinite(tick) && tick > 0 ? tick : 0.01,
    lot: isFinite(lot) && lot > 0 ? lot : 1,
  };
}

const dpOf = step => Math.max(0, Math.min(8, Math.round(-Math.log10(step))));

function toTick(v, sym = state.symbol) {
  const { tick } = micro(sym);
  const n = num(v);
  if (!isFinite(n)) return '';
  return (Math.round(n / tick) * tick).toFixed(dpOf(tick));
}

/*
  Keep the number inputs' step and default in step with the instrument,
  so the browser's own spinners and validation agree with the engine's.
*/
function syncTicketMicro() {
  const { tick, lot } = micro();
  ['#o-limit', '#o-stop'].forEach(sel => { $(sel).step = tick; });
  const q = $('#o-qty');
  q.step = lot;
  q.min = lot;
  // A default of 10 whole bitcoins is not a sensible starting clip.
  const cur = num(q.value);
  if (lot < 1 && (!isFinite(cur) || cur >= 1)) {
    const px = num(state.quote?.last_price);
    q.value = isFinite(px) && px > 0
      ? (Math.max(Math.round((2000 / px) / lot) * lot, lot)).toFixed(dpOf(lot)).replace(/0+$/, '')
      : lot;
  } else if (lot >= 1 && (!isFinite(cur) || cur < 1)) {
    q.value = 10;
  }
}

function defaultPrice() {
  const q = state.quote;
  if (!q) return NaN;
  const side = state.side === 'buy' ? num(q.ask) : num(q.bid);
  return isFinite(side) ? side : num(q.last_price);
}

function applyDefaultPrice() {
  syncTicketMicro();
  const px = defaultPrice();
  if (isFinite(px)) {
    $('#o-limit').value = toTick(px);
    if (!$('#o-stop').value) $('#o-stop').value = toTick(px);
  }
  updateEstimate();
}

function updateEstimate() {
  const qty = num($('#o-qty').value);
  const limit = num($('#o-limit').value);
  const px = limit || num($('#o-stop').value) || num(state.quote?.last_price);
  // Instruments are quoted in their own currency; also show the viewer's.
  const quoteCcy = state.quote?.currency || 'USD';
  const val = (isFinite(qty) && isFinite(px)) ? qty * px : NaN;
  $('#o-est').textContent = !isFinite(val) ? '—'
    : money(val, 2, quoteCcy) +
      (quoteCcy !== state.displayCcy ? `  (${moneyIn(val, quoteCcy)})` : '');

  // ---- will this order cross, or rest? ----
  const hint = $('#o-hint');
  const q = state.quote;
  const kind = $('#o-kind').value;
  const buy = state.side === 'buy';
  const ask = num(q?.ask), bid = num(q?.bid);
  const touch = buy ? ask : bid;

  if (kind === 'market') {
    hint.className = 'marketability cross';
    hint.textContent = `fills immediately against the best ${buy ? 'offer' : 'bid'}`;
    return;
  }
  if (kind !== 'limit' && kind !== 'iceberg') {
    hint.className = 'marketability none';
    hint.textContent = kind === 'trailing_stop'
      ? 'waits until price retraces by the trail amount'
      : 'waits until the stop price trades, then becomes live';
    return;
  }
  if (!isFinite(limit) || !isFinite(touch)) {
    hint.className = 'marketability none'; hint.textContent = ''; return;
  }

  const crosses = buy ? limit >= ask : limit <= bid;
  if (crosses) {
    hint.className = 'marketability cross';
    hint.textContent =
      `crosses the spread \u2014 fills now at ${fmt(touch)} or better`;
  } else {
    const away = Math.abs((limit - touch) / touch * 100);
    hint.className = 'marketability rest';
    hint.textContent =
      `rests on the book at ${fmt(limit)} \u2014 ${fmt(away, 2)}% away from the ` +
      `${buy ? 'offer' : 'bid'} of ${fmt(touch)}; fills only if the market comes to it`;
  }
}

$('#ticket').addEventListener('submit', async e => {
  e.preventDefault();
  const btn = $('#o-submit');
  const label = btn.textContent;
  // Immediate feedback. Without this the button simply dims and the UI
  // looks frozen for however long the round trip takes.
  btn.disabled = true; btn.textContent = 'Placing\u2026';
  const kind = $('#o-kind').value;
  const body = {
    symbol: state.symbol, side: state.side, kind,
    quantity: Number($('#o-qty').value), tif: $('#o-tif').value,
  };
  if (!$('#wrap-limit').hidden)   body.limit_price = Number($('#o-limit').value);
  if (!$('#wrap-stop').hidden)    body.stop_price  = Number($('#o-stop').value);
  if (!$('#wrap-trail').hidden)   body.trail_pct   = Number($('#o-trail').value);
  if (!$('#wrap-display').hidden) body.display_qty = Number($('#o-display').value);

  try {
    const r = await api('/orders', { method: 'POST', body: JSON.stringify(body) });
    if (r.status === 'rejected') {
      // A risk rejection is a normal business outcome, not an error --
      // the reason text comes straight from risk.pretrade_check().
      toast('Order rejected by pre-trade risk', r.reject_reason, 'err');
    } else if (num(r.filled_qty) > 0) {
      toast(`${body.side.toUpperCase()} ${qty(r.filled_qty)} ${body.symbol} filled`,
            `avg ${price(r.avg_fill_price, body.symbol)} · ${r.fills.length} fill(s) · ${r.status}`,
            'ok');
    } else {
      toast(`Order ${r.status}`, `#${r.order_id} resting on the book`, 'info');
    }
    // Re-enable immediately: the order is already decided. The panel
    // refreshes are cosmetic and must not hold the ticket hostage.
    btn.disabled = false; btn.textContent = label;
    Promise.all([loadBook(), loadBlotter(), loadBuyingPower()])
           .catch(e => console.error('refresh after order failed:', e));
  } catch (err) {
    toast('Order failed', err.message, 'err');
    btn.disabled = false; btn.textContent = label;
  }
});

async function loadBuyingPower() {
  try {
    const s = await api('/portfolio/summary');
    const B = s.base_currency || state.baseCcy;
    state.baseCcy = B;
    $('#bp-line').textContent =
      `buying power ${moneyIn(s.buying_power, B)} · cash ${moneyIn(s.cash, B)} · ` +
      `NAV ${moneyIn(s.nav, B)}${num(s.committed_to_open_orders) > 0
        ? ` · ${moneyIn(s.committed_to_open_orders, B)} committed` : ''}` +
      `${s.allow_short_selling ? '' : ' · shorting off'}`;
  } catch {}
}

/* ---------------------------------------------------------------- blotter */
$$('#blotter-tabs button').forEach(b => b.onclick = () => {
  state.tab = b.dataset.tab;
  $$('#blotter-tabs button').forEach(x => x.classList.toggle('active', x === b));
  loadBlotter();
});

function table(cols, rows, rowFn) {
  if (!rows.length) return `<div class="empty">Nothing to show</div>`;
  return `<table><thead><tr>${cols.map(c => `<th>${esc(c)}</th>`).join('')}</tr></thead>
    <tbody>${rows.map(rowFn).join('')}</tbody></table>`;
}

/*
  Remember what the visible table holds so the export button writes the
  rows that are on screen rather than firing a second, differently
  filtered query.
*/
function recordTable(name, rows, cols) {
  state.lastTable = { name, rows, cols };
}

async function loadBlotter() {
  const host = $('#blotter-body');
  try {
    if (state.tab === 'orders') {
      const d = await api('/orders?open_only=true&limit=200');
      $('#c-orders').textContent = d.length || '';
      recordTable('orders', d, ['order_id', 'symbol', 'side', 'kind', 'tif', 'quantity',
                                'filled_qty', 'leaves_qty', 'limit_price', 'stop_price',
                                'status', 'placed_at']);
      host.innerHTML = table(
        ['Symbol', 'Side', 'Type', 'TIF', 'Qty', 'Filled', 'Leaves', 'Limit', 'Stop', 'Status', 'Placed', ''],
        d, o => `<tr>
          <td class="sym">${esc(o.symbol)}</td>
          <td class="${o.side === 'buy' ? 'up' : 'down'}">${esc(o.side)}</td>
          <td class="dim">${esc(o.kind)}</td><td class="dim">${esc(o.tif)}</td>
          <td>${qty(o.quantity)}</td><td>${qty(o.filled_qty)}</td>
          <td>${qty(o.leaves_qty)}</td>
          <td>${o.limit_price ? price(o.limit_price, o.symbol) : '—'}</td>
          <td>${o.stop_price ? price(o.stop_price, o.symbol) + (o.stop_armed ? ' ⏳' : '') : '—'}</td>
          <td><span class="pill ${esc(o.status)}">${esc(o.status)}</span></td>
          <td class="dim">${time(o.placed_at)}</td>
          <td><button class="x-btn" data-cancel="${o.order_id}">cancel</button></td>
        </tr>`);
      $$('[data-cancel]', host).forEach(b => b.onclick = async () => {
        try {
          await api(`/orders/${b.dataset.cancel}`, { method: 'DELETE' });
          toast('Order cancelled', `#${b.dataset.cancel}`, 'ok');
          await Promise.all([loadBlotter(), loadBook(), loadBuyingPower()]);
        } catch (e) { toast('Cancel failed', e.message, 'err'); }
      });

    } else if (state.tab === 'positions') {
      const d = await api('/portfolio/positions');
      $('#c-positions').textContent = d.length || '';
      recordTable('positions', d, ['symbol', 'name', 'quantity', 'avg_cost', 'mark_price',
                                   'market_value', 'unrealized_pnl', 'unrealized_pct',
                                   'realized_pnl', 'pct_of_holdings']);
      host.innerHTML = table(
        ['Symbol', 'Name', 'Qty', 'Avg cost', 'Mark', 'Value', 'Unrealised', '%', 'Realised', '% of book'],
        d, p => `<tr>
          <td class="sym">${esc(p.symbol)}</td><td class="txt dim">${esc(p.name)}</td>
          <td>${qty(p.quantity)}</td><td>${price(p.avg_cost, p.symbol)}</td>
          <td>${price(p.mark_price, p.symbol)}</td><td>${money(p.market_value)}</td>
          <td class="${cls(p.unrealized_pnl)}">${money(p.unrealized_pnl)}</td>
          <td class="${cls(p.unrealized_pct)}">${pct(p.unrealized_pct)}</td>
          <td class="${cls(p.realized_pnl)}">${money(p.realized_pnl)}</td>
          <td class="dim">${fmt(p.pct_of_holdings, 1)}%</td>
        </tr>`);

    } else if (state.tab === 'fills') {
      const d = await api('/portfolio/blotter?limit=200');
      $('#c-fills').textContent = d.length || '';
      recordTable('fills', d, ['executed_at', 'symbol', 'side', 'quantity', 'price',
                               'notional', 'fee', 'cash_flow', 'was_aggressor']);
      host.innerHTML = table(
        ['Time', 'Symbol', 'Side', 'Qty', 'Price', 'Notional', 'Fee', 'Cash flow', 'Role'],
        d, f => `<tr>
          <td class="dim">${time(f.executed_at)}</td>
          <td class="sym">${esc(f.symbol)}</td>
          <td class="${f.side === 'buy' ? 'up' : 'down'}">${esc(f.side)}</td>
          <td>${qty(f.quantity)}</td><td>${price(f.price, f.symbol)}</td>
          <td>${money(f.notional)}</td><td class="dim">${money(f.fee, 4)}</td>
          <td class="${cls(f.cash_flow)}">${money(f.cash_flow)}</td>
          <td class="dim">${f.was_aggressor ? 'taker' : 'maker'}</td>
        </tr>`);

    } else if (state.tab === 'tape') {
      const d = await api(`/market/trades/${state.symbol}?limit=150`);
      recordTable(`${state.symbol}-tape`, d,
                  ['executed_at', 'price', 'quantity', 'aggressor_side']);
      host.innerHTML = table(['Time', 'Price', 'Size', 'Aggressor'], d, t => `<tr>
          <td class="dim">${time(t.executed_at)}</td>
          <td class="${t.aggressor_side === 'buy' ? 'up' : 'down'}">${price(t.price)}</td>
          <td>${qty(t.quantity)}</td>
          <td class="dim">${esc(t.aggressor_side)}</td></tr>`);

    } else if (state.tab === 'ledger') {
      const d = await api('/portfolio/ledger?limit=200');
      recordTable('ledger', d, ['occurred_at', 'entry_id', 'entry_kind', 'asset_class',
                                'symbol', 'amount', 'description']);
      host.innerHTML = table(
        ['When', 'Entry', 'Kind', 'Asset', 'Symbol', 'Amount', 'Description'],
        d, l => `<tr>
          <td class="dim">${date(l.occurred_at)} ${time(l.occurred_at)}</td>
          <td class="dim">#${l.entry_id}</td>
          <td class="dim">${esc(l.entry_kind)}</td>
          <td class="dim">${esc(l.asset_class)}</td>
          <td class="sym">${esc(l.symbol || '—')}</td>
          <td class="${cls(l.amount)}">${fmt(l.amount, 4)}</td>
          <td class="txt dim" style="text-align:left">${esc(l.description)}</td>
        </tr>`);

    } else if (state.tab === 'watchlist') {
      await loadWatchlist();
      const d = state.watchlist?.items || [];
      recordTable('watchlist', d, ['symbol', 'name', 'kind', 'sector', 'currency',
                                   'last_price', 'change_pct', 'day_volume', 'note']);
      host.innerHTML = !d.length
        ? `<div class="empty">Nothing starred yet. Press <b>☆</b> above the chart,
             or <b>w</b> on the keyboard, to follow an instrument.</div>`
        : table(['Symbol', 'Name', 'Class', 'Last', 'Change', 'Bid', 'Ask', 'Volume', 'Session', ''],
            d, w => `<tr data-sym="${esc(w.symbol)}" style="cursor:pointer">
              <td class="sym">${esc(w.symbol)}</td>
              <td class="txt dim">${esc(w.name)}</td>
              <td class="dim">${esc(w.kind)}</td>
              <td>${price(w.last_price, w.symbol)}</td>
              <td class="${cls(w.change_pct)}">${pct(w.change_pct)}</td>
              <td class="up">${price(w.bid, w.symbol)}</td>
              <td class="down">${price(w.ask, w.symbol)}</td>
              <td class="dim">${compact(w.day_volume)}</td>
              <td>${w.trades_24x7
                     ? '<span class="badge c24">24×7</span>'
                     : `<span class="badge ${w.market_open ? 'open' : 'closed'}">${
                          w.market_open ? 'open' : 'closed'}</span>`}</td>
              <td><button class="x-btn" data-unstar="${esc(w.symbol)}">remove</button></td>
            </tr>`);
      $$('[data-sym]', host).forEach(tr => tr.onclick = ev => {
        if (ev.target.dataset.unstar) return;
        selectSymbol(tr.dataset.sym);
      });
      $$('[data-unstar]', host).forEach(b => b.onclick = ev => {
        ev.stopPropagation();
        toggleWatch(b.dataset.unstar);
      });

    } else if (state.tab === 'alerts') {
      await loadAlerts();
      const d = state.alerts;
      recordTable('alerts', d, ['alert_id', 'symbol', 'kind', 'threshold', 'reference_price',
                                'last_price', 'distance', 'is_active', 'fire_count',
                                'last_fired_at', 'note']);
      const fires = state.alertFires.slice(0, 8);
      host.innerHTML = (!d.length
        ? `<div class="empty">No alerts. Press <b>🔔</b> above the chart, or <b>a</b> on the
             keyboard, to watch a level. Alerts are evaluated in SQL on every ingestion
             cycle and pushed over the same LISTEN/NOTIFY channel as fills.</div>`
        : table(['Symbol', 'Condition', 'Threshold', 'Last', 'Distance', 'State', 'Fired', 'Note', ''],
            d, a => `<tr>
              <td class="sym">${esc(a.symbol)}</td>
              <td class="dim">${esc({ above: 'rises above', below: 'falls below',
                                      pct_move_up: 'rises by', pct_move_down: 'falls by' }[a.kind] || a.kind)}</td>
              <td>${a.kind.startsWith('pct_move') ? fmt(a.threshold, 2) + '%'
                                                  : price(a.threshold, a.symbol)}</td>
              <td>${price(a.last_price, a.symbol)}</td>
              <td class="al-dist ${cls(a.distance)}">${a.distance != null
                    ? (num(a.distance) >= 0 ? '+' : '') + fmt(a.distance, 2) : '—'}</td>
              <td><span class="al-state ${alertState(a)}">${alertState(a)}</span></td>
              <td class="dim">${a.fire_count || 0}${a.last_fired_at
                    ? ` · ${time(a.last_fired_at)}` : ''}</td>
              <td class="txt dim" style="text-align:left">${esc(a.note || '')}</td>
              <td><button class="x-btn" data-rmalert="${a.alert_id}">remove</button></td>
            </tr>`))
        + (!fires.length ? '' : `
            <div class="sr-group">Recent fires</div>
            ${fires.map(f => `<div class="hc-row">
                <span class="st PASS">fired</span>
                <span class="nm">${esc(f.symbol || f.detail?.symbol || '')}
                  at ${price(f.price, f.symbol)}</span>
                <span class="dt">${date(f.fired_at)} ${time(f.fired_at)}</span>
              </div>`).join('')}`);
      $$('[data-rmalert]', host).forEach(b =>
        b.onclick = () => removeAlert(Number(b.dataset.rmalert)));
    }
  } catch (e) { host.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}

/* ---------------------------------------------------------------- symbol */
async function selectSymbol(sym) {
  state.symbol = sym;
  $$('#tape .tape-item').forEach(el => el.classList.toggle('sel', el.dataset.sym === sym));
  renderStar();
  // The ticket's step sizes and default clip depend on the instrument,
  // not on whatever was selected before it.
  syncTicketMicro();
  const results = await Promise.allSettled(
    [loadQuote(), loadBook(), loadChart(), loadBuyingPower()]);
  results.filter(r => r.status === 'rejected')
         .forEach(r => console.error('panel failed:', r.reason));
  loadBlotter();
  $('#o-stop').value = '';
  applyDefaultPrice();
  syncTicketFields();
}

async function loadQuote() {
  try { state.quote = await api(`/market/quote/${state.symbol}`); renderQuote(); } catch {}
}
async function loadBook() {
  try { state.book = await api(`/market/book/${state.symbol}?depth=12`); renderBook(); } catch {}
}

async function refreshLight() {
  if (!$('#view-trade').classList.contains('active')) return;
  try {
    state.instruments = await api('/market/instruments');
    renderTape();
  } catch {}
  if (state.tab === 'watchlist' || state.tab === 'alerts') loadBlotter();
  await Promise.all([loadQuote(), loadBook()]);
}

/* ---------------------------------------------------------------- websocket */
function connectWS() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const ws = new WebSocket(`${proto}://${location.host}/ws/stream`);
  state.ws = ws;

  ws.onopen = async () => {
    $('#live').classList.add('on');
    $('#live-text').textContent = 'live';
    // Say which feed is actually behind these prices. If the configured
    // provider died and the worker fell back to the simulator, the badge
    // must not keep claiming a live market feed.
    try {
      const h = await (await fetch('/api/health')).json();
      $('#live-text').textContent = h.degraded ? 'simulated' : `live · ${h.feed}`;
      $('#live').title = h.degraded
        ? 'The configured market-data provider stopped responding; '
          + 'prices are being generated by the built-in simulator.'
        : `Market data: ${h.feed}`;
      if (h.degraded) $('#live').classList.add('degraded');
    } catch {}
    setInterval(() => { if (ws.readyState === 1) ws.send('ping'); }, 25000);
  };
  ws.onclose = () => {
    $('#live').classList.remove('on');
    $('#live-text').textContent = 'reconnecting';
    setTimeout(connectWS, 4000);
  };
  ws.onmessage = ev => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    // These events originate from pg_notify() inside the same
    // transaction that wrote the execution, so anything arriving here
    // has definitely committed.
    if (m.type === 'execution') {
      const inst = state.instruments.find(i => i.instrument_id === m.instrument_id);
      if (inst && inst.symbol === state.symbol) { loadQuote(); loadBook(); }
    } else if (m.type === 'book') {
      const inst = state.instruments.find(i => i.instrument_id === m.instrument_id);
      if (inst && inst.symbol === state.symbol) loadBook();
    } else if (m.type === 'halt') {
      const inst = state.instruments.find(i => i.instrument_id === m.instrument_id);
      toast('Trading halted', `${inst?.symbol || m.instrument_id} moved ${m.move_pct}%`, 'err');
    } else if (m.type === 'stop_elected') {
      toast('Stop order elected', `order #${m.order_id} triggered at ${m.trigger_price}`, 'info');
    } else if (m.type === 'price_alert') {
      // Fired by risk.evaluate_price_alerts() inside the ingestion cycle
      // and pushed on the same LISTEN/NOTIFY channel as fills, so the
      // browser needs no second transport and no polling.
      const verb = { above: 'rose above', below: 'fell below',
                     pct_move_up: 'rose by', pct_move_down: 'fell by' }[m.alert_kind]
                 || m.alert_kind;
      const thr = String(m.alert_kind).startsWith('pct_move')
        ? `${fmt(m.threshold, 2)}%` : price(m.threshold, m.symbol);
      toast(`🔔 ${m.symbol} ${verb} ${thr}`,
            `now ${price(m.price, m.symbol)}${m.note ? ` · ${m.note}` : ''}`, 'ok');
      loadAlerts();
      if (state.tab === 'alerts') loadBlotter();
    }
  };
}

/* ---------------------------------------------------------------- portfolio */
async function loadPortfolio() {
  const [s, pos, ec] = await Promise.all([
    api('/portfolio/summary'),
    api('/portfolio/positions'),
    api('/portfolio/equity-curve?days=90'),
  ]);

  // Everything in the summary is denominated in the ACCOUNT's base
  // currency; render it in whatever the viewer selected.
  const B = s.base_currency || state.baseCcy;
  const inB = v => moneyIn(v, B);
  $('#pf-metrics').innerHTML = [
    ['Net asset value', inB(s.nav), `${esc(s.account_no)} · ${esc(s.kind)} · base ${esc(B)}`],
    ['Cash', inB(s.cash), `buying power ${inB(s.buying_power)} · ${s.currencies_held} currencies`],
    ['Securities', inB(s.securities_value), `${s.position_count} positions`],
    ['Unrealised P&L', inB(s.unrealized_pnl), 'mark to market', cls(s.unrealized_pnl)],
    ['Realised P&L', inB(s.realized_pnl), 'closed trades', cls(s.realized_pnl)],
    ['P&L today', inB(s.pnl_today), `cash flow ${inB(s.cash_flow_today)}`, cls(s.pnl_today)],
    ['Open orders', s.open_orders, `${inB(s.committed_to_open_orders)} committed`],
    ['Short selling', s.allow_short_selling ? 'ENABLED' : 'OFF',
      s.allow_short_selling ? 'may hold negative positions' : 'cannot sell more than held',
      s.allow_short_selling ? 'down' : ''],
  ].map(([k, v, d, c]) => `<div class="metric">
      <div class="k">${esc(k)}</div>
      <div class="v ${c || ''}">${v}</div>
      <div class="d">${esc(d)}</div></div>`).join('');

  const st = ec.stats || {};
  $('#pf-stats').innerHTML =
    `total ${pct(st.total_return_pct)} · sharpe ${fmt(st.sharpe_ratio, 2)} · ` +
    `vol ${fmt(st.volatility_pct, 2)}% · maxDD ${fmt(st.max_drawdown_pct, 2)}% · ` +
    `win ${fmt(st.win_rate_pct, 1)}% (${st.win_days}/${st.trading_days}d)`;

  // Equity curve with drawdown underneath.
  const el = $('#equity-chart'); el.innerHTML = '';
  if (typeof LightweightCharts === 'undefined') {
    el.innerHTML = `<div class="empty">Charting library failed to load</div>`;
  } else {
  const ch = LightweightCharts.createChart(el, {
    ...chartTheme(), width: el.clientWidth, height: 280, autoSize: true,
  });
  state.charts.equity = ch;
  const navSeries = ch.addAreaSeries({
    lineColor: '#4d8dff', topColor: 'rgba(77,141,255,.28)',
    bottomColor: 'rgba(77,141,255,.02)', lineWidth: 2,
  });
  navSeries.setData(ec.curve.map(r => ({ time: r.as_of, value: num(r.nav) })));
  const ddSeries = ch.addHistogramSeries({ priceScaleId: 'dd', color: 'rgba(255,77,106,.5)' });
  ch.priceScale('dd').applyOptions({ scaleMargins: { top: 0.78, bottom: 0 } });
  ddSeries.setData(ec.curve.map(r => ({ time: r.as_of, value: num(r.drawdown_pct) || 0 })));
  ch.timeScale().fitContent();
  }

  // The quote currency rides along with the mark rather than taking a
  // column of its own: this card shares a row with two others, and the
  // Value column was being clipped to make room for a word that is the
  // same on almost every line.
  $('#pf-positions').innerHTML = table(
    ['Symbol', 'Qty', 'Avg cost', 'Mark', 'Value', 'Unrealised', '%'],
    pos, p => `<tr><td class="sym">${esc(p.symbol)}</td>
      <td>${qty(p.quantity)}</td>
      <td>${price(p.avg_cost, p.symbol)}</td>
      <td>${price(p.mark_price, p.symbol)}
        <span class="dim" style="font-size:10px">${esc(p.quote_currency)}</span></td>
      <td>${moneyIn(p.market_value, p.quote_currency)}</td>
      <td class="${cls(p.unrealized_pnl)}">${moneyIn(p.unrealized_pnl, p.quote_currency)}</td>
      <td class="${cls(p.unrealized_pct)}">${pct(p.unrealized_pct)}</td></tr>`);

  state.pfRows = pos;
  renderAllocation(pos, s);
  await loadWallet();

  if (!$('#asof-input').value) {
    const d = new Date(Date.now() - 20 * 864e5);
    $('#asof-input').value = d.toISOString().slice(0, 16);
  }
}

/*
  Allocation. Two readings of the same holdings: which asset classes the
  book is in, and how concentrated it is in any one name. Both come from
  the positions already fetched -- the point is to make the shape of the
  portfolio legible, not to add another query.
*/
function renderAllocation(pos, summary) {
  const host = $('#pf-alloc');
  if (!host) return;
  const B = summary.base_currency || state.baseCcy;
  const cash = Math.max(num(summary.cash) || 0, 0);

  const buckets = new Map();
  let invested = 0;
  pos.forEach(p => {
    const inst = state.instruments.find(i => i.symbol === p.symbol);
    const k = inst ? classOf(inst) : 'equity';
    const v = Math.abs(fxConv(num(p.market_value) || 0, p.quote_currency, B));
    invested += v;
    buckets.set(k, (buckets.get(k) || 0) + v);
  });
  buckets.set('cash', cash);
  const total = invested + cash;
  if (!total) { host.innerHTML = `<div class="empty">Nothing held</div>`; return; }

  const LABEL = { equity: 'Stocks', etf: 'ETFs', crypto: 'Crypto', cash: 'Cash' };
  const COLOR = { equity: 'var(--accent)', etf: '#c47dff',
                  crypto: 'var(--warn)', cash: 'var(--up)' };
  const order = ['equity', 'etf', 'crypto', 'cash'].filter(k => buckets.get(k));

  const bar = `<div style="display:flex;height:10px;border-radius:5px;overflow:hidden;
      background:var(--bg);margin-bottom:12px">${
    order.map(k => `<i title="${LABEL[k]} ${fmt(buckets.get(k) / total * 100, 1)}%"
        style="width:${buckets.get(k) / total * 100}%;background:${COLOR[k]}"></i>`).join('')}</div>`;

  const legend = order.map(k => `<div style="display:flex;align-items:center;gap:8px;
      font-size:12px;padding:3px 0">
      <i style="width:9px;height:9px;border-radius:2px;background:${COLOR[k]}"></i>
      <span style="flex:1">${LABEL[k]}</span>
      <b style="font-family:var(--mono)">${moneyIn(buckets.get(k), B)}</b>
      <span class="dim" style="font-family:var(--mono);width:52px;text-align:right"
        >${fmt(buckets.get(k) / total * 100, 1)}%</span></div>`).join('');

  // Concentration. risk.pretrade_check() enforces a per-name cap, so
  // showing the largest position says whether the next buy in that name
  // is about to be refused -- before the ticket finds out.
  const biggest = [...pos].sort((a, b) =>
    Math.abs(num(b.market_value)) - Math.abs(num(a.market_value)))[0];
  const topPct = biggest
    ? Math.abs(fxConv(num(biggest.market_value), biggest.quote_currency, B)) / total * 100
    : 0;

  host.innerHTML = bar + legend + `
    <div style="margin-top:12px;padding-top:10px;border-top:1px solid var(--border);
         font-size:11.5px;color:var(--text-dim);line-height:1.6">
      Largest position <b style="color:var(--text)">${esc(biggest?.symbol || '—')}</b>
      at <b style="color:var(--text)">${fmt(topPct, 1)}%</b> of the book.
      ${order.includes('crypto') ? `Digital assets are
        <b style="color:var(--text)">${fmt((buckets.get('crypto') || 0) / total * 100, 1)}%</b>
        &mdash; they carry wider price bands (30&ndash;50% against 20% for equities)
        and never close.` : ''}
    </div>`;
}

async function loadWallet() {
  const d = await api('/portfolio/currencies');
  state.baseCcy = d.base_currency;
  $('#wallet-base').textContent = `base ${d.base_currency}`;
  // Only show the display column when it differs from the base, or the
  // table repeats the same number twice under two headings.
  const showDisplay = state.displayCcy !== d.base_currency;
  const cols = ['Currency', 'Balance', `In ${d.base_currency}`];
  if (showDisplay) cols.push(`In ${state.displayCcy}`);
  $('#wallet').innerHTML = table(cols, d.holdings, h => `<tr>
      <td class="sym">${esc(h.symbol)} ${esc(h.currency)}</td>
      <td>${money(h.balance, 2, h.currency)}</td>
      <td class="dim">${money(h.in_base, 2, d.base_currency)}</td>
      ${showDisplay ? `<td>${moneyIn(h.balance, h.currency)}</td>` : ''}</tr>`);

  const opts = Object.keys(state.fx).map(c =>
    `<option value="${esc(c)}">${esc(state.ccyMeta[c]?.symbol || '')} ${esc(c)}</option>`).join('');
  const held = d.holdings.map(h => h.currency);
  $('#fx-from').innerHTML = opts;
  $('#fx-to').innerHTML = opts;
  $('#fx-from').value = held[0] || d.base_currency;
  $('#fx-to').value = held.find(c => c !== $('#fx-from').value)
                      || (d.base_currency === 'USD' ? 'INR' : 'USD');
  previewFx();
}

function previewFx() {
  const amt = num($('#fx-amount').value);
  const from = $('#fx-from').value, to = $('#fx-to').value;
  if (!isFinite(amt) || !from || !to || from === to) { $('#fx-preview').textContent = ''; return; }
  const rate = num(state.fx[to]) / num(state.fx[from]);
  $('#fx-preview').textContent =
    `${money(amt, 2, from)} → ${money(amt * rate, 2, to)}  ·  1 ${from} = ${fmt(rate, 6)} ${to}`;
}
['#fx-amount', '#fx-from', '#fx-to'].forEach(sel => {
  const el = $(sel); if (el) { el.oninput = previewFx; el.onchange = previewFx; }
});

$('#fx-go').onclick = async () => {
  const amt = Number($('#fx-amount').value);
  const from = $('#fx-from').value, to = $('#fx-to').value;
  if (!(amt > 0) || from === to) { toast('Nothing to convert', '', 'err'); return; }
  try {
    const r = await api('/portfolio/convert', { method: 'POST', body: JSON.stringify({
      from_currency: from, to_currency: to, amount: amt }) });
    toast('Currency converted',
          `${money(amt, 2, from)} → ${money(r.amount_to, 2, to)} at ${fmt(r.rate, 6)}`, 'ok');
    $('#fx-amount').value = '';
    await loadPortfolio();
  } catch (e) { toast('Conversion failed', e.message, 'err'); }
};

$('#asof-btn').onclick = async () => {
  const v = $('#asof-input').value;
  if (!v) return;
  try {
    const d = await api(`/portfolio/as-of?at=${encodeURIComponent(new Date(v).toISOString())}`);
    $('#asof-result').innerHTML = table(['Asset', 'Symbol / currency', 'Balance'], d.holdings,
      h => `<tr><td class="dim">${esc(h.asset_class)}</td>
        <td class="sym">${esc(h.symbol || (h.currency + ' cash'))}</td>
        <td>${h.asset_class === 'cash'
              ? money(h.balance, 2, h.currency) : fmt(h.balance, 2)}</td></tr>`);
  } catch (e) { toast('Reconstruction failed', e.message, 'err'); }
};

/* ---------------------------------------------------------------- history */
$$('#hist-filter button').forEach(b => b.onclick = () => {
  $$('#hist-filter button').forEach(x => x.classList.toggle('active', x === b));
  state.histKind = b.dataset.kind;
  loadHistory();
});
['#hist-symbol', '#hist-days'].forEach(sel => {
  const el = $(sel);
  if (el) { el.onchange = loadHistory; el.oninput = () => { clearTimeout(el._t);
    el._t = setTimeout(loadHistory, 350); }; }
});

async function loadHistory() {
  const host = $('#history-table');
  const params = new URLSearchParams({
    kind: state.histKind,
    days: $('#hist-days')?.value || '90',
    limit: '400',
  });
  const sym = ($('#hist-symbol')?.value || '').trim();
  if (sym) params.set('symbol', sym);

  try {
    const rows = await api(`/portfolio/history?${params}`);
    state.histRows = rows;
    let running = 0;
    host.innerHTML = table(
      ['When', 'Action', 'Symbol', 'Qty', 'Price', 'Fee', 'Amount', `In ${state.displayCcy}`, 'Entry'],
      rows, r => {
        const isTrade = r.action === 'buy' || r.action === 'sell';
        const flow = num(r.cash_flow);
        running += fxConv(flow, r.currency);
        const label = isTrade
          ? `<span class="${r.action === 'buy' ? 'up' : 'down'}">${esc(r.action)}</span>`
          : `<span class="pill">${esc((r.action || '').replace(/_/g, ' '))}</span>`;
        return `<tr>
          <td class="dim">${date(r.at)} ${time(r.at)}</td>
          <td>${label}</td>
          <td class="sym">${esc(r.symbol || '—')}</td>
          <td>${r.quantity ? qty(r.quantity) : '—'}</td>
          <td>${r.price ? price(r.price, r.symbol) : '—'}</td>
          <td class="dim">${r.fee ? money(r.fee, 4, r.currency) : '—'}</td>
          <td class="${cls(flow)}">${money(flow, 2, r.currency)}</td>
          <td class="${cls(flow)}">${moneyIn(flow, r.currency)}</td>
          <td class="dim">#${r.entry_id ?? '—'}</td>
        </tr>`;
      });
    if (!rows.length) host.innerHTML = `<div class="empty">No activity in this period</div>`;
  } catch (e) { host.innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}

/* ---------------------------------------------------------------- markets */
async function loadMarkets() {
  const [movers, sectors, fx] = await Promise.all([
    api('/market/movers'), api('/market/sectors'), api('/market/fx'),
  ]);

  // The movers endpoint ranks the whole universe. Filtering client-side
  // keeps one ranking -- a crypto "top gainer" tab that re-ranked only
  // crypto would disagree with the all-assets tab about the same name.
  const byClass = rows => state.mkClass === 'all' ? rows
    : rows.filter(m => classOf(m) === state.mkClass);

  const moverTable = rows => table(
    ['Symbol', 'Name', 'Last', 'Change', 'Volume'], rows, m => `<tr>
      <td class="sym"><a href="#" data-goto="${esc(m.symbol)}"
          style="color:var(--accent);text-decoration:none">${esc(m.symbol)}</a>
        ${m.kind === 'crypto' ? '<span class="badge c24">24×7</span>' : ''}</td>
      <td class="txt dim">${esc(m.name)}</td>
      <td>${price(m.last_price, m.symbol)}</td>
      <td class="${cls(m.change_pct)}">${pct(m.change_pct)}</td>
      <td class="dim">${compact(m.day_volume)}</td></tr>`);

  $('#mk-gainers').innerHTML = moverTable(byClass(movers.gainers));
  $('#mk-losers').innerHTML  = moverTable(byClass(movers.losers));
  $('#mk-active').innerHTML  = moverTable(byClass(movers.most_active));
  state.mkRows = [...movers.gainers, ...movers.losers, ...movers.most_active];

  // The crypto board. Separate from the movers because the interesting
  // columns are different: a coin's tick size and session rule matter,
  // and "is the market open" is always yes.
  const coins = state.instruments.filter(i => i.kind === 'crypto');
  $('#mk-crypto').innerHTML = !coins.length
    ? `<div class="empty">No digital assets listed</div>`
    : table(['Symbol', 'Name', 'Last', 'Change', 'Bid', 'Ask', 'Tick', 'Min size', 'Band', 'Session'],
        coins, i => `<tr>
          <td class="sym"><a href="#" data-goto="${esc(i.symbol)}"
              style="color:var(--accent);text-decoration:none">${esc(i.symbol)}</a></td>
          <td class="txt dim">${esc(i.name)}</td>
          <td>${price(i.last_price, i.symbol)}</td>
          <td class="${cls(i.change_pct)}">${pct(i.change_pct)}</td>
          <td class="up">${price(i.bid, i.symbol)}</td>
          <td class="down">${price(i.ask, i.symbol)}</td>
          <td class="dim">${esc(String(i.tick_size).replace(/0+$/, ''))}</td>
          <td class="dim">${esc(String(i.lot_size).replace(/0+$/, ''))}</td>
          <td class="dim">±${fmt(i.price_band_pct, 0)}%</td>
          <td><span class="badge c24">24×7</span></td></tr>`);

  $('#mk-sectors').innerHTML = table(
    ['Sector', 'Names', 'Avg change', 'Volume', 'Mkt cap'],
    sectors, s => `<tr>
      <td class="txt">${esc(s.sector || '—')}</td>
      <td class="dim">${s.instruments}</td>
      <td class="${cls(s.avg_change_pct)}">${pct(s.avg_change_pct)}</td>
      <td class="dim">${compact(s.volume)}</td>
      <td class="dim">$${fmt(s.mcap_bn, 1)}B</td></tr>`);

  $('#mk-fx').innerHTML = table(
    ['Currency', 'Code', 'Per 1 USD', '1 unit in USD', 'Decimals', 'Updated'],
    fx, f => `<tr>
      <td class="txt">${esc(f.symbol)} ${esc(f.name)}</td>
      <td class="sym">${esc(f.code)}</td>
      <td>${fmt(f.per_usd, 4)}</td>
      <td class="dim">${fmt(f.in_usd, 6)}</td>
      <td class="dim">${f.minor_units}</td>
      <td class="dim">${f.last_updated ? date(f.last_updated) : '—'}</td></tr>`);

  // Clicking a symbol jumps to the trading view for it.
  $$('[data-goto]').forEach(a => a.onclick = ev => {
    ev.preventDefault();
    $$('nav button').find(b => b.dataset.view === 'trade')?.click();
    selectSymbol(a.dataset.goto);
  });
}

$$('#mk-class button').forEach(b => b.onclick = () => {
  $$('#mk-class button').forEach(x => x.classList.toggle('active', x === b));
  state.mkClass = b.dataset.class;
  loadMarkets();
});

/* ---------------------------------------------------------------- social */
async function loadSocial() {
  const [lb, mine] = await Promise.all([
    api('/social/leaderboard'), api('/social/strategies'),
  ]);
  $('#leaderboard').innerHTML = table(
    ['#', 'Strategy', 'Leader', 'Avg daily', 'Volatility', 'Sharpe', 'Max DD', 'Win rate', 'Days', 'Fills', 'Copiers', 'Fee', ''],
    lb, s => `<tr>
      <td class="dim">${s.sharpe_rank}</td>
      <td class="txt"><b>${esc(s.name)}</b></td>
      <td class="txt dim">${esc(s.owner_name)}</td>
      <td class="${cls(s.avg_daily_return_pct)}">${pct(s.avg_daily_return_pct, 3)}</td>
      <td class="dim">${fmt(s.volatility_pct, 2)}%</td>
      <td class="${cls(s.sharpe_ratio)}">${fmt(s.sharpe_ratio, 2)}</td>
      <td class="down">${fmt(s.max_drawdown_pct, 2)}%</td>
      <td>${fmt(s.win_rate_pct, 1)}%</td>
      <td class="dim">${s.trading_days}</td><td class="dim">${s.total_fills}</td>
      <td>${s.active_copiers}</td>
      <td class="dim">${fmt(s.fee_bps, 0)} bps</td>
      <td><button class="x-btn" data-sub="${s.strategy_id}" style="border-color:var(--accent);color:var(--accent)">copy</button></td>
    </tr>`);

  $$('[data-sub]').forEach(b => b.onclick = async () => {
    try {
      await api('/social/subscribe', { method: 'POST', body: JSON.stringify({
        strategy_id: Number(b.dataset.sub), allocation_pct: 25, max_trade_notional: 10000 }) });
      toast('Subscribed', 'Leader fills will now mirror into your account', 'ok');
      loadSocial();
    } catch (e) { toast('Subscribe failed', e.message, 'err'); }
  });

  $('#my-subs').innerHTML = table(
    ['Strategy', 'Leader', 'Allocation', 'Max per trade', 'Fee', 'Status', 'Since', ''],
    mine.subscriptions, s => `<tr>
      <td class="txt"><b>${esc(s.name)}</b></td><td class="txt dim">${esc(s.leader)}</td>
      <td>${fmt(s.allocation_pct, 0)}%</td><td>${money(s.max_trade_notional, 0)}</td>
      <td class="dim">${fmt(s.fee_bps, 0)} bps</td>
      <td><span class="pill">${esc(s.status)}</span></td>
      <td class="dim">${date(s.subscribed_at)}</td>
      <td><button class="x-btn" data-unsub="${s.subscription_id}">stop</button></td>
    </tr>`);

  $$('[data-unsub]').forEach(b => b.onclick = async () => {
    try {
      await api(`/social/subscribe/${b.dataset.unsub}`, { method: 'DELETE' });
      toast('Unsubscribed', '', 'ok'); loadSocial();
    } catch (e) { toast('Failed', e.message, 'err'); }
  });
}

/* ---------------------------------------------------------------- compliance */
async function loadCompliance() {
  try {
    const [alerts, hc] = await Promise.all([
      api('/admin/alerts?state=all&limit=100'), api('/admin/health'),
    ]);

    const bySev = s => alerts.filter(a => a.severity === s).length;
    $('#cp-metrics').innerHTML = [
      ['Open alerts', alerts.filter(a => a.state === 'open').length, 'awaiting review'],
      ['Critical', bySev('critical'), 'wash trading / self-match', bySev('critical') ? 'down' : ''],
      ['High', bySev('high'), 'layering, momentum ignition'],
      ['Invariants', hc.all_passing ? 'ALL PASS' : 'FAILING',
        `${hc.checks.length} checks`, hc.all_passing ? 'up' : 'down'],
    ].map(([k, v, d, c]) => `<div class="metric"><div class="k">${esc(k)}</div>
       <div class="v ${c || ''}">${v}</div><div class="d">${esc(d)}</div></div>`).join('');

    $('#healthcheck').innerHTML = hc.checks.map(c => `<div class="hc-row">
        <span class="st ${esc(c.status)}">${esc(c.status)}</span>
        <span class="nm">${esc(c.check_name)}</span>
        <span class="dt">${esc(c.detail)}</span></div>`).join('');

    $('#alerts').innerHTML = table(
      ['Detected', 'Rule', 'Severity', 'Account', 'Holder', 'Symbol', 'Score', 'State', 'Evidence'],
      alerts, a => `<tr>
        <td class="dim">${date(a.detected_at)} ${time(a.detected_at)}</td>
        <td class="txt"><b>${esc(a.rule_name)}</b><br><span class="dim" style="font:10px var(--mono)">${esc(a.rule_code)}</span></td>
        <td><span class="pill ${esc(a.severity)}">${esc(a.severity)}</span></td>
        <td>${esc(a.account_no || '—')}</td>
        <td class="txt dim">${esc(a.account_holder || '—')}</td>
        <td class="sym">${esc(a.symbol || '—')}</td>
        <td>${fmt(a.score, 1)}</td>
        <td><span class="pill">${esc(a.state)}</span></td>
        <td><details><summary style="cursor:pointer;color:var(--accent)">view</summary>
            <div class="evidence">${esc(JSON.stringify(a.evidence, null, 2))}</div></details></td>
      </tr>`);
  } catch (e) {
    $('#alerts').innerHTML = `<div class="empty">${esc(e.message)}</div>`;
  }
}

$('#hc-refresh').onclick = loadCompliance;

async function runOp(label, path, body) {
  const out = $('#ops-out'); out.style.display = 'block'; out.textContent = `running ${label}…`;
  try {
    const r = await api(path, { method: 'POST', body: body ? JSON.stringify(body) : undefined });
    out.textContent = JSON.stringify(r, null, 2);
    toast(`${label} complete`, '', 'ok');
    loadCompliance();
  } catch (e) { out.textContent = e.message; toast(`${label} failed`, e.message, 'err'); }
}
$('#scan-btn').onclick = () => runOp('Surveillance scan', '/admin/surveillance/scan');
$('#copy-btn').onclick = () => runOp('Copy queue drain', '/admin/ops/process-copy-queue');
$('#eod-btn').onclick  = () => runOp('End-of-day batch', '/admin/ops/end-of-day');

/* ---------------------------------------------------------------- about */
/* ================================================================== search
   Two sources, one list.

   The LOCAL half queries reference.instrument with pg_trgm similarity, so
   "aple" finds AAPL. The REMOTE half asks the market-data provider, which
   knows about every symbol in the world, not only the ones this venue
   lists. A remote-only hit can be imported on the spot: POST /market/import
   creates the instrument with microstructure appropriate to its asset
   class -- a coin gets a sub-cent tick and a fractional lot, an equity
   gets a cent tick and a whole-share lot -- then backfills its history so
   the chart is not empty when you land on it.
   ================================================================== */
function openSearch(prefill = '') {
  const m = $('#search-modal');
  m.hidden = false;
  state.search.open = true;
  const inp = $('#search-input');
  inp.value = prefill;
  inp.focus();
  inp.select();
  renderSearch([], 'Type at least two characters');
  if (prefill.length >= 2) runSearch(prefill);
}

function closeSearch() {
  $('#search-modal').hidden = true;
  state.search.open = false;
}

function renderSearch(rows, note = '') {
  state.search.rows = rows;
  if (state.search.cur >= rows.length) state.search.cur = 0;
  const host = $('#search-results');
  if (!rows.length) {
    host.innerHTML = `<div class="empty" style="padding:26px">${esc(note || 'No matches')}</div>`;
    return;
  }
  const group = (label, set) => !set.length ? '' :
    `<div class="sr-group">${esc(label)}</div>` + set.map(r => `
      <div class="sr-row ${r._i === state.search.cur ? 'cur' : ''}" data-i="${r._i}">
        <span class="s">${esc(r.symbol)}</span>
        <span class="n">${esc(r.name || '')}${r.exchange ? ` · ${esc(r.exchange)}` : ''}
          ${r.kind === 'crypto' ? '<span class="badge c24">24×7</span>' : ''}</span>
        <span class="px ${cls(r.change_pct)}">${r.last_price != null
            ? price(r.last_price, r.symbol) + (r.change_pct != null
                ? ` <span class="${cls(r.change_pct)}">${pct(r.change_pct)}</span>` : '')
            : ''}</span>
        <span class="act ${r.listed ? 'listed' : ''}">${r.listed ? 'open' : '+ list it'}</span>
      </div>`).join('');

  rows.forEach((r, i) => { r._i = i; });
  host.innerHTML = group('Listed on this venue', rows.filter(r => r.listed)) +
                   group('Available from the data provider', rows.filter(r => !r.listed));
  $$('.sr-row', host).forEach(el => {
    el.onclick = ev => pickSearch(Number(el.dataset.i), ev.shiftKey);
    el.onmouseenter = () => { state.search.cur = Number(el.dataset.i); highlightSearch(); };
  });
  highlightSearch();
}

function highlightSearch() {
  $$('.sr-row').forEach(el =>
    el.classList.toggle('cur', Number(el.dataset.i) === state.search.cur));
  const el = $(`.sr-row.cur`);
  if (el) el.scrollIntoView({ block: 'nearest' });
}

let searchTimer = null;
function onSearchInput() {
  const q = $('#search-input').value.trim();
  clearTimeout(searchTimer);
  if (q.length < 2) { renderSearch([], 'Type at least two characters'); return; }
  // Debounced: the remote leg is a network call to the data provider, and
  // firing one per keystroke is how you get rate limited.
  searchTimer = setTimeout(() => runSearch(q), 220);
}

async function runSearch(q) {
  const seq = ++state.search.seq;
  $('#search-hint').textContent = 'searching…';
  try {
    const rows = await api(`/market/search?q=${encodeURIComponent(q)}`);
    // A slow earlier request must not overwrite a newer result.
    if (seq !== state.search.seq) return;
    $('#search-hint').textContent = `${rows.length} match${rows.length === 1 ? '' : 'es'}`;
    $('#search-src').textContent =
      rows.some(r => !r.listed) ? 'local + provider' : 'local universe';
    renderSearch(rows, `Nothing matches “${q}”`);
  } catch (e) {
    if (seq !== state.search.seq) return;
    $('#search-hint').textContent = '';
    renderSearch([], e.message);
  }
}

async function pickSearch(i, forceImport = false) {
  const r = state.search.rows[i];
  if (!r) return;
  if (r.listed && !forceImport) {
    closeSearch();
    state.assetClass = 'all';
    $$('#class-seg button').forEach(x => x.classList.toggle('active', x.dataset.class === 'all'));
    await selectSymbol(r.symbol);
    renderTape();
    return;
  }
  $('#search-hint').textContent = `listing ${r.symbol}…`;
  try {
    const res = await api('/market/import', {
      method: 'POST',
      body: JSON.stringify({ symbol: r.symbol }),
    });
    toast('Listed on this venue', `${r.symbol} — ${res.candles_backfilled || 0} bars of history`, 'ok');
    closeSearch();
    state.instruments = await api('/market/instruments');
    renderTape();
    await selectSymbol(r.symbol);
  } catch (e) {
    $('#search-hint').textContent = '';
    toast(`Could not list ${r.symbol}`, e.message, 'err');
  }
}

$('#search-btn').onclick = () => openSearch();
$('#search-close').onclick = closeSearch;
$('#search-modal').onclick = ev => { if (ev.target.id === 'search-modal') closeSearch(); };
$('#search-input').oninput = onSearchInput;
$('#search-input').onkeydown = ev => {
  const n = state.search.rows.length;
  if (ev.key === 'ArrowDown') { state.search.cur = (state.search.cur + 1) % Math.max(n, 1); highlightSearch(); ev.preventDefault(); }
  else if (ev.key === 'ArrowUp') { state.search.cur = (state.search.cur - 1 + n) % Math.max(n, 1); highlightSearch(); ev.preventDefault(); }
  else if (ev.key === 'Enter') { pickSearch(state.search.cur, ev.shiftKey); ev.preventDefault(); }
  else if (ev.key === 'Escape') closeSearch();
};

/* ============================================================== watchlist */
async function loadWatchlist() {
  try {
    const lists = await api('/watchlist');
    state.watchlist = lists[0] || null;
    state.watchSyms = new Set((state.watchlist?.items || []).map(i => i.symbol));
    $('#c-watch').textContent = state.watchSyms.size || '';
    renderStar();
  } catch (e) { console.error('watchlist load failed', e); }
}

function renderStar() {
  const on = state.watchSyms.has(state.symbol);
  const b = $('#star-btn');
  b.textContent = on ? '★' : '☆';
  b.classList.toggle('on', on);
  b.title = on ? 'Remove from watchlist' : 'Add to watchlist';
}

async function toggleWatch(sym = state.symbol) {
  try {
    if (state.watchSyms.has(sym)) {
      await api(`/watchlist/items/${encodeURIComponent(sym)}`, { method: 'DELETE' });
      toast('Removed from watchlist', sym, 'info');
    } else {
      await api('/watchlist/items', { method: 'POST', body: JSON.stringify({ symbol: sym }) });
      toast('Added to watchlist', sym, 'ok');
    }
    await loadWatchlist();
    renderTape();
    if (state.tab === 'watchlist') loadBlotter();
  } catch (e) { toast('Watchlist failed', e.message, 'err'); }
}

$('#star-btn').onclick = () => toggleWatch();

/* ================================================================ alerts */
async function loadAlerts() {
  try {
    const d = await api('/alerts');
    state.alerts = d.alerts || [];
    state.alertFires = d.recent_fires || [];
    const armed = state.alerts.filter(a => a.is_active).length;
    $('#c-alerts').textContent = armed || '';
  } catch (e) { console.error('alerts load failed', e); }
}

function alertState(a) {
  if (a.fire_count > 0 && !a.is_active) return 'fired';
  if (!a.is_active) return 'expired';
  return 'armed';
}

function openAlertDialog(sym = state.symbol) {
  const q = state.quote;
  $('#alert-modal').hidden = false;
  $('#alert-sym').textContent = sym;
  $('#alert-form').dataset.sym = sym;
  $('#alert-kind').value = 'above';
  $('#alert-note').value = '';
  $('#alert-repeat').value = 'false';
  syncAlertDialog();
  // Pre-fill 2% away from the current mark: a plausible alert, so the
  // dialog is one keystroke from useful rather than an empty form.
  const last = num(q?.last_price);
  $('#alert-threshold').value = isFinite(last) ? (last * 1.02).toFixed(
    Math.abs(last) >= 1 ? 2 : 6) : '';
  $('#alert-threshold').focus();
}

function syncAlertDialog() {
  const kind = $('#alert-kind').value;
  const isPct = kind.startsWith('pct_move');
  $('#alert-thr-label').textContent = isPct ? 'Move (%)' : 'Price';
  const last = num(state.quote?.last_price);
  if (isPct) {
    $('#alert-threshold').value = '5';
    $('#alert-hint').innerHTML = isFinite(last)
      ? `Measured from <b>${price(last)}</b>, captured now. The reference is
         fixed at creation, so the alert cannot drift with the market.`
      : 'Measured from the price at creation.';
  } else {
    $('#alert-hint').innerHTML = isFinite(last)
      ? `Current mark <b>${price(last)}</b>.`
      : '';
  }
}

$('#alert-kind').onchange = syncAlertDialog;
$('#bell-btn').onclick = () => openAlertDialog();
$('#alert-cancel').onclick = () => { $('#alert-modal').hidden = true; };
$('#alert-modal').onclick = ev => { if (ev.target.id === 'alert-modal') $('#alert-modal').hidden = true; };
$('#alert-form').onsubmit = async ev => {
  ev.preventDefault();
  const body = {
    symbol: $('#alert-form').dataset.sym,
    kind: $('#alert-kind').value,
    threshold: $('#alert-threshold').value,
    note: $('#alert-note').value || null,
    repeat_alert: $('#alert-repeat').value === 'true',
  };
  try {
    await api('/alerts', { method: 'POST', body: JSON.stringify(body) });
    $('#alert-modal').hidden = true;
    toast('Alert armed', `${body.symbol} ${body.kind.replace('_', ' ')} ${body.threshold}`, 'ok');
    await loadAlerts();
    if (state.tab === 'alerts') loadBlotter();
  } catch (e) { toast('Could not create the alert', e.message, 'err'); }
};

async function removeAlert(id) {
  try {
    const res = await api(`/alerts/${id}`, { method: 'DELETE' });
    // The distinction is real and worth surfacing: an alert that has
    // fired cannot be deleted, because risk.alert_fire is append-only
    // and still references it. It is archived instead.
    toast(res.outcome === 'archived' ? 'Alert archived' : 'Alert deleted',
          res.outcome === 'archived'
            ? 'It had fired, so its notification history is kept.'
            : `#${id}`, 'info');
    await loadAlerts();
    loadBlotter();
  } catch (e) { toast('Could not remove the alert', e.message, 'err'); }
}

/* ============================================================ csv export */
/*
  Exports whatever the visible table last rendered, not a second query --
  so what lands in the file is exactly what was on screen.
*/
function toCsv(cols, rows) {
  const cell = v => {
    const t = v === null || v === undefined ? '' : String(v);
    return /[",\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
  };
  return [cols.map(cell).join(','), ...rows.map(r => r.map(cell).join(','))].join('\n');
}

function downloadCsv(name, cols, rows) {
  if (!rows.length) { toast('Nothing to export', 'This table is empty', 'info'); return; }
  const blob = new Blob([toCsv(cols, rows)], { type: 'text/csv;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `apex-${name}-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '')}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
  toast('Exported', `${rows.length} row${rows.length === 1 ? '' : 's'} → ${a.download}`, 'ok');
}

function exportRecords(name, records, keys) {
  downloadCsv(name, keys, records.map(r => keys.map(k => r[k])));
}

$('#blotter-csv').onclick = () => {
  const t = state.lastTable;
  exportRecords(t.name, t.rows, t.cols);
};
$('#chart-csv').onclick = () => {
  const bars = state.charts.lastBars || [];
  exportRecords(`${state.symbol}-${state.interval}`, bars,
                ['bucket', 'open', 'high', 'low', 'close', 'volume', 'vwap']);
};
$('#hist-csv').onclick = () => exportRecords('history', state.histRows || [],
  ['occurred_at', 'action', 'symbol', 'quantity', 'price', 'amount',
   'currency', 'description', 'entry_id']);
$('#pf-csv').onclick = () => exportRecords('holdings', state.pfRows || [],
  ['symbol', 'name', 'quantity', 'avg_cost', 'mark_price', 'quote_currency',
   'market_value', 'unrealized_pnl', 'unrealized_pct', 'realized_pnl']);
$('#mk-csv').onclick = () => exportRecords('movers', state.mkRows || [],
  ['symbol', 'name', 'kind', 'sector', 'last_price', 'change_pct', 'day_volume']);

/* ======================================================= keyboard shortcuts */
const SHORTCUTS = [
  ['/',       'Search stocks and crypto'],
  ['b',       'Switch the ticket to buy'],
  ['s',       'Switch the ticket to sell'],
  ['w',       'Star or unstar the current instrument'],
  ['a',       'Create a price alert on it'],
  ['1 … 5',   'Chart interval: 1m, 5m, 15m, 1h, 1D'],
  ['[  ]',    'Previous / next instrument in the visible tape'],
  ['e',       'Export the visible table as CSV'],
  ['g then p','Go to Portfolio   (g h History, g m Markets, g t Trade)'],
  ['?',       'This list'],
  ['Esc',     'Close whatever is open'],
];

function renderShortcuts() {
  $('#keys-grid').innerHTML = SHORTCUTS.map(([k, d]) =>
    `<kbd>${esc(k)}</kbd><span class="d">${esc(d)}</span>`).join('');
}

let goPrefix = false;
document.addEventListener('keydown', ev => {
  // Never steal a keystroke someone is typing into a field.
  const tag = (ev.target.tagName || '').toLowerCase();
  if (['input', 'select', 'textarea'].includes(tag) || ev.metaKey || ev.ctrlKey) {
    if (ev.key === 'Escape') { closeSearch(); $('#alert-modal').hidden = true; }
    return;
  }
  if (ev.key === 'Escape') {
    closeSearch(); $('#alert-modal').hidden = true; $('#keys-modal').hidden = true;
    return;
  }
  if (!$('#app').classList.contains('ready')) return;

  if (goPrefix) {
    goPrefix = false;
    const to = { p: 'portfolio', h: 'history', m: 'markets', t: 'trade',
                 s: 'social', c: 'compliance' }[ev.key];
    if (to) { gotoView(to); ev.preventDefault(); }
    return;
  }

  switch (ev.key) {
    case '/': openSearch(); ev.preventDefault(); break;
    case '?': $('#keys-modal').hidden = false; break;
    case 'g': goPrefix = true; break;
    case 'b': setSide('buy'); break;
    case 's': setSide('sell'); break;
    case 'w': toggleWatch(); break;
    case 'a': openAlertDialog(); break;
    case 'e': $('#blotter-csv').click(); break;
    case '[': stepSymbol(-1); break;
    case ']': stepSymbol(1); break;
    case '1': case '2': case '3': case '4': case '5': {
      const b = $$('#interval-seg button')[Number(ev.key) - 1];
      if (b) b.click();
      break;
    }
  }
});

$('#keys-close').onclick = () => { $('#keys-modal').hidden = true; };
$('#keys-modal').onclick = ev => { if (ev.target.id === 'keys-modal') $('#keys-modal').hidden = true; };

function gotoView(v) {
  const b = $$('nav button').find(x => x.dataset.view === v);
  if (b && !b.hidden) b.click();
}

function stepSymbol(d) {
  const rows = visibleInstruments();
  if (!rows.length) return;
  const i = rows.findIndex(r => r.symbol === state.symbol);
  const next = rows[((i < 0 ? 0 : i) + d + rows.length) % rows.length];
  selectSymbol(next.symbol);
}

function renderAbout() {
  $('#about-body').innerHTML = `
    <h2>How Apex Trader works</h2>
    <p class="lede">This is not a trading app that forwards orders to somebody else's API.
    The order book lives in PostgreSQL and orders are crossed there. The database is the exchange.</p>

    <div class="cols">
      <div class="card"><div class="panel-head"><span class="title">Matching engine</span></div>
        <div style="padding:12px;font-size:12.5px;line-height:1.6;color:var(--text-dim)">
          A continuous-auction limit order book with <b style="color:var(--text)">price-time priority</b>,
          implemented as PL/pgSQL. Better prices execute first; at equal prices the earlier
          order wins, ordered by a monotonic sequence rather than a wall clock that can tie.
          The resting order sets the execution price, so an aggressor crossing the spread
          receives price improvement. Matching per instrument is serialised with a
          transaction-scoped advisory lock, so different symbols match in parallel while the
          same symbol can never double-fill a resting order.
          <br><br>Order types: market, limit, stop, stop-limit, trailing stop and iceberg,
          with DAY / GTC / IOC / FOK time-in-force.
        </div></div>

      <div class="card"><div class="panel-head"><span class="title">Double-entry ledger</span></div>
        <div style="padding:12px;font-size:12.5px;line-height:1.6;color:var(--text-dim)">
          There is <b style="color:var(--text)">no balance column</b>. Every movement of value is a
          set of signed postings inside a journal entry, and a
          <b style="color:var(--text)">deferred constraint trigger</b> verifies at COMMIT that each
          entry sums to exactly zero, independently for cash and for every security.
          Value can only move, never be created.
          <br><br>Because the journal is append-only, the portfolio at any past instant is a
          query &mdash; see <i>Point-in-time reconstruction</i> on the Portfolio tab. A design
          that mutates a balance cannot answer that question, because the history is gone.
        </div></div>

      <div class="card"><div class="panel-head"><span class="title">Risk &amp; surveillance</span></div>
        <div style="padding:12px;font-size:12.5px;line-height:1.6;color:var(--text-dim)">
          The pre-trade gate runs inside the order transaction, so no client path &mdash;
          app, script or direct psql &mdash; can place an order that skips it. It checks
          buying power including cash already committed to resting orders, share
          availability net of open sells, concentration, order rate, tick and lot size,
          price bands and daily loss.
          <br><br>Surveillance rules are single analytical queries: self-match joins for wash
          trading, cancel-ratio window functions for layering, statistical outliers for
          volume anomalies.
        </div></div>

      <div class="card"><div class="panel-head"><span class="title">Why it is built this way</span></div>
        <div style="padding:12px;font-size:12.5px;line-height:1.6;color:var(--text-dim)">
          Doing risk in Python, then matching in Python, then writing balances cannot be made
          atomic across concurrent orders without a global lock or a distributed transaction.
          Pushing the invariants into the database is what makes the system correct under
          concurrency &mdash; and it is why there is no ORM here.
          <br><br>Multi-tenant isolation is enforced by
          <b style="color:var(--text)">Row Level Security</b>, not by remembering to add a WHERE
          clause: the API sets one session variable per request and PostgreSQL itself refuses
          to return another trader's rows. A forgotten predicate yields an empty result instead
          of a data breach.
          <br><br>That protection is easy to lose without noticing. A view runs as its
          <i>owner</i> by default, and the owner of these tables is exempt from their own RLS,
          so reading the same rows through a view consulted no policy at all. Every view over
          user data is now <code>security_invoker</code>, and
          <code>ops.assert_rls_intact()</code> reports any that is not &mdash; so the next view
          someone adds has to make the decision rather than inherit the unsafe default.
        </div></div>

      <div class="card"><div class="panel-head"><span class="title">Two asset classes, one engine</span></div>
        <div style="padding:12px;font-size:12.5px;line-height:1.6;color:var(--text-dim)">
          Equities trade in a 390-minute session; crypto never closes. The same matching
          engine serves both, because the things that differ are
          <b style="color:var(--text)">data, not code</b>: an instrument carries its own tick
          size, lot size, price band and session rule, and
          <code>reference.is_instrument_open()</code> answers the hours question for either.
          <br><br>That is also where the equity assumptions were hiding. A lot size of 1 makes
          one bitcoin the minimum order; a tick of 0.01 is a thousand ticks on DOGE-USD;
          rounding a price to two decimals quantises a $0.13 coin into about thirteen
          distinguishable levels. And because crypto history has no gap between
          &ldquo;yesterday&rsquo;s close&rdquo; and &ldquo;now&rdquo;, the candle roller landed
          on top of loaded history and overwrote it &mdash; which is why every bar now records
          where it came from.
        </div></div>

      <div class="card"><div class="panel-head"><span class="title">Search, watchlists and alerts</span></div>
        <div style="padding:12px;font-size:12.5px;line-height:1.6;color:var(--text-dim)">
          Search runs twice: a <code>pg_trgm</code> similarity match against the listed
          universe, so &ldquo;aple&rdquo; finds AAPL, and a parallel lookup against the market
          data provider. A provider hit this venue does not carry yet can be listed on the
          spot &mdash; the instrument is created with microstructure chosen from its asset
          class and its minute history is backfilled, after which it trades like anything else.
          <br><br>Price alerts are evaluated in SQL on every ingestion cycle and pushed to the
          browser on the same <code>LISTEN/NOTIFY</code> channel as fills, so there is no
          second transport and no polling. An alert that has fired is archived rather than
          deleted: its fire rows are append-only and still reference it, and a notification
          that was really sent should not be erasable.
        </div></div>
    </div>`;
}

/* ---------------------------------------------------------------- restore session */
(async () => {
  // Before anything else. Checking this only inside boot() would leave a
  // stale server undetected until after sign-in, which is precisely when
  // the confusing half-working dashboard appears.
  try { await checkApiContract(); } catch { return; }
  await renderDemoChips();
  try {
    const saved = JSON.parse(sessionStorage.getItem('apex') || 'null');
    if (saved?.t) {
      state.token = saved.t; state.refresh = saved.r;
      await boot();
    }
  } catch { sessionStorage.removeItem('apex'); }
})();
