#!/usr/bin/env node
/* 前端行为自检：在 build/Resources 里生成几个带数据的测试页，用 headless Chrome 跑，
   断言结果从 <pre id="out"> 里读回来。任何一条 FAIL 就非 0 退出。
   用法：node tools/check.js        （先跑 tools/bundle.sh） */
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

const daily = { '2026-11-01': 3, '2026-11-02': 2 };
const meetingDays = {
  '2026-01-05': 2, '2026-01-12': 2, '2026-01-19': 2,
  '2026-02-02': 2, '2026-02-09': 2, '2026-02-16': 2
};
const pad2 = n => (n < 10 ? '0' + n : '' + n);
const TODAY_K = (() => {
  const d = new Date();
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
})();

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

const BRIDGE_STUB = '<script>window.__sent=[];window.webkit={messageHandlers:{bridge:{'
  + 'postMessage:function(m){window.__sent.push(m)}}}};</script>\n<script src="app.js"></script>';

function makePage(name, { load, ext, body }) {
  const page = base.replace('<script src="app.js"></script>', BRIDGE_STUB).replace('</body>',
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
  nodes: [], seq: 1, log: [], daily, flow: { '2026-03-02': { n: 12, x: 3 } },
  byProj: {}, anniv: {}, fb: [], hide: {}, gap: {}, gapOff: 0,
  said: { '2026-10': { avg: '日均 2.8 件', meet: '有会反而做得多' } }, saidN: {}, vote: {},
  seen: seenDays, seenFrom: '2026-01-05'
};

function run(file) {
  const dom = execFileSync(CHROME, ['--headless', '--disable-gpu', '--no-sandbox',
    '--virtual-time-budget=5000', '--dump-dom', 'file://' + file],
    { maxBuffer: 1 << 24, stdio: ['ignore', 'pipe', 'ignore'] }).toString();
  const m = dom.match(/<pre id="out"[^>]*>([\s\S]*?)<\/pre>/);
  return m ? m[1] : 'NO OUTPUT';
}

/* ---------------- 用例 1：三层纠错 ---------------- */
const caseTruth = makePage('__t_truth.html', {
  body: `
  var g = ask('gap');
  ok('日级对账出现', !!g, g ? g.textContent.trim() : '没有');
  ok('对账带日程数', !!g && g.textContent.indexOf('3 个日程') >= 0);
  var b1 = g && g.querySelector('[data-gap="1"]');
  ok('有「忘了记」', !!b1);
  if (b1) b1.click();
  ok('回答后不再问', !ask('gap'));
  tab('yr');
  ok('年轮标了漏记', txt().indexOf('可能漏记') >= 0);
  var v = ask('vote');
  ok('月级投票出现', !!v);
  ok('列出上月原句', !!v && v.textContent.indexOf('日均 2.8 件') >= 0);
  var no = v && v.querySelector('[data-vote="avg|no"]');
  ok('有「不准」', !!no);
  if (no) no.click();
  ok('累计两次后静音', txt().indexOf('动手那天平均') < 0);
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
  ok('年轮标题对', txt().indexOf('年轮') >= 0);
  // 年页不许再统计"节日 N 天"：那是日历条目数，不是这一年干了什么
  ok('年页不统计节日天数', txt().indexOf('节日 ') < 0, txt().slice(0, 300));
  tab('day');
  ok('今日行显示节日（来自日历）', txt().indexOf('测试节日') >= 0, txt().slice(0, 200));
  // 「（休）」要读成人话；「（班）」和节气不能跟着被当成放假
  ok('（休）标记读成放假', txt().indexOf('测试节日 放假') >= 0, txt().slice(0, 200));
  // 环里必须写清算什么：只有一个百分比会被读成"专注度"
  ok('今日环写明在算什么', txt().indexOf('今日完成') >= 0 || txt().indexOf('还没排事') >= 0,
    txt().slice(0, 120));
  // 行存在就必须带口径；行不存在（样本不足）也算合规——但两种都不能靠"或"蒙过去
  var meetRow = document.querySelector('.r-src[data-k="meet"]');
  ok('对照行写明只比工作日', !meetRow || (meetRow.getAttribute('title') || '').indexOf('工作日') >= 0,
     meetRow ? meetRow.getAttribute('title') : '行未出现');`
});

/* ---------------- 用例 D：欠账有出口 + 日结报得准 ----------------
   欠账条以前只是半句话：点不动，也销不掉。这里断言它真的能点、能销。 */
const T0 = (() => {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.getTime();
})();
const dayKeyOf = ts => {
  const d = new Date(ts);
  return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
};
const YDAY_K = dayKeyOf(T0 - 86400000);
const WEEK_START_K = dayKeyOf(T0 - ((new Date(T0).getDay() + 6) % 7) * 86400000);

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
  ok('写了销账是什么意思', document.body.textContent.indexOf('不算完成，也不再欠着') >= 0);

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

  var backs = document.querySelector('.d-back');
  ok('有返回今天的出口', !!backs);
  if (backs) backs.click();
  ok('返回后回到日程', !!document.querySelector('.a-row'));
  `
});

/* ---------------- 用例 W：本周页签 ----------------
   本周只算"周一到今天"，不拿 7 天当分母。 */
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
  ok('标了本周完成', t.indexOf('本周完成') >= 0, t.slice(0, 120));
  ok('不拿 7 天当分母', t.indexOf('周一到今天') >= 0, t.slice(0, 200));
  var bars = document.querySelectorAll('.r-bar');
  var wd = (new Date().getDay() + 6) % 7;
  ok('柱子只画到今天', bars.length === wd + 1, 'bars=' + bars.length + ' 应为 ' + (wd + 1));
  ok('周一的柱子有数', bars.length > 0);
  ok('昨天没记录就不日结', !document.querySelector('.a-settle'));
  `
});

/* ---------------- 用例 6：没记录 ≠ 0 件 ---------------- */
const caseSeen = makePage('__t_seen.html', {
  load: {
    nodes: [], seq: 1, log: [],
    daily: { '2026-11-04': 2 },
    seen: { '2026-11-03': 1, '2026-11-04': 1 },
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
  ok('已知 0 件另算', zero >= 0 && zero !== unk, 'hc0=' + zero);
  var tips = Array.prototype.map.call(document.querySelectorAll('rect title'), function (n) { return n.textContent; });
  ok('悬浮提示不写"0 件"', tips.filter(function (x) { return x.indexOf('没记录') >= 0; }).length > 0);
  // 今天的戳：__tick 会自动补上"今天开着"，并且真的发给了原生侧
  function pad(n){ return n < 10 ? '0' + n : '' + n; }
  var nd = new Date();
  var todayK = nd.getFullYear() + '-' + pad(nd.getMonth() + 1) + '-' + pad(nd.getDate());
  window.__tick();
  var saves = window.__sent.filter(function (m) { return m.type === 'save'; });
  var last = saves.length ? JSON.parse(saves[saves.length - 1].payload) : {};
  ok('今天补了 seen 戳', !!(last.seen && last.seen[todayK] === 1), todayK + ' → ' + JSON.stringify(last.seen || {}));
  ok('戳只记日期不记内容', Object.keys(last.seen || {}).every(function (k) { return /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(k); }));
  tab('day');
  ok('今日页仍正常', txt().indexOf('已完成') >= 0);`
});

/* ---------------- 用例 5：积压天数与残缺占比 ---------------- */
// due 在真实数据里永远是被归一化到当天零点的（rollover 每晚改写），不是"现在"
const MIDNIGHT = (function () { const d = new Date(); d.setHours(0, 0, 0, 0); return d.getTime(); })();
const caseBacklog = makePage('__t_backlog.html', {
  load: {
    nodes: [
      { id: 1, type: 'task', text: 'A', done: false, due: MIDNIGHT, carried: 9, created: 1 },
      { id: 2, type: 'task', text: 'B', done: false, due: MIDNIGHT, carried: 9, created: 1 },
      { id: 3, type: 'task', text: 'C', done: false, due: MIDNIGHT, carried: 2, created: 1 },
      { id: 4, type: 'task', text: 'D', done: true, due: MIDNIGHT, carried: 30, created: 1 }
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
   同样一份数据，在年页、月柱、区间三处不能说三套话。
   这里只给一天观测，其余全是"不知道"：
   - 空月份不能写"0 件"；
   - 有会/没会两组样本不足时，那行不许出现（否则拿未知日充数，日均会被稀释）；
   - 区间文案要把"有记录但没勾"和"没有记录"分开说。 */
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
   数据状态条验的是"文件出过事"这件事到底会不会被看见。 */
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
  ok('说明教怎么恢复', md.indexOf('Application Support/DeskTodo/data.json') >= 0);
  ok('年表数字对得上账本', md.indexOf('| 2026 | 5 |') >= 0, md.split('## 每年')[1]);
  // 有观测、真的一件没做的月份，写 0 是对的；只有"没观测"才必须写破折号
  ok('没观测的月不写 0 件', !/\\| [0-9]+ 月 \\| 0 \\| — \\|/.test(md));
  ok('空月份写破折号', md.indexOf('| 10 月 | — | — |') >= 0);
  ok('导出入口通了', typeof window.__exportReadme === 'function');

  window.__storeState({ state: 'recovered', kept: ['data.corrupt-20261106-1053.json'] });
  var bar = document.getElementById('databar');
  ok('恢复过会亮出来', bar.classList.contains('show'));
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

let bad = 0;
for (const [name, file] of [['三层纠错', caseTruth], ['授权状态', casePerm], ['页签渲染', caseTabs],
  ['欠账与日结', caseDebt], ['本周页签', caseWeek], ['观测口径', caseSeen], ['积压与占比', caseBacklog],
  ['口径一致', caseCaliber], ['导出与状态', caseExport]]) {
  const out = run(file);
  const fails = (out.match(/^FAIL /gm) || []).length;
  const passes = (out.match(/^PASS /gm) || []).length;
  bad += fails;
  console.log(`\n【${name}】PASS ${passes} / FAIL ${fails}`);
  if (fails || passes === 0) console.log(out);
}
console.log(bad === 0 ? '\n全部通过' : `\n有 ${bad} 条失败`);
process.exit(bad === 0 ? 0 : 1);
