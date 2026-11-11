  /* ---------------- 数据：带得走 / 看得见 / 删得掉 ----------------

     这个文件一件统计的事都不做，口径全在 05 / 06。它只管三样：
       1. 生成导出包里那份「读我.md」——不装这个 app 也能读懂自己的数据；
       2. 读盘出过问题时把话说出来，不让用户对着空清单猜；
       3. 把「打开数据文件夹」「导出」这两件事交给原生。

     导出的验收标准只有一条：把这个 zip 发给一个不懂代码的人，
     他能自己回答"我这几年干了多少、从哪天开始记的"。做不到就是没做好。 */

  var storeState = { state: 'normal', kept: [] };

  function two(n) { return n < 10 ? '0' + n : '' + n; }

  function stampNow() {
    var d = new Date();
    return d.getFullYear() + '-' + two(d.getMonth() + 1) + '-' + two(d.getDate())
      + ' ' + two(d.getHours()) + ':' + two(d.getMinutes());
  }

  /* 哪些年有东西：daily / flow 的键、任务的创建时间、加上今年。
     不从"今年往回数 N 年"，那样会把没数据的年份也印出来一排 0。 */
  function yearsWithData() {
    var ys = {}, now = new Date().getFullYear(), i;
    Object.keys(dailyMap()).forEach(function (k) { ys[k.slice(0, 4)] = 1; });
    Object.keys(state.flow || {}).forEach(function (k) { ys[k.slice(0, 4)] = 1; });
    state.nodes.forEach(function (n) {
      if (n.created) ys[String(new Date(n.created).getFullYear())] = 1;
    });
    ys[String(now)] = 1;
    return Object.keys(ys).filter(function (y) {
      return /^[0-9]{4}$/.test(y) && +y >= 2000 && +y <= 2100;
    }).sort();
  }

  /* 导出包里的说明文件。写法要求：不用术语，先给数字，再说怎么读，
     最后交代口径——因为口径不写清，别人会把这个数当成那个数。 */
  function exportReadme() {
    var N = state.nodes.filter(function (n) { return n.type === 'task'; }).length;
    var openN = state.nodes.filter(function (n) { return n.type === 'task' && !n.done; }).length;
    var ds = dataStart();
    /* 当前清单条数 和 历史累计划掉数 是两回事：划掉之后被"一键清除"删掉的条目
       不再占 nodes，但 daily 账本里那几件仍然算数。两个数分开写，
       否则读者会以为对不上。 */
    var ledger = 0;
    var dm = dailyMap();
    Object.keys(dm).forEach(function (k) { ledger += (dm[k] || 0); });
    var L = [];

    L.push('# 浮窗待办 · 数据导出');
    L.push('');
    L.push('导出时间：' + stampNow() + '  ');
    L.push('格式版本：' + SCHEMA_V + '（对应 data.json 里的 `v`）  ');
    L.push('当前清单：' + N + ' 件' + (openN === N ? '，都还没做完' : '，其中 ' + openN + ' 件还没做完') + '  ');
    L.push('历史累计划掉：' + ledger + ' 件（按 `daily` 账本；含已经从清单里清掉的）  ');
    L.push('记录起点：' + (ds ? dayKey(ds) : '还没有记录'));
    L.push('');
    L.push('这个压缩包里有两样东西：');
    L.push('');
    L.push('- **data.json** —— 全部原始数据。纯文本，用任何编辑器都能打开，不需要这个 app。');
    L.push('- **读我.md** —— 就是你正在看的这一份。');
    L.push('');
    L.push('这些数据只在这台机器上。这个应用没有账号、没有服务器、没有任何上报，');
    L.push('也没有埋点——它不知道你打开了它几次。');
    L.push('');

    /* ---------- 每年 ---------- */
    var years = yearsWithData();
    if (years.length) {
      L.push('## 每年');
      L.push('');
      L.push('| 年份 | 划掉 | 有产出的天 | 看得见的天 | 最长连续 |');
      L.push('| --- | --- | --- | --- | --- |');
      years.forEach(function (y) {
        var r = yearStats(+y);
        if (!r.observed && !r.total) return;
        L.push('| ' + y + ' | ' + r.total + ' | ' + r.active + ' | ' + r.observed
          + ' | ' + (r.longest >= 2 ? r.longest + ' 天' : '—') + ' |');
      });
      L.push('');
      L.push('「看得见的天」= 那天这个 app 开着，或者有过操作，或者有划掉记录。');
      L.push('「有产出的天」= 那天至少划掉一件。这两个数不一样时，');
      L.push('任何"平均每天多少"都该用「看得见的天」当分母，而不是日历天数。');
      L.push('');

      /* ---------- 按月 ---------- */
      var curY = new Date().getFullYear();
      var months = yearMonths(curY), mobs = monthObserved(curY);
      // 从有记录的那个月开始印：更早的月份本来就没在使用，一行"—"也没有信息
      var fromM = 0;
      if (ds && new Date(ds).getFullYear() === curY) fromM = new Date(ds).getMonth();
      L.push('## 按月（' + curY + '）');
      L.push('');
      L.push('| 月 | 划掉 | 有记录的天 |');
      L.push('| --- | --- | --- |');
      for (var m = fromM; m < 12; m++) {
        var ob = mobs[m] || 0;
        // 一天都没看见的月份不写 0 件：那是"没记录"，不是"没做"
        L.push('| ' + (m + 1) + ' 月 | ' + (ob ? months[m] : '—') + ' | ' + (ob || '—') + ' |');
      }
      L.push('');
    }

    /* ---------- 清单 ---------- */
    var open = state.nodes.filter(function (n) { return n.type === 'task' && !n.done; });
    if (open.length) {
      L.push('## 导出时还没做完的（' + open.length + ' 件）');
      L.push('');
      open.slice(0, 60).forEach(function (n) {
        L.push('- ' + String(n.text || '').replace(/\n/g, ' '));
      });
      if (open.length > 60) L.push('- …还有 ' + (open.length - 60) + ' 件');
      L.push('');
      L.push('这里只列标题。项目名、文件路径、提醒时间都在 data.json 里。');
      L.push('');
    }

    /* ---------- 字段说明 ---------- */
    L.push('## data.json 里都有什么');
    L.push('');
    L.push('| 键 | 含义 |');
    L.push('| --- | --- |');
    L.push('| `v` | 格式版本。加字段只加不改，这个数跟着走 |');
    L.push('| `nodes` | 全部条目（任务、项目、文件节点）。`done` 是划掉标记 |');
    L.push('| `seq` | 下一个条目 id。清空数据后会回到 1 |');
    L.push('| `daily` | `{"日期": 划掉件数}`。是**账本**，只累加，不回改 |');
    L.push('| `log` | 最近 60 天的划掉明细 `{id, at, d, p}`（`p` = 划掉时挂的项目 id）。只用来算"什么时段出活" |');
    L.push('| `flow` | `{"日期": {n: 新写, x: 删掉（当时没做完）, q: 认赔（销账）}}` 当天的进出流水 |');
    L.push('| `seen` | `{"日期": 1}` 这天应用开着。**没有这个键不代表 0 件**；永久保留，不裁剪 |');
    L.push('| `seenFrom` | 从哪天开始能判断"这天有没有记录" |');
    L.push('| `settle` | 日结条已经给哪天看过（一天只出现一次） |');
    L.push('| `gap` | 你对某天做的对账（0 = 那天确实没做事，1 = 忘了记） |');
    L.push('| `gapOff` | "别问"按到哪天为止（14 天内不再问对账） |');
    L.push('| `said` | 按月存的判断句原文（月级投票拿它当依据） |');
    L.push('| `vote` | 哪个月投过哪句"准/不准"（每句每月只投一次） |');
    L.push('| `hide` / `fb` / `saidN` | 你否掉过的来源行、纠正记录、判断句被说"不准"的累计次数 |');
    L.push('| `byProj` | 按项目汇总的件数（记的是项目 id，项目改名会跟着变） |');
    L.push('| `anniv` | 哪一年的年度公告看过了 |');
    L.push('');
    L.push('同目录还有一个 `focus.json`：前台 App 计时（只留最近 7 天），');
    L.push('它和 `data.json` 一起打进了这个压缩包。');
    L.push('');

    /* ---------- 怎么恢复 ---------- */
    L.push('## 怎么用回这些数据');
    L.push('');
    L.push('把 `data.json` 放回这个位置，重新打开应用就行：');
    L.push('');
    L.push('```');
    L.push('~/Library/Application Support/DeskTodo/data.json');
    L.push('```');
    L.push('');
    L.push('整个文件夹可以直接替换。应用启动时如果发现主文件读不出来，');
    L.push('会自动用同目录的 `data.json.bak`（上一版），并把坏掉的原文件');
    L.push('改名成 `data.corrupt-时间.json` 留着，不会覆盖掉。');
    L.push('');

    /* ---------- 口径 ---------- */
    L.push('## 这份数据的三条规矩');
    L.push('');
    L.push('1. **没记录 ≠ 0 件。** 那天没有 `daily` 键、`seen` 里也没有，说明我不知道，');
    L.push('   不是你没做。所有图表里"描边"就是这个意思，只有浅填充才是真的 0。');
    L.push('2. **历史不回改。** 今天的口径只影响今天往后，`daily` 和 `seen` 里的旧记录永远不动。');
    L.push('   `seen` 也是账本的一部分：它一旦被裁掉，「看得见的天」和「最长连续」就会在几年后自己变小，');
    L.push('   所以它永久保留（一天一个键）。');
    L.push('3. **不替你补记。** 系统不会猜"你大概是那天做的"，也不会把漏记的算进平均。');
    L.push('');
    L.push('所以「最长连续」永远是下界：中间有我看不见的日子，那一串就在那儿断开。');
    L.push('真实值只会更长，不会更短。');
    L.push('');

    return L.join('\n');
  }

  window.__exportReadme = exportReadme;

  /* 读盘出过什么事，界面得说。normal / fresh 不占任何像素。 */
  window.__storeState = function (o) {
    if (!el.databar) return;
    storeState = o && typeof o === 'object' ? o : { state: 'normal', kept: [] };
    var k = storeState.state || 'normal';
    if (k === 'normal' || k === 'fresh') {
      el.databar.classList.remove('show');
      scheduleResize();
      return;
    }
    var kept = (storeState.kept && storeState.kept[0]) || '';
    var t;
    if (k === 'recovered') {
      t = '上次的数据文件读不出来，已经用上一版备份恢复了。' + (kept ? '坏的那份留着：' + kept : '');
    } else {
      t = '数据文件读不出来，备份也没有。清单现在是空的，原文件没删。'
        + (kept ? '（' + kept + '）' : '');
    }
    el.dbText.textContent = t;
    el.dbText.title = t;
    el.databar.classList.add('show');
    lastHeight = 0;
    scheduleResize();
    setTimeout(scheduleResize, 200);
  };

  if (el.dbGo) el.dbGo.addEventListener('click', function (e) {
    e.stopPropagation();
    send('revealStore');
  });

  if (el.dbX) el.dbX.addEventListener('click', function (e) {
    e.stopPropagation();
    el.databar.classList.remove('show');
    lastHeight = 0;
    scheduleResize();
  });

  window.__storeStateNow = function () { return storeState; };

  /* 反馈用的一段纯文本。铁律：**只有计数和状态，没有一个字的任务内容**，
     也没有日历标题、文件名、屏幕 app 名。
     本地优先的产品不该为了拿反馈去搬用户的东西——想知道哪里坏了，
     数得清的东西就够了。 */
  function diagText() {
    var L = [];
    var now = new Date();
    L.push('浮窗待办 · 诊断信息');
    L.push('时间：' + stampNow());
    L.push('格式版本：' + SCHEMA_V);
    L.push('页面：' + (reportOpen ? '报告已打开' : '报告未打开')
      + (collapsed ? ' · 收起态' : '') + (manualSaved ? ' · 手动尺寸' : ' · 自适应'));
    L.push('');

    var tasks = state.nodes.filter(function (n) { return n.type === 'task'; });
    var projs = state.nodes.filter(function (n) { return n.type === 'project'; });
    var ledger = 0, dm = dailyMap();
    Object.keys(dm).forEach(function (k) { ledger += (dm[k] || 0); });
    L.push('清单：' + tasks.length + ' 件任务（未划掉 ' + tasks.filter(function (n) { return !n.done; }).length + '）'
      + ' · 项目 ' + projs.length + ' 个');
    L.push('账本：累计划掉 ' + ledger + ' 件 · 有记录的天 ' + Object.keys(dm).length
      + ' · seen ' + Object.keys(state.seen || {}).length + ' 天');
    L.push('记录起点：' + (dataStart() ? dayKey(dataStart()) : '无'));
    L.push('');

    /* 来源状态：只写 ok / ask / denied / nofda 这类枚举，不写读到了什么 */
    var keys = ['cal', 'rem', 'screen', 'focus'];
    if (ext) {
      keys.forEach(function (k) {
        var s = ext[k] || {};
        L.push('来源 ' + k + '：' + (s.st || '无')
          + (s.sec !== undefined ? ' · ' + Math.round(s.sec / 60) + ' 分钟' : '')
          + (s.why ? ' · ' + s.why : ''));
      });
      if (ext.cal && ext.cal.hcal) L.push('节假日日历：' + (ext.cal.hcal.length ? '已订阅（' + ext.cal.hcal.length + ' 本）' : '没订阅'));
    } else {
      L.push('来源：还没读到（ext = null）');
    }
    if (ext && ext.session) {
      var se = ext.session;
      L.push('会话：' + (se.away ? '离开' : '在前台') + ' · 空闲 ' + (se.idle || 0) + ' 秒'
        + (se.locked ? ' · 锁屏' : '') + (se.screenoff ? ' · 熄屏' : '') + (se.asleep ? ' · 睡眠' : ''));
    }
    L.push('数据文件状态：' + (storeState.state || 'normal')
      + (storeState.kept && storeState.kept.length ? ' · 留证 ' + storeState.kept.length + ' 个' : ''));
    L.push('窗口：高 ' + Math.round(document.getElementById('wrap').getBoundingClientRect().height)
      + ' css px · 缩放 ' + uiScale);
    L.push('你纠正过我：' + (state.fb ? state.fb.length : 0) + ' 次 · 隐藏来源行 '
      + Object.keys(state.hide || {}).length + ' 行');
    L.push('');
    L.push('（这份信息不含任何任务内容、日历标题、文件名或 app 名）');
    return L.join('\n');
  }

  window.__diagText = diagText;
