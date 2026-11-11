#!/usr/bin/env node
/* 前端行为自检：在 build/Resources 里生成几个带数据的测试页，用 headless Chrome 跑，
   断言结果从 <pre id="out"> 里读回来。任何一条 FAIL 就非 0 退出。
   用法：node tools/check.js        （先跑 tools/bundle.sh）

   所有用例都跑在一个**固定假时钟**上：日期相关的逻辑（月级投票只在 1–7 号出现、
   日结报昨天、本周从周一算、年度公告 1/1–1/15 报去年）如果跟着真实日期走，
   一个月里只有几天能全绿，其余日子会红——红灯一多，就没人看了。
   默认 NOW = 2026-11-06（周五）12:00：6 号在 1–7 号窗口内，本周一 = 11-02，
   昨天 11-05 没有记录（日结条不该出现）。需要别的时点的用例单独传 now。 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(ROOT, 'build', 'Resources');
const INDEX = path.join(OUT, 'index.html');
// CI 上 Chrome 不在同一个位置，所以允许外部指定
const CHROME = process.env.CHROME_BIN || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
if (!fs.existsSync(CHROME)) {
  console.error('找不到 Chrome：' + CHROME + '\n可以设 CHROME_BIN=/path/to/chrome 再跑');
  process.exit(1);
}

if (!fs.existsSync(INDEX)) {
  console.error('缺少 build/Resources/index.html，先跑 tools/bundle.sh');
  process.exit(1);
}
const base = fs.readFileSync(INDEX, 'utf8');

/* ---------------- 固定时钟 ---------------- */
const NOW = new Date(2026, 10, 6, 12, 0, 0);      // 本地 2026-11-06 12:00
const pad2 = n => (n < 10 ? '0' + n : '' + n);
const dayKeyOf = ts => {
  const d = new Date(ts);
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
};
const T0 = (() => { const d = new Date(NOW.getTime()); d.setHours(0, 0, 0, 0); return d.getTime(); })();
const TODAY_K = dayKeyOf(T0);
const YDAY_K = dayKeyOf(T0 - 86400000);
const WEEK_START_K = dayKeyOf(T0 - ((new Date(T0).getDay() + 6) % 7) * 86400000);
const NOW_MS = NOW.getTime();
const LAST7_SEEN = (() => {
  const o = {};
  for (let i = 0; i < 7; i++) {
    const d = new Date(T0); d.setDate(d.getDate() - i);
    o[dayKeyOf(d.getTime())] = 1;
  }
  return o;
})();

/* 在 app.js **之前**注入 Date 桩：无参构造 / Date.now() 返回固定时刻，
   带参构造、parse、UTC 全部透传给真的 Date（返回的也是真 Date 实例）。 */
function dateStub(ms) {
  return '<script>(function () {\n'
    + '  var REAL = Date, FAKE = ' + ms + ';\n'
    + '  function Fake() {\n'
    + '    if (!(this instanceof Fake)) return REAL(FAKE);\n'
    + '    if (!arguments.length) return new REAL(FAKE);\n'
    + '    return Reflect.construct(REAL, Array.prototype.slice.call(arguments));\n'
    + '  }\n'
    + '  Fake.prototype = REAL.prototype;\n'
    + '  Fake.now = function () { return FAKE; };\n'
    + '  Fake.parse = REAL.parse;\n'
    + '  Fake.UTC = REAL.UTC;\n'
    + '  window.Date = Fake;\n'
    + '})();</script>\n';
}

const BRIDGE_STUB = '<script>window.__sent=[];window.webkit={messageHandlers:{bridge:{'
  + 'postMessage:function(m){window.__sent.push(m)}}}};</script>\n<script src="app.js"></script>';

function makePage(name, { load, ext, body, now }) {
  const at = now ? (now instanceof Date ? now : new Date(now)) : NOW;
  const page = base.replace('<script src="app.js"></script>', dateStub(at.getTime()) + BRIDGE_STUB).replace('</body>',
    '<style>*{animation:none!important;transition:none!important}</style>\n'
    + '<pre id="out" style="position:fixed;left:0;top:0;z-index:9999"></pre>\n'
    + '<script>\n'
    + 'window.__err=[];window.addEventListener("error",function(e){window.__err.push(e.message)});\n'
    + 'var LOG=[];function ok(n,c,x){LOG.push((c?"PASS ":"FAIL ")+n+(x?" :: "+x:""));}\n'
    + 'function flush(){document.getElementById("out").textContent=LOG.join("\\n");}\n'
    + 'setTimeout(function(){try{\n'
    + '  function txt(){return document.getElementById("report").textContent;}\n'
    + '  function tab(k){var b=document.querySelector(\'.r-tabs [data-tab="\'+k+\'"]\');if(b)b.click();}\n'
    + '  function ask(k){return document.querySelector(\'.r-ask[data-ask="\'+k+\'"]\');}\n'
    + '  function vis(sel){var e=document.querySelector(sel);if(!e)return {display:"missing",h:0};'
    + 'var s=getComputedStyle(e);var r=e.getBoundingClientRect();'
    + 'return {display:s.display,h:Math.round(r.height)};}\n'
    + '  window.__load(' + JSON.stringify(load || defaultLoad) + ');\n'
    + '  window.__ext(' + JSON.stringify(ext === undefined ? extFull : ext) + ');\n'
    + '  document.getElementById("btnProg").click();\n'
    + body + '\n'
    + '}catch(e){LOG.push("FAIL 运行期异常 :: "+e.message);}\n'
    + 'ok("页面无 JS 报错",!window.__err.length,window.__err.join(" | "));flush();},500);\n'
    + '</script>\n');
  const f = path.join(OUT, name);
  fs.writeFileSync(f, page);
  return f;
}

function run(file) {
  const dom = execFileSync(CHROME, ['--headless', '--disable-gpu', '--no-sandbox',
    '--virtual-time-budget=5000', '--dump-dom', 'file://' + file],
    { maxBuffer: 1 << 24, stdio: ['ignore', 'pipe', 'ignore'] }).toString();
  const m = dom.match(/<pre id="out"[^>]*>([\s\S]*?)<\/pre>/);
  return m ? m[1] : 'NO OUTPUT';
}

/* ---------------- 夹具 ---------------- */
const daily = { '2026-11-01': 3, '2026-11-02': 2 };
const meetingDays = {
  '2026-01-05': 2, '2026-01-12': 2, '2026-01-19': 2,
  '2026-02-02': 2, '2026-02-09': 2, '2026-02-16': 2
};

const extFull = {
  cal: {
    st: 'ok', n: 365, allday: 10, sec: 1000000, days: 120, today: 3, next: '14:30', year: 2026, per: meetingDays,
    // 节日只来自日历：夹具里造一本"节假日"日历，今天记一个节日
    // hoff 是日历自带的调休标记：1=休 0=班，缺省=不知道（节气就是这类）
    holi: { [TODAY_K]: '测试节日（休）' }, hoff: { [TODAY_K]: 1 }, hcal: ['中国大陆节假日']
  },
  rem: { st: 'ok', total: 40, open: 5, done: 30, overdue: 2, today: 1, nodue: 0 },
  screen: { st: 'ok', sec: 19800, apps: [{ id: 'a', n: 'Slack', sec: 7200 }], src: 'knowledgeC' },
  focus: { st: 'ok', sec: 5400, apps: [{ id: 'b', n: 'Arc', sec: 5400 }] },
  session: { idle: 30, locked: false, screenoff: false, asleep: false, away: false }
};

/* 「app 那天开着」的戳。有会/没会对照现在只认看得见的日子，
   夹具得先把这些天标成"我看见了"，否则那行根本不该出现。 */
const seenDays = (() => {
  const o = {};
  Object.keys(meetingDays).forEach(k => { o[k] = 1; });
  ['2026-01-06', '2026-01-07', '2026-01-08', '2026-01-09',
    '2026-01-13', '2026-01-14', '2026-01-15', '2026-01-16'].forEach(k => { o[k] = 1; });
  Object.keys(daily).forEach(k => { o[k] = 1; });
  return o;
})();

const defaultLoad = {
  nodes: [], seq: 1, log: [], daily, flow: { '2026-03-02': { n: 12, x: 3, q: 2 } },
  byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
  said: { '2026-10': { avg: '日均 2.8 件', meet: '有会反而做得多' } }, saidN: {}, vote: {},
  seen: seenDays, seenFrom: '2026-01-05'
};

/* ---------------- 用例 1：三层纠错 ---------------- */
const caseTruth = makePage('__t_truth.html', {
  // 多给一天有产出的日子：avg 那句判断要 active >= 3 才会生成，
  // 否则下面「静音」的断言测的是一个根本不存在的句子（空转绿灯）。
  load: Object.assign({}, defaultLoad, {
    daily: Object.assign({}, daily, { '2026-11-03': 1 })
  }),
  body: `
  var g = ask('gap');
  ok('日级对账出现', !!g, g ? g.textContent.trim() : '没有');
  ok('对账带日程数', !!g && g.textContent.indexOf('3 个日程') >= 0);
  var b1 = g && g.querySelector('[data-gap="1"]');
  ok('有「忘了记」', !!b1);
  if (b1) b1.click();
  ok('回答后不再问', !ask('gap'));
  tab('yr');
  ok('年度标了漏记', txt().indexOf('可能漏记') >= 0);
  // 月级投票只在每月 1–7 号出现；固定时钟是 11-06，上月键 = 2026-10
  var v = ask('vote');
  ok('月级投票出现', !!v);
  ok('列出上月原句', !!v && v.textContent.indexOf('日均 2.8 件') >= 0);
  ok('静音前句子在', txt().indexOf('动手那天平均') >= 0, txt().slice(0, 200));
  var no = v && v.querySelector('[data-vote="avg|no"]');
  ok('有「不准」', !!no);
  if (no) no.click();
  var saidN1 = window.__debugState().saidN || {};
  ok('投一次还没静音：句在、计数 1', txt().indexOf('动手那天平均') >= 0 && saidN1.avg === 1,
     'saidN=' + JSON.stringify(saidN1));
  // UI 里同一句每月只能投一次；直接把计数补到 2，再投另一句触发重渲染，看它消不消失
  window.__debugState().saidN.avg = 2;
  var v2 = ask('vote');
  var noMeet = v2 && v2.querySelector('[data-vote="meet|no"]');
  ok('还能投别的句子', !!noMeet);
  if (noMeet) noMeet.click();
  ok('累计两次后静音', txt().indexOf('动手那天平均') < 0, txt().slice(0, 200));
  var q = document.querySelector('.r-q[data-q="cal.y"]');
  ok('来源行有问号', !!q);
  if (q) q.click();
  var fb = document.querySelector('.r-fb');
  ok('展开三选项', !!fb && fb.textContent.indexOf('数不对') >= 0);
  var wrong = fb && fb.querySelector('[data-fb="wrong"]');
  if (wrong) wrong.click();
  ok('投完收起', !document.querySelector('.r-fb'));
  ok('纠正计数出现', txt().indexOf('你纠正过我 1 次') >= 0);
  var q2 = document.querySelector('.r-q[data-q="meet"]');
  if (q2) q2.click();
  var hide = document.querySelector('.r-fb [data-fb="hide"]');
  if (hide) hide.click();
  ok('该行被隐藏', !document.querySelector('.r-src[data-k="meet"]'));
  var un = document.querySelector('[data-act="unhide"]');
  ok('有恢复入口', !!un);
  if (un) un.click();
  ok('恢复后回来', !!document.querySelector('.r-src[data-k="meet"]'));
  ok('单开一个面板', document.querySelectorAll('.r-fb').length <= 1);`
});

/* ---------------- 用例 2：无授权 / 拒绝 / 空数据 ---------------- */
const casePerm = makePage('__t_perm.html', {
  ext: { cal: { st: 'ask' }, rem: { st: 'ask' }, screen: { st: 'nofda' },
         focus: { st: 'ok', sec: 5400, apps: [{ id: 'b', n: 'Arc', sec: 5400 }] } },
  body: `
  tab('yr');
  var a = txt();
  ok('有授权入口', a.indexOf('授权后显示日历') >= 0);
  ok('有磁盘访问入口', a.indexOf('完全磁盘访问') >= 0);
  ok('没数据不编日历', a.indexOf('天有会') < 0);
  ok('入口可点', !!document.querySelector('[data-act="auth"]'));
  tab('day');
  ok('退到前台计时', txt().indexOf('前台') >= 0);
  window.__ext({cal:{st:'denied'},rem:{st:'denied'},screen:{st:'nofile'},focus:{st:'ok',sec:0,apps:[]}});
  tab('yr');
  ok('拒绝提示', txt().indexOf('被拒绝') >= 0);
  window.__ext(null);
  ok('ext 为空不崩', !!txt());`
});

/* ---------------- 用例 3：四个页签都能渲染 ---------------- */
const caseTabs = makePage('__t_tabs.html', {
  body: `
  ['day','d30','h1','yr'].forEach(function(k){
    tab(k);
    var t = txt();
    ok('页签 ' + k + ' 有内容', t.length > 30, t.slice(0, 40));
  });
  tab('yr');
  ok('年度标题对', txt().indexOf('年度') >= 0);
  // 认赔要单独看得见：它是"我认下这件事不做了"，不是"我不想要了"
  ok('年度页里能看见认赔件数', txt().indexOf('认赔') >= 0, txt().slice(0, 300));
  // 年页不许再统计"节日 N 天"：那是日历条目数，不是这一年干了什么
  ok('年页不统计节日天数', txt().indexOf('节日 ') < 0, txt().slice(0, 300));
  tab('day');
  ok('今日行显示节日（来自日历）', txt().indexOf('测试节日') >= 0, txt().slice(0, 200));
  // 「（休）」要读成人话；「（班）」和节气不能跟着被当成放假
  ok('（休）标记读成放假', txt().indexOf('测试节日 放假') >= 0, txt().slice(0, 200));
  // 环里必须写清算什么：只有一个百分比会被读成"专注度"
  ok('今日环写明在算什么', txt().indexOf('今日划掉') >= 0 || txt().indexOf('还没排事') >= 0,
    txt().slice(0, 120));
  // 行存在就必须带口径；行不存在（样本不足）也算合规——但两种都不能靠"或"蒙过去
  var meetRow = document.querySelector('.r-src[data-k="meet"]');
  ok('对照行写明只比工作日', !meetRow || (meetRow.getAttribute('title') || '').indexOf('工作日') >= 0,
     meetRow ? meetRow.getAttribute('title') : '行未出现');`
});

/* ---------------- 用例 D：欠账有出口 + 日结报得准 ----------------
   欠账条以前只是半句话：点不动，也销不掉。这里断言它真的能点、能销。 */
const debtNodes = [
  { id: 1, type: 'task', text: '修落地页文案', done: false, due: T0, created: T0 - 86400000 * 9, carried: 8 },
  { id: 2, type: 'task', text: '回电话给老张', done: false, due: T0, created: T0 - 86400000 * 6, carried: 5 },
  { id: 3, type: 'task', text: '整理照片', done: false, due: T0, created: T0 - 86400000 * 4, carried: 3 },
  { id: 4, type: 'task', text: '今天的新事', done: false, due: T0, created: T0, carried: 0 }
];

const caseDebt = makePage('__t_debt.html', {
  load: {
    nodes: debtNodes, seq: 9, log: [], daily: { [YDAY_K]: 7 },
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}, seen: { [YDAY_K]: 1 }, seenFrom: YDAY_K
  },
  ext: null,
  body: `
  var db = document.querySelector('.a-debt');
  ok('欠账条出现', !!db, db ? db.textContent : '没有');
  ok('欠账条报件数', !!db && db.textContent.indexOf('3') >= 0, db ? db.textContent : '');
  ok('欠账条给最久天数', !!db && db.textContent.indexOf('8 天') >= 0, db ? db.textContent : '');

  var settle = document.querySelector('.a-settle');
  ok('日结条出现', !!settle, settle ? settle.textContent : '没有');
  ok('日结报昨天的实数', !!settle && settle.textContent.indexOf('昨天结了 7 件') >= 0,
     settle ? settle.textContent : '');

  if (db) db.click();
  var rows = document.querySelectorAll('.d-row');
  ok('面板列出 3 件', rows.length === 3, 'rows=' + rows.length);
  ok('拖得最久的排第一', rows.length > 0 && rows[0].textContent.indexOf('8天') >= 0,
     rows.length ? rows[0].textContent : '');
  ok('写了销账是什么意思', document.body.textContent.indexOf('不算划掉，也不再欠着') >= 0);

  if (rows.length) {
    var wv = rows[0].querySelector('.d-wv');
    if (wv) wv.click();
  }
  var after = document.querySelectorAll('.d-row');
  ok('销账后少一件', after.length === 2, 'rows=' + after.length);
  // 只看清单和面板，不看 #out —— 断言日志自己会带着任务名，那是测试的副产品
  var stillThere = [].filter.call(document.querySelectorAll('.d-row, #list li'), function (n) {
    return n.textContent.indexOf('修落地页文案') >= 0;
  }).length;
  ok('销掉的那件从清单消失', stillThere === 0, '还在 ' + stillThere + ' 处');

  // 认赔 ≠ 删掉。一个是"我认下这件事不做了"，一个是"这条我不想要了"。
  // 混成一个数，那笔了结就没有重量了——报告里也再没人看得见。
  var fl = (window.__debugState().flow || {})["${TODAY_K}"] || {};
  ok('销账记进 q（认赔），不混进 x（删掉）', fl.q === 1 && !fl.x, JSON.stringify(fl));

  var backs = document.querySelector('.d-back');
  ok('有返回今天的出口', !!backs);
  if (backs) backs.click();
  // 展开态下 agenda 只留「要你处理」的条；返回之后债务行就该没了。
  // 日程摘要（.a-head）在展开态是多余的，footer 已经在说同一件事。
  ok('返回后不再显示欠账行', !document.querySelector('.d-row'));
  ok('展开态不重复日程摘要',
    !document.querySelector('.a-head') || getComputedStyle(document.querySelector('.a-head')).display === 'none');
  `
});

/* ---------------- 用例 W：本周页签 ----------------
   本周只算"周一到今天"，不拿 7 天当分母。固定时钟是周五 → 本周 5 天。 */
const caseWeek = makePage('__t_week.html', {
  load: {
    nodes: [], seq: 1, log: [], daily: { [WEEK_START_K]: 2 },
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}, seen: { [WEEK_START_K]: 1 }, seenFrom: WEEK_START_K
  },
  ext: null,
  body: `
  tab('wk');
  var t = txt();
  ok('本周页签有内容', t.length > 30, t.slice(0, 40));
  ok('标了本周划掉', t.indexOf('本周划掉') >= 0, t.slice(0, 120));
  ok('不拿 7 天当分母', t.indexOf('周一到今天') >= 0, t.slice(0, 200));
  var bars = document.querySelectorAll('.r-bar');
  var wd = (new Date().getDay() + 6) % 7;
  ok('柱子只画到今天', bars.length === wd + 1, 'bars=' + bars.length + ' 应为 ' + (wd + 1));
  ok('周一的柱子有数', bars.length > 0);
  ok('昨天没记录就不日结', !document.querySelector('.a-settle'));
  `
});

/* ---------------- 用例 W2：开着但一件没划掉 ----------------
   这一屏原来有两句话在打架：柱子区说"这周还没有记录"，
   下面那行总结说"这 7 天我开着，一件都没划掉"。同一次渲染里两种说法。
   判据是 sum（划掉件数），可 sum=0 不等于没有记录——那是把"有记录"说成"没记录"，
   和产品最核心的那条口径正好相反。
   反方向也一样：只看见 1 天就说"这 7 天都开着"，是把"没记录"说成"有记录"。 */
const caseWeekZero = makePage('__t_week0.html', {
  load: {
    nodes: [], seq: 1, log: [], daily: {},
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}, seen: { [TODAY_K]: 1 }, seenFrom: TODAY_K
  },
  ext: null,
  body: `
  tab('wk');
  var t = txt();
  ok('空账但开着：不说"没有记录"', t.indexOf('这周还没有记录') < 0, t.slice(0, 160));
  ok('空账但开着：说成"开着，没划掉"', t.indexOf('没划掉') >= 0, t.slice(0, 160));
  tab('day');
  var d = txt();
  ok('只看见 1 天：不吹"这 7 天都开着"', d.indexOf('这 7 天都开着') < 0, d.slice(0, 200));
  ok('只看见 1 天：报实际开着几天', d.indexOf('这 7 天里我开着 1 天') >= 0, d.slice(0, 200));
  // 7 天全都看见：才配说"这 7 天都开着"
  window.__load({
    nodes: [], seq: 1, log: [], daily: {},
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {},
    seen: ${JSON.stringify(LAST7_SEEN)}, seenFrom: ${JSON.stringify(dayKeyOf(T0 - 86400000 * 6))}
  });
  tab('day');
  ok('7 天都看见：才说"这 7 天都开着"', txt().indexOf('这 7 天都开着') >= 0, txt().slice(0, 200));
  `
});

/* ---------------- 用例 S：最长连续是下界 ----------------
   没记录的日子只能当断点，真实连续只会更长。全看见了才敢写确定值。 */
const caseStreak = makePage('__t_streak.html', {
  load: {
    nodes: [], seq: 1, log: [],
    daily: { [dayKeyOf(T0 - 86400000 * 2)]: 1, [dayKeyOf(T0 - 86400000)]: 2 },
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {},
    seen: { [dayKeyOf(T0 - 86400000 * 2)]: 1, [dayKeyOf(T0 - 86400000)]: 1 },
    seenFrom: dayKeyOf(T0 - 86400000 * 2)
  },
  ext: null,
  body: `
  tab('yr');
  var t = txt();
  ok('年度的最长连续标了"≥"', t.indexOf('≥') >= 0, t.slice(0, 200));
  ok('没有把下界写成确定值', /最长连续/.test(t), t.slice(0, 200));
  tab('h1');
  ok('半年页也标了"≥"', txt().indexOf('≥') >= 0, txt().slice(0, 200));`
});

/* ---------------- 用例 P：手动顺延也要记账 ----------------
   老实现里「→」只写 due、不碰 carried，于是它成了一无限次免罚券。
   另一头：顺延计数只对"已经到期"的任务算欠账——把一件未来排期的活
   往后挪，是重排不是欠债（口径见 05-today.js debts）。 */
const casePush = makePage('__t_push.html', {
  load: {
    nodes: [
      { id: 1, type: 'task', text: '推到明天的那件', done: false, due: T0, created: T0 - 86400000, carried: 0 },
      { id: 2, type: 'task', text: '排在明天的那件', done: false, due: T0 + 86400000, created: T0, carried: 0 }
    ],
    seq: 3, log: [], daily: {},
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}, seen: { [TODAY_K]: 1 }, seenFrom: TODAY_K
  },
  ext: null,
  body: `
  function nodeOf(id) {
    var a = window.__debugState().nodes.filter(function (n) { return n.id === id; });
    return a[0] || {};
  }
  function moveOf(word) {
    var rows = [].slice.call(document.querySelectorAll('.agenda .a-row'));
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].textContent.indexOf(word) >= 0) return rows[i].querySelector('.a-move');
    }
    return null;
  }
  function chipOf(word) {
    var rows = [].slice.call(document.querySelectorAll('#list li'));
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].textContent.indexOf(word) >= 0) return rows[i].querySelector('.chip.day');
    }
    return null;
  }
  function debtText() {
    var d = document.querySelector('.a-debt');
    return d ? d.textContent : '没有';
  }

  // 1) 收起态：今天的活点「→」推走
  window.__setCollapsed(true);
  ok('收起态能看到今天清单', !!moveOf('推到明天'), debtText());
  ok('顺延前没有欠账条', !document.querySelector('.a-debt'), debtText());
  var m1 = moveOf('推到明天');
  if (m1) m1.click();
  ok('点「→」记 1 天', nodeOf(1).carried === 1, 'carried=' + nodeOf(1).carried);
  ok('点「→」due 真到了明天', nodeOf(1).due === ${T0} + 86400000, 'due=' + nodeOf(1).due);
  ok('只推一天还不算欠（阈值 2）', !document.querySelector('.a-debt'), debtText());

  // 2) 展开态：未来任务的日期 chip 走同一条路
  window.__setCollapsed(false);
  var c1 = chipOf('排在明天');
  ok('未来任务有日期 chip', !!c1);
  if (c1) c1.click();
  ok('点日期 chip 也记 1 天', nodeOf(2).carried === 1, 'carried=' + nodeOf(2).carried);
  var c2 = chipOf('排在明天');
  if (c2) c2.click();
  ok('连推两次记到 2 天', nodeOf(2).carried === 2, 'carried=' + nodeOf(2).carried);
  // 未来排期被推两次：carried 记了，但这不是"欠"——due 还没到
  ok('未来任务推两次不进欠账面板', !document.querySelector('.a-debt'), debtText());

  // 3) 造一件真的过期且拖过的：due 退回昨天，交给 rollover 归一到今天并渲染
  var st = window.__debugState();
  st.nodes.push({ id: 3, type: 'task', text: '真拖了两天的', parentId: null, done: false,
                  due: ${T0} - 86400000, created: ${T0} - 5 * 86400000, carried: 2 });
  window.__tick();
  ok('过期且拖过的才进欠账', !!document.querySelector('.a-debt'), debtText());
  ok('欠账只算这一件', debtText().indexOf('有 1 件') >= 0, debtText());
  ok('未来那两件没被算进来', debtText().indexOf('有 3 件') < 0, debtText());
  `
});

/* ---------------- 用例 6：没记录 ≠ 0 件 ---------------- */
const caseSeen = makePage('__t_seen.html', {
  load: {
    nodes: [], seq: 1, log: [],
    daily: { '2026-11-04': 2 },
    seen: { '2026-11-03': 1, '2026-11-04': 1, '2026-11-05': 1 },
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}
  },
  ext: null,
  body: `
  tab('yr');
  var t = txt();
  ok('说了"不知道"那句', t.indexOf('没有任何记录') >= 0, t.slice(0, 200));
  ok('明确没算成 0 件', t.indexOf('没算成 0 件') >= 0);
  var unk = document.querySelectorAll('rect.hc-unk').length;
  var zero = document.querySelectorAll('rect.hc0').length;
  ok('有"没记录"空格', unk > 0, 'unk=' + unk);
  // 11-05 被看见、0 件：这是真的 0 件，要单独画成 hc0，不能跟着 hc-unk
  ok('已知的 0 件画成实心 0', zero >= 1, 'hc0=' + zero);
  var tips = Array.prototype.map.call(document.querySelectorAll('rect title'), function (n) { return n.textContent; });
  ok('悬浮提示不写"0 件"', tips.filter(function (x) { return x.indexOf('没记录') >= 0; }).length > 0);
  // 今天的戳：__tick 会自动补上"今天开着"，并且真的发给了原生侧
  window.__tick();
  var saves = window.__sent.filter(function (m) { return m.type === 'save'; });
  var last = saves.length ? JSON.parse(saves[saves.length - 1].payload) : {};
  ok('今天补了 seen 戳', !!(last.seen && last.seen["${TODAY_K}"] === 1), "${TODAY_K} → " + JSON.stringify(last.seen || {}));
  ok('戳只记日期不记内容', Object.keys(last.seen || {}).every(function (k) { return /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(k); }));
  tab('day');
  ok('今日页仍正常', txt().indexOf('已划掉') >= 0);

  // seen 不再裁剪：900 个历史键 + 今天 = 901，一个都不许少
  // （裁掉旧 seen 会让"看得见的天/最长连续"在几年后自己变小，和"历史不回改"冲突）
  var bigSeen = {};
  for (var i = 1; i <= 900; i++) {
    var dd = new Date(${T0});
    dd.setDate(dd.getDate() - i);
    bigSeen[dd.getFullYear() + '-' + ('0' + (dd.getMonth() + 1)).slice(-2) + '-' + ('0' + dd.getDate()).slice(-2)] = 1;
  }
  var firstKey = (function () {
    var d = new Date(${T0}); d.setDate(d.getDate() - 900);
    return d.getFullYear() + '-' + ('0' + (d.getMonth() + 1)).slice(-2) + '-' + ('0' + d.getDate()).slice(-2);
  })();
  window.__load({ nodes: [], seq: 1, log: [], daily: {}, flow: {}, byProj: {}, anniv: {},
    fb: [], hide: {}, gap: {}, gapOff: 0, said: {}, saidN: {}, vote: {},
    seen: bigSeen, seenFrom: firstKey });
  var beforeN = Object.keys(window.__debugState().seen).length;
  window.__tick();
  var afterN = Object.keys(window.__debugState().seen).length;
  ok('900 个历史 seen 没被裁', beforeN === 900, 'before=' + beforeN);
  ok('补上今天后 901 个都在', afterN === 901, 'after=' + afterN);`
});

/* ---------------- 用例 5：积压天数与残缺占比 ---------------- */
// due 在真实数据里永远是被归一化到当天零点的（rollover 每晚改写），不是"现在"
const caseBacklog = makePage('__t_backlog.html', {
  load: {
    nodes: [
      { id: 1, type: 'task', text: 'A', done: false, due: T0, carried: 9, created: 1 },
      { id: 2, type: 'task', text: 'B', done: false, due: T0, carried: 9, created: 1 },
      { id: 3, type: 'task', text: 'C', done: false, due: T0, carried: 2, created: 1 },
      { id: 4, type: 'task', text: 'D', done: true, due: T0, carried: 30, created: 1 }
    ],
    seq: 5, log: [],
    daily: { '2026-11-04': 10 },
    seen: { '2026-11-04': 1 }, seenFrom: '2026-11-04',
    flow: {}, byProj: { '2026': { '0': 5 } }, anniv: {},
    fb: [], hide: {}, gap: {}, gapOff: 0, said: {}, saidN: {}, vote: {}
  },
  ext: null,
  body: `
  tab('yr');
  var t = txt();
  ok('按顺延天数说积压', t.indexOf('推了一周以上') >= 0, t.slice(-260));
  ok('只算没做完的', t.indexOf('2 件已经被往后推了一周以上') >= 0);
  ok('占比残缺不报百分比', t.indexOf('还算不了') >= 0);
  ok('没有假百分比', t.indexOf('100%') < 0 && t.indexOf('60%') < 0);
  ok('积压行写明是"现在"', t.indexOf('现在还有') >= 0);`
});

/* ---------------- 用例 6：口径一致（月度 / 对照 / 区间文案） ----------------
   同样一份数据，在年页、月柱、区间三处不能说三套话。 */
const caseCaliber = makePage('__t_caliber.html', {
  load: {
    nodes: [], seq: 1, log: [],
    daily: { '2026-11-04': 6 },
    seen: { '2026-11-04': 1 }, seenFrom: '2026-11-04',
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}
  },
  ext: {
    cal: { st: 'ok', n: 365, allday: 0, sec: 1000000, days: 120, today: 1, next: '', year: 2026, per: meetingDays },
    rem: { st: 'ok', total: 0, open: 0, done: 0, overdue: 0, today: 0, nodue: 0 },
    screen: { st: 'nofda', why: 'rc=23 errno=1' }, focus: { st: 'ok', sec: 0, apps: [] }
  },
  body: `
  tab('yr');
  var titles = Array.prototype.map.call(document.querySelectorAll('.r-week-month .r-bar'), function (n) { return n.title; });
  ok('月柱有"没记录"', titles.filter(function (x) { return x.indexOf('没记录') >= 0; }).length > 0, titles.join(' | '));
  ok('空月不写 0 件', titles.filter(function (x) { return / 月 · 0 件/.test(x); }).length === 0, titles.join(' | '));
  ok('观测不足不说有会/没会', !document.querySelector('.r-src[data-k="meet"]'));
  ok('屏幕权限有可点入口', !!document.querySelector('[data-act="fda"]'));
  tab('d30');
  var t30 = txt();
  ok('区间分开说未知', t30.indexOf('没有任何记录') >= 0, t30);
  ok('未知不说成 0 件', t30.indexOf('不算 0 件') >= 0, t30);`
});

/* ---------------- 用例 7：导出说明 + 数据状态条 ----------------
   本地优先的三条承诺要靠"用户能自己验"兑现，所以这里验的是导出包里的那份说明：
   它必须自带格式版本、必须把"没记录"写成"—"而不是 0、必须写明口径。
   数据状态条验的是"文件出过事"这件事到底会不会被看见——不只是 DOM 里有节点。 */
const caseExport = makePage('__t_export.html', {
  load: {
    nodes: [{ id: 1, type: 'task', text: '秘密事项XYZ', done: false, due: null, created: 1 }],
    seq: 2, log: [], daily, flow: {}, byProj: {}, anniv: {},
    fb: [], hide: {}, gap: {}, gapOff: 0, said: {}, saidN: {}, vote: {},
    seen: seenDays, seenFrom: '2026-01-05'
  },
  body: `
  var md = window.__exportReadme();
  ok('说明有格式版本', md.indexOf('格式版本：2') >= 0);
  ok('说明写明没记录不等于 0', md.indexOf('没记录 ≠ 0 件') >= 0);
  ok('说明有字段表', md.indexOf('data.json 里都有什么') >= 0);
  // 字段表要覆盖真正写进去的键：三层纠错的证据（said/vote）、明细（log）、对账静音（gapOff）
  ok('字段表补了 seq/log/gapOff', md.indexOf('\`seq\`') >= 0 && md.indexOf('\`log\`') >= 0 && md.indexOf('\`gapOff\`') >= 0);
  ok('字段表补了 said/vote', md.indexOf('\`said\`') >= 0 && md.indexOf('\`vote\`') >= 0);
  ok('说明提到 focus.json', md.indexOf('focus.json') >= 0);
  ok('说明写明 seen 永久保留', md.indexOf('永久保留') >= 0);
  ok('说明教怎么恢复', md.indexOf('Application Support/DeskTodo/data.json') >= 0);
  ok('年表数字对得上账本', md.indexOf('| 2026 | 5 |') >= 0, md.split('## 每年')[1]);
  // 有观测、真的一件没做的月份，写 0 是对的；只有"没观测"才必须写破折号
  ok('没观测的月不写 0 件', !/\\| [0-9]+ 月 \\| 0 \\| — \\|/.test(md));
  ok('空月份写破折号', md.indexOf('| 10 月 | — | — |') >= 0);
  ok('导出入口通了', typeof window.__exportReadme === 'function');

  window.__storeState({ state: 'recovered', kept: ['data.corrupt-20261106-1053.json'] });
  var bar = document.getElementById('databar');
  ok('恢复过会亮出来', bar.classList.contains('show'));
  // 断言要钉"看得见"，不是"DOM 里有这个节点"：上一版正是因此漏掉了 CSS 藏起来的条
  var barVis = vis('#databar');
  ok('恢复条真的占位置', barVis.display !== 'none' && barVis.h > 0, JSON.stringify(barVis));
  ok('说明是备份救的', document.getElementById('dbText').textContent.indexOf('备份') >= 0);
  ok('带上坏文件名', document.getElementById('dbText').textContent.indexOf('data.corrupt-') >= 0);

  window.__storeState({ state: 'normal' });
  ok('正常时一点不占', !bar.classList.contains('show'));

  // 两条边界必须同时成立：导出里"有内容"，诊断里"没内容"
  var diag = window.__diagText();
  ok('导出带任务正文', md.indexOf('秘密事项XYZ') >= 0);
  ok('诊断不带任务正文', diag.indexOf('秘密事项XYZ') < 0, diag);
  ok('诊断带来源状态', diag.indexOf('来源 cal：') >= 0, diag);
  ok('诊断写明不含内容', diag.indexOf('不含任何任务内容') >= 0);`
});

/* ---------------- 用例 L：账本自洽 ----------------
   1 取消勾选一件超过 60 天前划掉的任务，daily 要能退回来
   2 顺延天数累加上界与重算上界必须一致（366），数字不能自己变小
   3 认赔（q）也算"这天我看得见"
   4 报告五个页签高度差几百 px，切页签窗口不能弹
   这几条以前 99 条断言全绿也照样存在，因为断言没查它们。 */
// 60 天前正午划掉：一定已经被 pruneLog 裁掉（它只留 60 天，且按 todayStart 算）
const SIXTY_TS = (() => { const d = new Date(T0); d.setDate(d.getDate() - 60); d.setHours(12, 0, 0, 0); return d.getTime(); })();
const SIXTY_K = dayKeyOf(SIXTY_TS);
// 只有一次销账的那天：daily 没有、seen 没有、只有 flow.q
const QONLY_TS = (() => { const d = new Date(T0); d.setDate(d.getDate() - 3); return d.getTime(); })();
const QONLY_K = dayKeyOf(QONLY_TS);
const QONLY_MD = (new Date(QONLY_TS).getMonth() + 1) + '/' + new Date(QONLY_TS).getDate();

const caseLedger = makePage('__t_ledger.html', {
  load: {
    nodes: [
      { id: 1, type: 'task', text: '六十天前做完的', done: true, doneAt: SIXTY_TS, due: T0, created: SIXTY_TS - 86400000 },
      { id: 2, type: 'task', text: '拖了很久的', done: false, due: T0, carried: 900, created: T0 - 400 * 86400000 }
    ],
    seq: 3,
    log: [],                                  // 明细已裁，这里必须是空的，才是真实场景
    daily: {},                                // 下面按计算出的键填，避免硬编码日期
    seen: {}, seenFrom: '',
    flow: {},
    byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}
  },
  ext: null,
  body: `
  var st0 = window.__debugState();
  // 把夹具铺好：那天的账是 1 件，而 log 里没有对应明细
  st0.daily['${SIXTY_K}'] = 1;
  st0.flow['${QONLY_K}'] = { q: 1 };
  ok('起点：那天的账是 1', st0.daily['${SIXTY_K}'] === 1);

  // 1) 明细已裁时取消勾选，账要退回来
  var row = document.querySelector('.task[data-id="1"] .check');
  ok('找得到那条已划掉任务的勾选框', !!row);
  if (row) row.click();
  var st1 = window.__debugState();
  ok('取消勾选后那天减回 0（明细已裁也要退）', !st1.daily['${SIXTY_K}'],
    'daily=' + JSON.stringify(st1.daily));
  ok('任务本身回到未划掉', st1.nodes.filter(function (n) { return n.id === 1; })[0].done === false);

  // 2) 顺延天数：涨不上去，也不会自己变小
  var long = st1.nodes.filter(function (n) { return n.id === 2; })[0];
  ok('顺延天数不超过 366', (long.carried || 0) <= 366, 'carried=' + long.carried);
  ok('没有出现 999 这种越界值', (long.carried || 0) !== 999 && (long.carried || 0) !== 900, 'carried=' + long.carried);

  // 3) 只有认赔的那天，不算"没记录"
  tab('yr');
  var tips = Array.prototype.map.call(document.querySelectorAll('rect title'),
    function (n) { return n.textContent; });
  var qTip = tips.filter(function (x) { return x.indexOf('${QONLY_MD}') === 0; })[0] || '';
  ok('销账的那天不进"没记录"', qTip.indexOf('没记录') < 0, 'tip=' + qTip);

  // 4) 切页签：只会变高，不会缩回来再弹一下（窗口高度才稳）
  tab('day');
  var hDay = document.getElementById('report').offsetHeight;
  tab('yr');
  var hYr = document.getElementById('report').offsetHeight;
  tab('day');
  var hBack = document.getElementById('report').offsetHeight;
  ok('切页签只会变高', hYr >= hDay && hDay > 0, hDay + ' → ' + hYr);
  ok('切回原页签高度不变（不抖）', hBack === hYr, hYr + ' → ' + hBack);
  ok('高度有上限，不会顶出屏幕', hYr <= 640, 'h=' + hYr);`
});

/* ---------------- 用例 V：看不见时不该落账、看得见才落账 ----------------
   收起成桌面小圆点时窗口是 orderOut 的，JS 还在跑。日结条如果在这时候
   "渲染即算看过"，用户当天就再也看不到它。toast 同理：收起态 footer 被藏了，
   提示必须真的出现在屏幕上（尤其是「保存失败」）。 */
const caseVisible = makePage('__t_visible.html', {
  load: {
    nodes: [{ id: 1, type: 'task', text: '今天的一件', parentId: null, done: false, due: T0, created: T0 }],
    seq: 2, log: [], daily: { [YDAY_K]: 4 },
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}, seen: { [YDAY_K]: 1, [TODAY_K]: 1 }, seenFrom: YDAY_K
  },
  ext: null,
  body: `
  // 1) 收起态：footer 被 CSS 藏了，提示必须改走 #toast 并且真的看得见
  window.__setCollapsed(true);
  ok('收起态：footer 确实不可见', vis('#footer').display === 'none', JSON.stringify(vis('#footer')));
  window.__saveFail();
  var tv = vis('#toast');
  ok('收起态：提示元素可见', tv.display !== 'none' && tv.h > 0, JSON.stringify(tv));
  ok('收起态：保存失败真的显示出来',
    document.getElementById('toast').textContent.indexOf('保存失败') >= 0
    && document.getElementById('toast').classList.contains('show'),
    document.getElementById('toast').className);
  window.__setCollapsed(false);

  // 2) 日结：不可见时不生成 DOM、不写盘；可见后才落账
  var st = window.__debugState();
  st.settle = '';
  document.getElementById('agenda').innerHTML = '';
  window.__onBlur();                       // 原生 hideToDot 会调这个
  st.nodes[0].due = ${T0} - 86400000;      // 造一次跨天：__tick 里 rollover 会变
  window.__tick();
  ok('不可见时：不生成日结条', !document.querySelector('.a-settle'));
  ok('不可见时：不写 settle', st.settle === '', 'settle=' + st.settle);
  window.__onShow();                       // 原生 showMain 会调这个
  ok('可见后：日结条出现', !!document.querySelector('.a-settle'),
     (document.querySelector('.a-settle') || {}).textContent);
  ok('可见后：才写 settle', st.settle === "${TODAY_K}", 'settle=' + st.settle);
  `
});

/* ---------------- 用例 R：时间段提醒勾掉再取消，不能静默死亡 ----------------
   chip 写着「每天 HH:MM」就是承诺"这个点还会响"。勾掉时清掉 remindAt、
   取消勾选后不重算的话，UI 还在承诺，checkDue 却永远跳过。 */
const caseRange = makePage('__t_range.html', {
  load: {
    nodes: [{ id: 1, type: 'task', text: '每天提醒的活', parentId: null, done: false,
              due: T0, created: T0, remindAt: NOW_MS + 3600000, fired: false,
              range: { from: T0, to: T0 + 7 * 86400000, hh: 12, mm: 30 } }],
    seq: 2, log: [], daily: {},
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}, seen: { [TODAY_K]: 1 }, seenFrom: TODAY_K
  },
  ext: null,
  body: `
  var st = window.__debugState();
  var t = st.nodes[0];
  ok('勾掉前 chip 说「每天」', document.querySelector('.task[data-id="1"] .chip').textContent.indexOf('每天') >= 0,
     document.querySelector('.task[data-id="1"] .chip').textContent);
  document.querySelector('.task[data-id="1"] .check').click();
  ok('勾掉后保留 range', !!st.nodes[0].range);
  ok('勾掉后不清 remindAt（时间段是常设承诺）', typeof st.nodes[0].remindAt === 'number',
     'remindAt=' + st.nodes[0].remindAt);
  document.querySelector('.task[data-id="1"] .check').click();
  t = st.nodes[0];
  ok('取消勾选后 chip 还是「每天」',
    document.querySelector('.task[data-id="1"] .chip').textContent.indexOf('每天') >= 0,
    document.querySelector('.task[data-id="1"] .chip').textContent);
  ok('取消勾选后 remindAt 重新排到未来', t.remindAt > ${NOW_MS}, 'remindAt=' + t.remindAt);
  ok('fired 复位，下个点还能响', t.fired === false, 'fired=' + t.fired);
  ok('账也退回去了', !st.daily["${TODAY_K}"], JSON.stringify(st.daily));
  `
});

/* ---------------- 用例 Y：年度公告跨年那 15 天 ----------------
   1/1–1/15 公告报的是去年；点「看」必须翻到去年，不能打开今年的空账本。 */
const caseAnnivYear = makePage('__t_anniv.html', {
  now: new Date(2027, 0, 3, 12, 0, 0),
  load: {
    nodes: [], seq: 1, log: [],
    daily: { '2026-11-01': 3, '2026-11-02': 2, '2026-11-03': 1 },
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {},
    seen: { '2026-11-01': 1, '2026-11-02': 1, '2026-11-03': 1 }, seenFrom: '2026-11-01'
  },
  ext: null,
  body: `
  var an = document.getElementById('anniv');
  ok('公告报的是去年', an.dataset.year === '2026', 'dataset.year=' + an.dataset.year);
  ok('公告标题写去年', document.getElementById('annivTitle').textContent.indexOf('2026') >= 0,
     document.getElementById('annivTitle').textContent);
  document.getElementById('annivGo').click();
  var sub = (document.querySelector('.r-sub') || {}).textContent || '';
  ok('点「看」打开的是 2026 年度', sub.indexOf('2026 年度') >= 0, sub);
  ok('不是今年的空账本', sub.indexOf('2027 年度') < 0, sub);
  ok('年度页里是 2026 的账', txt().indexOf('划掉') >= 0 && txt().indexOf('6') >= 0, txt().slice(0, 200));
  ok('公告标记成看过了', window.__debugState().anniv.seen2026 === 1,
     JSON.stringify(window.__debugState().anniv));
  `
});

/* ---------------- 用例 J：项目删掉之后取消勾选，byProj 要按当时的项目退 ----------------
   只按"现在的归属"退账，删过项目再取消勾选时，那个项目的数字就永久多一件。 */
const caseProjUndo = makePage('__t_projundo.html', {
  load: {
    nodes: [
      { id: 1, type: 'project', text: '项目A', path: null, kind: 'folder', collapsed: false, created: T0 },
      { id: 2, type: 'task', text: '挂A的活', parentId: 1, path: null, done: false, due: T0, created: T0 }
    ],
    seq: 3, log: [], daily: {},
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}, seen: { [TODAY_K]: 1 }, seenFrom: TODAY_K
  },
  ext: null,
  body: `
  var st = window.__debugState();
  var y = String(new Date().getFullYear());
  document.querySelector('.task[data-id="2"] .check').click();
  ok('划掉时记进所在项目', !!(st.byProj[y] && st.byProj[y]['1'] === 1), JSON.stringify(st.byProj));
  ok('明细里记了当时的项目 id', (st.log[st.log.length - 1] || {}).p === 1, JSON.stringify(st.log));
  document.querySelector('.project[data-id="1"] .p-act.rm').click();
  ok('删项目后任务落到顶层', st.nodes.filter(function (n) { return n.id === 2; })[0].parentId === null);
  document.querySelector('.task[data-id="2"] .check').click();
  ok('取消勾选后按当时的项目退账', !st.byProj[y], JSON.stringify(st.byProj));
  ok('daily 也退回去了', !st.daily["${TODAY_K}"], JSON.stringify(st.daily));
  `
});

/* ---------------- 用例 F：从本地选文件新建，也要记 flow.n ---------------- */
const caseFileFlow = makePage('__t_fileflow.html', {
  load: {
    nodes: [], seq: 1, log: [], daily: {},
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}, seen: { [TODAY_K]: 1 }, seenFrom: TODAY_K
  },
  ext: null,
  body: `
  var st = window.__debugState();
  window.__onPick('newfile', '/tmp/demo-report.pdf', false);
  ok('文件任务建出来了', st.nodes.length === 1 && st.nodes[0].path === '/tmp/demo-report.pdf',
     JSON.stringify(st.nodes));
  var fl = st.flow["${TODAY_K}"] || {};
  ok('文件任务也记进 flow.n', fl.n === 1, JSON.stringify(fl));
  `
});

/* ---------------- 用例 G：更新版本的数据文件，不加载也不写盘 ---------------- */
const caseVersionGate = makePage('__t_version.html', {
  load: {
    v: 99,
    nodes: [{ id: 1, type: 'task', text: '未来版本的条目', parentId: null, done: false, due: T0, created: T0 }],
    seq: 2, log: [], daily: { [TODAY_K]: 3 },
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}, seen: { [TODAY_K]: 1 }, seenFrom: TODAY_K
  },
  ext: null,
  body: `
  var st = window.__debugState();
  ok('更新版本的数据不加载', st.nodes.length === 0, 'nodes=' + st.nodes.length);
  ok('刷新标记立起来', st.loadBlocked === true, 'loadBlocked=' + st.loadBlocked);
  var saves = window.__sent.filter(function (m) { return m.type === 'save'; });
  ok('一条 save 都没发出去', saves.length === 0, 'saves=' + saves.length);
  ok('给了"请先升级"的提示', document.body.textContent.indexOf('更新版本') >= 0,
     document.body.textContent.slice(0, 200));
  // 之后再有任何动作也不能写盘
  window.__saveFail();
  window.__tick();
  ok('后续 tick 也不写盘',
     window.__sent.filter(function (m) { return m.type === 'save'; }).length === 0,
     'saves=' + window.__sent.filter(function (m) { return m.type === 'save'; }).length);
  `
});

/* ---------------- 用例 C：磁盘被另一个窗口改过 ----------------
   原生把磁盘上那份合法 JSON 交给页面：按磁盘版本重载，且不回写。
   磁盘里的 due 故意是昨天——__load 的 rollover 会改内存，正是"别回写"要防的场景。 */
const caseConflict = makePage('__t_conflict.html', {
  load: {
    nodes: [{ id: 1, type: 'task', text: '本机版本', parentId: null, done: false, due: T0, created: T0 }],
    seq: 2, log: [], daily: { [TODAY_K]: 5 },
    flow: {}, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}, seen: { [TODAY_K]: 1 }, seenFrom: TODAY_K
  },
  ext: null,
  body: `
  var st = window.__debugState();
  ok('先载入本机版本', st.nodes.length === 1 && st.nodes[0].text.indexOf('本机') >= 0, JSON.stringify(st.nodes));
  function toastText() {
    return (document.getElementById('toast').textContent || '') + ' '
      + (document.getElementById('summary').textContent || '');
  }
  window.__sent.length = 0;
  var disk = JSON.stringify({
    v: 2, seq: 9,
    nodes: [{ id: 3, type: 'task', text: '磁盘版本', parentId: null, done: false,
              due: ${T0} - 86400000, created: ${T0} }],
    log: [], daily: { "${TODAY_K}": 1 }, flow: {}, byProj: {}, anniv: {}, fb: [], hide: {},
    gap: {}, gapOff: 0, said: {}, saidN: {}, vote: {},
    seen: { "${TODAY_K}": 1 }, seenFrom: "${TODAY_K}"
  });
  ok('冲突处理返回 true', window.__storeConflict(disk) === true);
  var st2 = window.__debugState();
  ok('内存换成磁盘版本', st2.nodes.length === 1 && st2.nodes[0].text === '磁盘版本', JSON.stringify(st2.nodes));
  ok('账本也换成磁盘的', st2.daily["${TODAY_K}"] === 1, JSON.stringify(st2.daily));
  ok('提示"已按磁盘版本重新载入"', toastText().indexOf('重新载入') >= 0, toastText());
  ok('重载过程一条 save 都不发',
     window.__sent.filter(function (m) { return m.type === 'save'; }).length === 0,
     'saves=' + window.__sent.filter(function (m) { return m.type === 'save'; }).length);
  var keep = st2.nodes[0].text;
  ok('坏 JSON 返回 false', window.__storeConflict('{不是 JSON') === false);
  ok('坏 JSON 不动内存', window.__debugState().nodes[0].text === keep);
  ok('坏 JSON 也给提示', toastText().indexOf('读不出来') >= 0, toastText());
  `
});

/* ---------------- 用例 T：今天只写不排 —— 报告不能说"什么都没写" ---------------- */
const caseFutureTip = makePage('__t_futuretip.html', {
  load: {
    nodes: [
      { id: 1, type: 'task', text: '明天的事1', parentId: null, done: false, due: T0 + 86400000, created: T0 },
      { id: 2, type: 'task', text: '明天的事2', parentId: null, done: false, due: T0 + 86400000, created: T0 }
    ],
    seq: 3, log: [], daily: {},
    flow: { [TODAY_K]: { n: 2 } }, byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
    said: {}, saidN: {}, vote: {}, seen: { [TODAY_K]: 1 }, seenFrom: TODAY_K
  },
  ext: null,
  body: `
  var tip = document.querySelector('.r-tip').textContent;
  ok('写了东西就不说"什么都没写"', tip.indexOf('什么都没写') < 0, tip);
  ok('说清今天写了几件', tip.indexOf('今天写了 2 件') >= 0, tip);
  ok('底栏没有和它打架', document.getElementById('summary').textContent.indexOf('还剩 2 件事') >= 0,
     document.getElementById('summary').textContent);
  `
});

/* ---------------- 跑全部用例 ---------------- */
let bad = 0, total = 0;
for (const [name, file] of [['三层纠错', caseTruth], ['授权状态', casePerm], ['页签渲染', caseTabs],
  ['欠账与日结', caseDebt], ['本周页签', caseWeek], ['开着但没勾', caseWeekZero],
  ['连续是下界', caseStreak], ['手动顺延记账', casePush],
  ['观测口径', caseSeen], ['积压与占比', caseBacklog],
  ['口径一致', caseCaliber], ['导出与状态', caseExport], ['账本自洽', caseLedger],
  ['不可见不落账', caseVisible], ['时间段提醒', caseRange], ['年度跨年', caseAnnivYear],
  ['项目退账', caseProjUndo], ['文件任务流水', caseFileFlow], ['版本闸门', caseVersionGate],
  ['磁盘冲突', caseConflict], ['今日只写不排', caseFutureTip]]) {
  const out = run(file);
  const fails = (out.match(/^FAIL /gm) || []).length;
  const passes = (out.match(/^PASS /gm) || []).length;
  bad += fails;
  total += passes + fails;
  console.log(`\n【${name}】PASS ${passes} / FAIL ${fails}`);
  if (fails || passes === 0) console.log(out);
}
console.log(bad === 0 ? '\n全部通过' : `\n有 ${bad} 条失败`);
/* 断言总数落一个文件：tools/docs-check.sh 会拿它核对文档里的数字，
   这样"文档说 129 条、实际 183 条"这种事不用人肉发现。 */
fs.writeFileSync(path.join(OUT, 'assert-count.txt'), String(total));
process.exit(bad === 0 ? 0 : 1);
