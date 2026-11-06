  /* ---------------- 今日数据 / 天气 / 文案 ----------------
     统计口径：
     - 「完成」记一份独立流水（id + 时间），这样"一键清除"删掉任务也不会把历史抹掉
     - 分母 = 今天已完成的 + 还没做完且到期日 ≤ 今天的
     - 老数据没有流水，按任务的 doneAt/due 兜底回填，只读不写盘 */

  function prevDay(ts) {
    var d = new Date(ts);
    d.setDate(d.getDate() - 1);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  function logArray() {
    if (!Array.isArray(state.log)) state.log = [];
    return state.log;
  }

  function pruneLog() {
    var cut = todayStart() - 60 * 86400000;
    state.log = logArray().filter(function (e) {
      return e && typeof e.at === 'number' && e.at >= cut;
    });
    if (state.log.length > 500) state.log = state.log.slice(state.log.length - 500);
  }

  /* 记账口径：
     - daily：每天完成多少件，永久保留（一年 365 个键，几 KB）。这是统计的唯一依据。
     - log：最近 60 天的明细，只用来算"什么时段出活"，超期就丢。
     删任务 / 一键清除都不碰这两个，所以历史不会被抹掉。 */

  function dayKey(ts) {
    var d = new Date(ts);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  }

  function dailyMap() {
    if (!state.daily || typeof state.daily !== 'object') state.daily = {};
    return state.daily;
  }

  function bumpDay(ts, delta) {
    var m = dailyMap(), k = dayKey(ts);
    var v = Math.max(0, (m[k] || 0) + delta);
    if (v) m[k] = v; else delete m[k];
  }

  /* 入账 / 出账：只在"新建任务"和"删掉没做完的任务"时记一笔。
     daily 记的是「做完几件」，这里补的是「攒了几件、丢掉几件」——
     没有这三个数，就只能看到你完成了什么，看不到你放弃了什么。 */
  function flowMap() {
    if (!state.flow || typeof state.flow !== 'object') state.flow = {};
    return state.flow;
  }

  function bumpFlow(kind, delta) {
    var m = flowMap(), k = dayKey(Date.now());
    var e = m[k] || { n: 0, x: 0 };
    e[kind] = Math.max(0, (e[kind] || 0) + delta);
    if (!e.n && !e.x) delete m[k]; else m[k] = e;
  }

  /* 某一天新增了几件待办（老数据没有这一层，返回 0，不猜） */
  function dayNew(day) {
    var e = flowMap()[dayKey(day)];
    return (e && e.n) || 0;
  }

  /* 某一天被删掉了几件没做完的 */
  function dayDrop(day) {
    var e = flowMap()[dayKey(day)];
    return (e && e.x) || 0;
  }

  /* 主题分布：按"这件挂在哪棵项目树下"累计，每年一份。
     只记项目 id，不记名字——项目改名后自动跟着变，删了才显示"已删的项目"。
     id 0 = 直接写在顶层的散项。 */
  function projMap() {
    if (!state.byProj || typeof state.byProj !== 'object') state.byProj = {};
    return state.byProj;
  }

  function projOf(t) {
    var cur = t, guard = 0;
    while (cur && guard++ < 12) {
      if (cur.type === 'project') return cur.id;
      if (!cur.parentId) return 0;
      cur = byId(cur.parentId);
    }
    return 0;
  }

  function bumpProj(t, delta, ts) {
    var y = String(new Date(ts || Date.now()).getFullYear());
    var m = projMap();
    var row = m[y] || (m[y] = {});
    var k = String(projOf(t) || 0);
    var v = Math.max(0, (row[k] || 0) + delta);
    if (v) row[k] = v; else delete row[k];
    if (!Object.keys(row).length) delete m[y];
  }

  /* 今年干得最多的几个项目，只报占比，不排名次。
     byProj 是从加了"项目"之后才开始记的，早于它的完成没有归属。
     所以当挂过项目的件数明显少于全年完成数时，百分比的分母就是残缺的——
     这种情况宁可不报，也不给一个看起来像"占全年的 67%"的假数。 */
  function projLine(year, total) {
    var row = projMap()[String(year)] || {};
    var items = [], sum = 0;
    Object.keys(row).forEach(function (k) {
      var n = row[k] || 0;
      if (!n) return;
      var name = (k === '0') ? '没挂项目' : (((byId(Number(k)) || {}).text) || '已删的项目');
      items.push({ name: name, n: n });
      sum += n;
    });
    if (!items.length || sum < 5) return '';
    if (typeof total === 'number' && total > 0 && sum < total * 0.9) {
      return '<div class="r-proj"><span class="r-proj-t">大头</span>'
        + '<span class="r-pj r-pj-o">还算不了：只有 ' + sum + ' / ' + total + ' 件挂过项目</span></div>';
    }
    items.sort(function (a, b) { return b.n - a.n; });
    var top = items.slice(0, 3);
    var named = 0;
    var html = '';
    top.forEach(function (it) {
      named += it.n;
      html += '<span class="r-pj"><b>' + escapeHtml(it.name) + '</b> ' + Math.round(it.n / sum * 100) + '%</span>';
    });
    if (sum - named > 0) {
      html += '<span class="r-pj r-pj-o">其他 ' + Math.round((sum - named) / sum * 100) + '%</span>';
    }
    return '<div class="r-proj"><span class="r-proj-t">大头</span>' + html + '</div>';
  }

  function markDone(t) {
    t.done = true;
    t.doneAt = Date.now();
    logArray().push({ id: t.id, at: t.doneAt, d: dayStart(t.doneAt) });
    bumpDay(t.doneAt, 1);
    bumpProj(t, 1, t.doneAt);
    pruneLog();
  }

  function markUndone(t) {
    t.done = false;
    delete t.doneAt;
    var log = logArray();
    for (var i = log.length - 1; i >= 0; i--) {
      if (log[i].id === t.id) {
        bumpDay(log[i].at, -1);
        bumpProj(t, -1, log[i].at);
        log.splice(i, 1);
        break;
      }
    }
  }

  function dayDone(day) { return dailyMap()[dayKey(day)] || 0; }

  /* ---------------- 「没记录」和「0 件」是两件事 ----------------
     完成 0 件只有在我看得见的那天才成立。有三种证据说明"我看见过这天"：
       1. 账本里有完成记录（必然开着）
       2. seen 里有这个戳（app 那天开过）
       3. 流水里有新建/删除（有操作）
     三样都没有 = 不知道。不知道就不许写成 0，也不许进任何分母。 */
  function daySeen(day) { return !!(state.seen && state.seen[dayKey(day)]); }

  function dayObserved(day) {
    if (dayDone(day) > 0) return true;
    if (daySeen(day)) return true;
    var f = (state.flow || {})[dayKey(day)];
    return !!(f && ((f.n || 0) + (f.x || 0) > 0));
  }

  /* 打开就盖一个戳：只记"这天 app 开着"，不记任何内容。
     返回 true 表示这是今天第一次，调用方负责存盘。 */
  /* 「YYYY-MM-DD」→ 本地零点时间戳（不走 Date 对字符串的 UTC 解析，避免差一天） */
  function keyToTs(k) {
    if (!k || k.length < 10) return 0;
    return new Date(+k.slice(0, 4), +k.slice(5, 7) - 1, +k.slice(8, 10)).getTime();
  }

  /* 这个 app 里最早的一条数据是哪天。在这之前既不是 0 件，也不是"不知道"，
     而是"还没有这一段"——三件事要分开画。 */
  function dataStart() {
    var t = 0;
    function bump(v) { if (v && (!t || v < t)) t = v; }
    bump(keyToTs(state.seenFrom));
    Object.keys(state.daily || {}).forEach(function (k) { bump(keyToTs(k)); });
    Object.keys(state.flow || {}).forEach(function (k) { bump(keyToTs(k)); });
    (state.nodes || []).forEach(function (n) { if (n.created) bump(dayStart(n.created)); });
    return t;
  }

  function markSeen() {
    if (!state.seen) state.seen = {};
    var k = dayKey(Date.now());
    if (!state.seenFrom) state.seenFrom = k;   // 只写一次，之后不随裁剪变动
    if (state.seen[k]) return false;
    state.seen[k] = 1;
    var keys = Object.keys(state.seen).sort();
    if (keys.length > 800) {
      keys.slice(0, keys.length - 800).forEach(function (x) { delete state.seen[x]; });
    }
    return true;
  }

  function statsToday() {
    var t0 = todayStart();
    var done = dayDone(t0);
    var pending = 0, carried = 0;
    state.nodes.forEach(function (n) {
      if (n.type !== 'task' || n.done) return;
      if (n.due <= t0) {
        pending++;
        if ((n.carried || 0) >= 2) carried++;
      }
    });
    return { done: done, pending: pending, total: done + pending, carried: carried };
  }

  /* 连续天数：今天还没开张不算断，从昨天往前数 */
  /* 连续有产出的天数。碰到"我没看见过的那天"就停：
     不跨过未知继续数，否则会把"中间不知道"说成"一直连着"。 */
  function streakDays() {
    var d = todayStart();
    if (dayDone(d) === 0) d = prevDay(d);
    var n = 0;
    while (n < 400 && dayObserved(d) && dayDone(d) > 0) { n++; d = prevDay(d); }
    return n;
  }

  function peakSlot() {
    var cut = todayStart() - 6 * 86400000;
    var b = { '早上': 0, '上午': 0, '下午': 0, '晚上': 0 };
    logArray().forEach(function (e) {
      if (!e || e.at < cut) return;
      var h = new Date(e.at).getHours();
      var k = h < 9 ? '早上' : h < 12 ? '上午' : h < 18 ? '下午' : '晚上';
      b[k]++;
    });
    var best = '', n = 0;
    Object.keys(b).forEach(function (k) { if (b[k] > n) { n = b[k]; best = k; } });
    return n >= 5 ? best : '';
  }

  /* --- 天气（WMO code 映射成人话 + 一个调皮图标） --- */
  function wxInfo(code, isDay) {
    var c = code || 0;
    function w(icon, label, tone) { return { icon: icon, label: label, tone: tone }; }
    if (c === 0) return w(isDay ? '☀️' : '🌙', isDay ? '晴' : '晴夜', 'clear');
    if (c === 1) return w(isDay ? '🌤️' : '🌙', '晴间多云', 'clear');
    if (c === 2) return w('⛅️', '多云', 'cloud');
    if (c === 3) return w('☁️', '阴', 'cloud');
    if (c === 45 || c === 48) return w('🌫️', '雾', 'fog');
    if (c >= 51 && c <= 57) return w('🌦️', '毛毛雨', 'rain');
    if (c >= 61 && c <= 67) return w('🌧️', '雨', 'rain');
    if (c >= 71 && c <= 77) return w('❄️', '雪', 'snow');
    if (c >= 80 && c <= 82) return w('🌦️', '阵雨', 'rain');
    if (c === 85 || c === 86) return w('🌨️', '阵雪', 'snow');
    if (c >= 95) return w('⛈️', '雷阵雨', 'storm');
    return w('🌡️', '天气', 'cloud');
  }

  function renderWeather() {
    if (!el.wx) return;
    if (!weather || typeof weather.temp !== 'number') { el.wx.classList.add('off'); return; }
    var wi = wxInfo(weather.code, weather.isDay);
    el.wx.classList.remove('off');
    el.wxIcon.textContent = wi.icon;
    el.wxTemp.textContent = Math.round(weather.temp) + '°';
    var head = (weather.city ? weather.city + ' · ' : '') + wi.label + ' ' + Math.round(weather.temp) + '°';
    var extra = [];
    if (typeof weather.tmax === 'number' && typeof weather.tmin === 'number')
      extra.push('最高 ' + Math.round(weather.tmax) + '° / 最低 ' + Math.round(weather.tmin) + '°');
    if (typeof weather.rain === 'number' && weather.rain > 0) extra.push('降水 ' + Math.round(weather.rain) + '%');
    if (typeof weather.hum === 'number') extra.push('湿度 ' + Math.round(weather.hum) + '%');
    el.wx.title = head + (extra.length ? '\n' + extra.join(' · ') : '') + '\n点一下更新';
  }

  window.__onWeather = function (w) {
    // 关了联网就把胶囊一起摘掉：留着上次的数字，等于让人以为它还在更新
    if (w && w.off) { weather = null; renderWeather(); renderSub(); if (reportOpen) renderReport(); return; }
    if (!w || typeof w !== 'object') return;
    weather = w;
    renderWeather();
    renderSub();
    if (reportOpen) renderReport();
  };

  /* --- 开场白 / 小文案：时段 × 天气 × 进度，15 分钟换一句 --- */
  var VIBE = {
    dawn: [
      '清单还没热，咖啡先热。',
      '先啃硬的那块。',
      '先开个头，别急着发力。',
      '今天不用很猛。'
    ],
    am: [
      '上午留给硬活。',
      '消息晚点再回。',
      '一次只开一个头。',
      '脑子最贵的两小时。'
    ],
    noon: [
      '先解决胃，再解决清单。',
      '歇十分钟再战。',
      '犯困就挑机械的做。'
    ],
    pm: [
      '靠完成一件来提神。',
      '过半了，剩下的没几口。',
      '再推两件就收工。'
    ],
    dusk: [
      '天黑了，收个尾。',
      '剩下的明天再说。',
      '把没做完的顺一天。'
    ],
    night: [
      '该睡了，清单不会跑。',
      '深夜别做决定。',
      '明天闹钟往后挪十分钟。'
    ],
    done: [
      '清空了，去晒太阳。',
      '今天到此为止。',
      '剩下的时间归你。'
    ],
    empty: [
      '空白的一天也算安排。',
      '写一条就算开始。',
      '不着急，想到再写。'
    ]
  };

  function pickLine(arr, k) { return arr[Math.abs(k) % arr.length]; }

  function weatherLines() {
    if (!weather) return [];
    var wi = wxInfo(weather.code, weather.isDay);
    var t = weather.temp || 0;
    if (wi.tone === 'rain' || wi.tone === 'storm')
      return ['下雨了，正好收尾。', '带伞了吗？', '雨天把欠的还了。'];
    if (wi.tone === 'snow')
      return ['下雪了，路上慢点。', '这种天适合窝着干活。'];
    if (wi.tone === 'fog')
      return ['雾大，出门看路。'];
    if (t >= 30)
      return ['太热了，多喝水。', '别把自己烤太干。'];
    if (t <= 5)
      return ['冷，出门多穿一件。', '手冷就先做简单的。'];
    if (wi.tone === 'clear' && weather.isDay)
      return ['天不错，干点正事。', '别全耗在屏幕上。'];
    if (wi.tone === 'cloud')
      return ['阴天，适合窝着干活。'];
    return [];
  }

  function vibeLine() {
    var h = new Date().getHours();
    var k = Math.floor(Date.now() / 900000);   // 15 分钟一换，不会每秒乱跳
    var st = statsToday();
    if (st.total === 0) return pickLine(VIBE.empty, k);
    if (st.pending === 0) return pickLine(VIBE.done, k);
    var slot = h < 5 ? 'night' : h < 9 ? 'dawn' : h < 12 ? 'am' : h < 14 ? 'noon'
      : h < 18 ? 'pm' : h < 21 ? 'dusk' : 'night';
    var wl = weatherLines();
    if (wl.length && k % 3 === 0) return pickLine(wl, k);
    return pickLine(VIBE[slot], k);
  }

  function renderSub() {
    var d = new Date();
    var line = vibeLine();
    // 只有一行字的空间：日期交给日程头和报告卡，这里专心说人话
    if (el.sub.textContent !== line) el.sub.textContent = line;
    el.sub.title = (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + weekday(d) + ' · ' + line;
  }

  function updateProgress() {
    if (!el.prog) return;
    var st = statsToday();
    var ratio = st.total ? st.done / st.total : 0;
    if (el.ringFg) el.ringFg.style.strokeDashoffset = (54 * (1 - ratio)).toFixed(1);
    var label = st.done + '/' + st.total;
    if (el.progN.textContent !== label) el.progN.textContent = label;
    el.prog.classList.toggle('full', st.total > 0 && st.pending === 0);
    el.prog.title = st.total
      ? '今日 ' + st.done + '/' + st.total + ' · 完成 ' + Math.round(ratio * 100) + '% · 点击看今日报告'
      : '今天还没有安排 · 点击看今日报告';
  }

