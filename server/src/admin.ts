/** The spend dashboard at /admin. The page asks for the admin token once and keeps it in this browser only. */
export const adminPage = String.raw`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>Oneshot · Spend</title>
<style>
  :root { --ink:#141216; --muted:#6b6570; --bg:#f6f2ec; --card:#fffdfa; --accent:#ee4d29; --warn:#d97706;
    --ring: 0 0 0 1px rgba(0,0,0,.06), 0 1px 2px -1px rgba(0,0,0,.06), 0 2px 4px rgba(0,0,0,.04); }
  * { box-sizing:border-box; }
  html { background:var(--bg); }
  body { margin:0; font:14px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; color:var(--ink);
    -webkit-font-smoothing:antialiased; }
  .wrap { max-width:960px; margin:0 auto; padding:40px 24px 64px; }
  header { display:flex; align-items:baseline; justify-content:space-between; gap:16px; margin-bottom:24px; }
  h1 { font-size:28px; letter-spacing:-.02em; margin:0; text-wrap:balance; }
  .sub { color:var(--muted); font-size:13px; }
  .grid { display:grid; grid-template-columns:repeat(4, 1fr); gap:12px; }
  .card { background:var(--card); border-radius:14px; box-shadow:var(--ring); padding:16px; }
  .label { font-size:12px; color:var(--muted); font-weight:500; }
  .big { font-size:28px; font-weight:700; letter-spacing:-.02em; font-variant-numeric:tabular-nums; margin-top:2px; }
  .small { font-size:12px; color:var(--muted); font-variant-numeric:tabular-nums; }
  h2 { font-size:15px; margin:28px 0 10px; }
  .chart { display:flex; align-items:flex-end; gap:4px; height:150px; padding-top:8px; }
  .bar { flex:1; background:rgba(238,77,41,.35); border-radius:4px 4px 1px 1px; min-height:2px; position:relative; }
  .bar.today { background:var(--accent); }
  .bar.est { background:repeating-linear-gradient(135deg, rgba(238,77,41,.35) 0 4px, rgba(238,77,41,.15) 4px 8px); }
  .bar:hover::after { content:attr(data-tip); position:absolute; bottom:calc(100% + 6px); left:50%; transform:translateX(-50%);
    white-space:nowrap; background:var(--ink); color:#fff; font-size:11px; padding:4px 7px; border-radius:6px; font-variant-numeric:tabular-nums; }
  .axis { display:flex; justify-content:space-between; font-size:11px; color:var(--muted); margin-top:6px; }
  table { width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; }
  td, th { padding:8px 4px; border-bottom:1px solid rgba(0,0,0,.06); text-align:left; font-size:13px; }
  th { font-size:12px; color:var(--muted); font-weight:500; }
  td.n, th.n { text-align:right; }
  .two { display:grid; grid-template-columns:1.4fr 1fr; gap:12px; }
  .pill { display:inline-block; font-size:11px; padding:2px 8px; border-radius:99px; background:rgba(0,0,0,.05); color:var(--muted); }
  .warn { color:var(--warn); }
  form { display:flex; gap:8px; margin-top:12px; }
  input { flex:1; font:inherit; padding:9px 12px; border-radius:10px; border:1px solid rgba(0,0,0,.12); background:#fff; }
  button { font:inherit; font-weight:600; padding:9px 16px; border:0; border-radius:10px; background:var(--ink); color:#fff; cursor:pointer;
    transition:transform 100ms cubic-bezier(.23,1,.32,1); }
  button:active { transform:scale(.97); }
  #login { max-width:420px; margin:12vh auto 0; }
  @media (max-width:760px) { .grid { grid-template-columns:repeat(2,1fr); } .two { grid-template-columns:1fr; } }
</style></head>
<body><div class="wrap">
  <div id="login" hidden class="card">
    <h1 style="font-size:20px">Oneshot spend</h1>
    <p class="sub">Paste the admin token. It stays in this browser.</p>
    <form id="f"><input id="t" type="password" placeholder="Admin token" autocomplete="off"><button>Open</button></form>
    <p id="err" class="small warn"></p>
  </div>
  <div id="app" hidden>
    <header><div><h1>Spend</h1><div class="sub" id="note"></div></div><span class="pill" id="limits"></span></header>
    <div class="grid">
      <div class="card"><div class="label">Today</div><div class="big" id="today"></div><div class="small" id="todayMin"></div></div>
      <div class="card"><div class="label">This week</div><div class="big" id="week"></div><div class="small" id="weekMin"></div></div>
      <div class="card"><div class="label">This month</div><div class="big" id="month"></div><div class="small" id="monthMin"></div></div>
      <div class="card"><div class="label">Monthly pace (last 7 days)</div><div class="big" id="pace"></div><div class="small" id="users"></div></div>
    </div>
    <h2>Last 30 days</h2>
    <div class="card"><div class="chart" id="chart"></div><div class="axis"><span id="a0"></span><span>striped = estimated from minutes</span><span>today</span></div></div>
    <div class="two">
      <div><h2>Busiest this week</h2><div class="card"><table id="top"></table></div></div>
      <div><h2>Daily detail</h2><div class="card"><table id="days"></table></div></div>
    </div>
  </div>
</div>
<script>
const $ = (id) => document.getElementById(id);
const usd = (n) => "$" + (n < 10 ? n.toFixed(2) : n.toFixed(0));
const min = (n) => (n < 10 ? n.toFixed(1) : Math.round(n)) + " min";
async function load() {
  // /admin#token=… stores the token (the fragment never reaches the server) and cleans the address bar.
  if (location.hash.startsWith("#token=")) {
    localStorage.setItem("oneshot-admin", decodeURIComponent(location.hash.slice(7)));
    history.replaceState(null, "", location.pathname);
  }
  const token = localStorage.getItem("oneshot-admin");
  if (!token) { $("login").hidden = false; return; }
  const res = await fetch("/admin/stats", { headers: { Authorization: "Bearer " + token } });
  if (res.status === 401) { localStorage.removeItem("oneshot-admin"); $("login").hidden = false; $("err").textContent = "That token didn't work."; return; }
  const s = await res.json();
  $("login").hidden = true; $("app").hidden = false;
  $("today").textContent = usd(s.today.usd); $("todayMin").textContent = min(s.today.minutes) + " · " + s.today.requests + " dictations";
  $("week").textContent = usd(s.week.usd); $("weekMin").textContent = min(s.week.minutes) + " · " + s.week.requests + " dictations";
  $("month").textContent = usd(s.month.usd); $("monthMin").textContent = min(s.month.minutes) + " · " + s.month.requests + " dictations";
  const last7 = s.days.slice(-7).reduce((n, d) => n + d.usd, 0);
  $("pace").textContent = usd(last7 / 7 * 30) + "/mo"; $("users").textContent = s.totalUsers + " accounts";
  const l = s.limits;
  $("limits").textContent = "Free: " + (l.freeWeeklyMinutes ? l.freeWeeklyMinutes + " min/week" : "") + (l.freeWeeklyMinutes && l.freeDailyMinutes ? " + " : "") + (l.freeDailyMinutes ? l.freeDailyMinutes + " min/day" : "") + " · global cap " + Math.round(l.globalDailyMinutes / 60) + " h/day";
  $("note").textContent = "OpenAI list prices: $" + s.prices.transcribePerMinute + "/audio min · updated " + new Date().toLocaleTimeString();
  const max = Math.max(0.01, ...s.days.map((d) => d.usd));
  $("chart").innerHTML = s.days.map((d, i) => '<div class="bar' + (i === s.days.length - 1 ? " today" : "") + (d.estimated ? " est" : "") +
    '" style="height:' + Math.max(1.5, d.usd / max * 100) + '%" data-tip="' + d.day.slice(5) + " · " + usd(d.usd) + " · " + min(d.minutes) + '"></div>').join("");
  $("a0").textContent = s.days[0].day.slice(5);
  $("top").innerHTML = "<tr><th>Account</th><th class=n>Minutes</th><th class=n>Dictations</th></tr>" +
    (s.topUsersThisWeek.map((t) => "<tr><td>" + t.email.replace(/</g, "&lt;") + "</td><td class=n>" + min(t.minutes) + "</td><td class=n>" + t.requests + "</td></tr>").join("") || "<tr><td colspan=3 class=small>No dictations yet this week</td></tr>");
  $("days").innerHTML = "<tr><th>Day</th><th class=n>Spend</th><th class=n>Minutes</th><th class=n>Active</th></tr>" +
    s.days.slice(-10).reverse().map((d) => "<tr><td>" + d.day.slice(5) + "</td><td class=n>" + usd(d.usd) + (d.estimated ? "*" : "") + "</td><td class=n>" + min(d.minutes) + "</td><td class=n>" + d.activeUsers + "</td></tr>").join("");
}
$("f").addEventListener("submit", (e) => { e.preventDefault(); localStorage.setItem("oneshot-admin", $("t").value.trim()); load(); });
load(); setInterval(load, 60000);
</script></body></html>`;
