  /* ---------------- 报告卡：今日 / 30 天 / 半年 / 今年 ----------------
     所有数字都来自 daily 账本，没有任何推算和补数据。 */

  var reportTab = 'day';

  /* 往前推 n 天（按日历走，不按 86400000 硬减） */
  function prevDayN(ts, n) {
    var d = new Date(ts);
    d.setDate(d.getDate() - n);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }

  function shortDate(ts) {
    var d = new Date(ts);
    return (d.getMonth() + 1) + '/' + d.getDate();
  }

  function rangeDays(n) {
    var t0 = todayStart(), out = [];
    for (var i = n - 1; i >= 0; i--) out.push(prevDayN(t0, i));
    return out;
  }

  function rangeStats(n) {
    var days = rangeDays(n);
    var total = 0, active = 0, observed = 0, best = { day: 0, n: 0 };
    days.forEach(function (d) {
      var c = dayDone(d);
      total += c;
      if (c > 0) active++;
      if (dayObserved(d)) observed++;
      if (c > best.n) best = { day: d, n: c };
    });
    /* observed = 这 n 天里我确实看得见的天数。
       它和 days 的差，是"我不知道"，不是"你没做"——任何日均都要用它当分母。 */
    return { total: total, active: active, observed: observed,
             best: best, days: n, avg: observed ? total / observed : 0 };
  }

  function longestStreak(n) {
    var best = 0, cur = 0;
    rangeDays(n).forEach(function (d) {
      if (dayDone(d) > 0) { cur++; if (cur > best) best = cur; } else cur = 0;
    });
    return best;
  }

  /* 热力图：每格一天，7 行一周，从起始日所在周的周日开始铺 */
  function heatSvg(startTs, endTs) {
    // 有数据之前的那些天：不画成 0 件，也不画成"不知道"，淡化掉
    var ds = dataStart();
    var gridStart = prevDayN(startTs, new Date(startTs).getDay());
    var total = Math.round((dayStart(endTs) - gridStart) / 86400000) + 1;
    var cols = Math.ceil(total / 7);
    var S = 5, G = 1.2, rx = 1.2;
    var W = cols * (S + G) - G, H = 7 * (S + G) - G;
    var out = '<svg class="r-heat" viewBox="0 0 ' + W + ' ' + H + '">';
    for (var i = 0; i < total; i++) {
      var d = prevDayN(gridStart, -i);
      // 起点之前那几格是补齐整周的，别把去年的事算进"今年"
      var inRange = d >= startTs && (!ds || d >= ds);
      var c = inRange ? dayDone(d) : 0;
      // 没看见过的那天不填色，只描个空框：空白 = 不知道，浅色 = 知道且是 0 件
      var obs = inRange && dayObserved(d);
      var lv = c === 0 ? 0 : c <= 2 ? 1 : c <= 4 ? 2 : c <= 7 ? 3 : 4;
      var cls = !inRange ? 'hc-off' : obs ? 'hc' + lv : 'hc-unk';
      var tip = !inRange ? '' : obs ? shortDate(d) + ' · ' + c + ' 件' : shortDate(d) + ' · 没记录';
      var col = Math.floor(i / 7), row = i % 7;
      out += '<rect class="' + cls + '" x="' + (col * (S + G)) + '" y="' + (row * (S + G))
        + '" width="' + S + '" height="' + S + '" rx="' + rx + '">'
        + '<title>' + tip + '</title></rect>';
    }
    return out + '</svg>';
  }

  function sevenBars() {
    var t0 = todayStart(), counts = [], max = 1, sum = 0;
    for (var i = 6; i >= 0; i--) {
      var day = prevDayN(t0, i);
      var c = dayDone(day);
      counts.push({ day: day, c: c, obs: dayObserved(day) });
      sum += c;
      if (c > max) max = c;
    }
    /* "一件没勾"和"我没开过"是两件事。这条以前只判 sum，于是整周开着但没勾东西时，
       图表说"还没有记录"、下面那行总结说"我开着，一件都没勾"——同一屏里两句话打架。 */
    if (!sum) {
      var anyObs7 = counts.some(function (x) { return x.obs; });
      return '<div class="r-empty">' + (anyObs7
        ? '这 7 天都开着，一件没勾'
        : '近 7 天还没有记录，勾掉第一件就会长出来') + '</div>';
    }
    var bars = '';
    counts.forEach(function (it) {
      var hgt = 3 + Math.round(it.c / max * 18);
      var dd = new Date(it.day);
      var isToday = dayStart(it.day) === t0;
      var lab = isToday ? '今' : ['日', '一', '二', '三', '四', '五', '六'][dd.getDay()];
      bars += '<div class="r-bar' + (isToday ? ' today' : '') + '" title="'
        + (it.obs ? shortDate(it.day) + ' 完成 ' + it.c + ' 件' : shortDate(it.day) + ' 没记录') + '">'
        + '<i class="' + (isToday ? 'on ' : '') + (it.obs ? '' : 'unk') + '" style="height:' + hgt + 'px"></i>'
        + '<u>' + lab + '</u></div>';
    });
    return bars;
  }

  /* 本周：周一算一周的头。只画到今天——后面的天还没发生，
     画成 0 会让"这周还没过完"看起来像"这周不行"。 */
  function weekIdx(ts) {
    var wd = new Date(ts || todayStart()).getDay();   // 0 = 周日
    return (wd + 6) % 7;                              // 0 = 周一
  }

  function weekBars(n) {
    var t0 = todayStart();
    var start = prevDayN(t0, weekIdx(t0));
    var counts = [], max = 1, sum = 0;
    for (var i = 0; i < n; i++) {
      var day = prevDayN(start, -i);
      var c = dayDone(day);
      counts.push({ day: day, c: c, obs: dayObserved(day) });
      sum += c;
      if (c > max) max = c;
    }
    if (!sum) {
      var anyObsW = counts.some(function (x) { return x.obs; });
      return '<div class="r-empty">' + (anyObsW
        ? '这周开着，一件没勾'
        : '这周还没有记录，勾掉第一件就会长出来') + '</div>';
    }
    var lab = ['一', '二', '三', '四', '五', '六', '日'];
    var bars = '';
    counts.forEach(function (it, i) {
      var hgt = 3 + Math.round(it.c / max * 18);
      var isToday = dayStart(it.day) === t0;
      bars += '<div class="r-bar' + (isToday ? ' today' : '') + '" title="'
        + (it.obs ? shortDate(it.day) + ' 完成 ' + it.c + ' 件' : shortDate(it.day) + ' 没记录') + '">'
        + '<i class="' + (isToday ? 'on ' : '') + (it.obs ? '' : 'unk') + '" style="height:' + hgt + 'px"></i>'
        + '<u>' + (isToday ? '今' : lab[i]) + '</u></div>';
    });
    return bars;
  }

  function thirtyBars(n) {
    var t0 = todayStart(), max = 1, bars = '';
    var list = rangeDays(n);
    list.forEach(function (d) { var c = dayDone(d); if (c > max) max = c; });
    list.forEach(function (d) {
      var c = dayDone(d);
      var hgt = 2 + Math.round(c / max * 32);
      var ob = dayObserved(d);
      bars += '<div class="r-bar" title="' + (ob ? shortDate(d) + ' · ' + c + ' 件' : shortDate(d) + ' · 没记录') + '">'
        + '<i class="' + (d === t0 ? 'on ' : '') + (ob ? '' : 'unk') + '" style="height:' + hgt + 'px"></i></div>';
    });
    return '<div class="r-week r-week-tight">' + bars + '</div>';
  }

  /* 一整年的统计：从 1/1 起算，往年算到 12/31，今年算到今天。
     不复用 rangeStats，因为那是"最近 N 天"，跨年那天会算错。 */
  function yearStats(year) {
    var now = new Date();
    var start = new Date(year, 0, 1).getTime();
    var end = (year === now.getFullYear()) ? todayStart() : new Date(year, 11, 31).getTime();
    var days = Math.round((dayStart(end) - start) / 86400000) + 1;
    var total = 0, active = 0, observed = 0;
    var best = { day: 0, n: 0 }, cur = 0, longest = 0;
    for (var i = 0; i < days; i++) {
      var dd = prevDayN(start, -i);
      var c = dayDone(dd);
      total += c;
      if (dayObserved(dd)) observed++;
      // 没看见过的日子既不能接龙也不能算 0，只能当成断点。
      // 所以这个"最长连续"是下界：真实值只会更长，不会更短。
      if (dayObserved(dd) && c > 0) { active++; cur++; if (cur > longest) longest = cur; }
      else cur = 0;
      if (c > best.n) best = { day: dd, n: c };
    }
    /* days    = 日历上过了多少天
       observed = 其中我确实看得见的天数（有记录 / app 开着 / 有操作）
       两个数不一样的时候，任何"平均到每天"都必须用 observed 当分母 */
    return { total: total, active: active, observed: observed, days: days,
             best: best, longest: longest, start: start, end: dayStart(end) };
  }

  /* 12 个月各做了多少件：扫一遍 daily 的键分月累加，不另建月表 */
  function yearMonths(year) {
    var out = [], i;
    for (i = 0; i < 12; i++) out.push(0);
    var m = dailyMap(), pre = String(year) + '-';
    Object.keys(m).forEach(function (k) {
      if (k.indexOf(pre) !== 0) return;
      var mi = parseInt(k.slice(5, 7), 10) - 1;
      if (mi >= 0 && mi < 12) out[mi] += (m[k] || 0);
    });
    return out;
  }

  /* 每个月里我"看得见"的天数。0 天的月不画柱子，也不写"0 件"——
     那不是零，那是没记录。 */
  function monthObserved(year) {
    var out = [], i;
    for (i = 0; i < 12; i++) out.push(0);
    var d = new Date(year, 0, 1);
    while (d.getFullYear() === year) {
      if (dayObserved(d.getTime())) out[d.getMonth()]++;
      d.setDate(d.getDate() + 1);
    }
    return out;
  }

  /* 当年新增 / 删掉（没做完的）。days 是"有记账动作的天数"——
     这一层是后加的，老账本里没有，没记过就别硬算成 0，那会读成"一件没写"。 */
  function yearFlow(year) {
    var nw = 0, dr = 0, days = 0, wr = 0, anyQ = false, f = flowMap(), pre = String(year) + '-';
    Object.keys(f).forEach(function (k) {
      if (k.indexOf(pre) !== 0) return;
      var e = f[k] || {};
      nw += e.n || 0;
      dr += e.x || 0;
      // q = 销账（认赔）。老账本里没有这一层，所以有 q 才敢说"认赔几件"
      if (typeof e.q === 'number') { wr += e.q; anyQ = true; }
      days++;
    });
    return { nw: nw, dr: dr, days: days, wr: wr, anyQ: anyQ };
  }

  /* 被往后推了 N 天以上、现在还没做完的。
     【坑】不能用 due 判：rollover() 每晚把没做完的 due 改写成今天，
     due <= 七天前 永远不成立，这句话永远说不出来（等于永远在骗自己"没有积压"）。
     真正记着拖延的是 carried（跨夜顺延时累加）。 */
  function staleCount(days) {
    var n = 0;
    state.nodes.forEach(function (x) {
      if (x.type !== 'task' || x.done) return;
      if ((x.carried || 0) >= days) n++;
    });
    return n;
  }

  /* 现在手里压着多少、平均被推了几天。
     口径是「此刻」，不是「今年」——所以话里必须写明"现在"。
     没被推过的（carried 0 或没有）不计入平均。 */
  function backlogStats() {
    var t0 = todayStart(), n = 0, pushed = 0, sum = 0;
    state.nodes.forEach(function (x) {
      if (x.type !== 'task' || x.done || !x.due || x.due > t0) return;
      n++;
      var c = x.carried || 0;
      if (c >= 1) { pushed++; sum += c; }
    });
    return { n: n, pushed: pushed, avg: pushed ? sum / pushed : 0 };
  }

  function backlogLine() {
    var b = backlogStats();
    if (!b.n) return '';
    var s = '现在还有 <b>' + b.n + '</b> 件没做';
    if (b.pushed) {
      s += '，其中 <b>' + b.pushed + '</b> 件平均被往后推了 <b>' + b.avg.toFixed(1) + '</b> 天';
    }
    return '<div class="r-flow"><span title="顺延天数由系统跨夜时自动累加，不是你设的日期">' + s + '</span></div>';
  }

  function monthBars(year) {
    var months = yearMonths(year);
    var obs = monthObserved(year);
    var now = new Date();
    var curM = (now.getFullYear() === year) ? now.getMonth() : 11;
    var max = 1, sum = 0;
    months.forEach(function (c, i) { if (i <= curM) { sum += c; if (c > max) max = c; } });
    if (!sum) return '<div class="r-empty">今年还没有完成记录，勾掉一件这根柱子就长出来</div>';
    var bars = '';
    for (var m = 0; m < 12; m++) {
      var c = months[m];
      var future = m > curM;
      var seenN = future ? 0 : obs[m];
      // 一件没有的月份不画短横——3px 的横条会被读成"有数据但很小"
      var hgt = future ? 0 : (c ? 3 + Math.round(c / max * 22) : 0);
      // 整个月都没记录：不写"0 件"，那会被读成"这一个月什么都没干"
      var tip = future ? '还没到' : (seenN ? c + ' 件' : '没记录');
      bars += '<div class="r-bar' + (m === curM ? ' today' : '') + '" title="'
        + (m + 1) + ' 月 · ' + tip + '">'
        + (hgt ? '<i class="' + (m === curM ? 'on' : '') + (future ? ' off' : '') + '" style="height:' + hgt + 'px"></i>' : '')
        + '<u>' + (m + 1) + '</u></div>';
    }
    return '<div class="r-week r-week-month">' + bars + '</div>';
  }

  /* 三格对账：新写 / 删掉 / 做完的比新写的多多少。
     注意别叫"清单净减"——没算年初存量，说净减会夸大。 */
  function flowLine(fl, done) {
    if (!fl.days) {
      return '<div class="r-flow"><span>「新写 / 删掉」从这一版才开始记，之前的不补</span></div>';
    }
    var net = done - fl.nw;
    var cls = net < 0 ? 'down' : '';
    var html = '<div class="r-flow">';
    html += '<span title="今年新写进清单的件数">新写 <b>' + fl.nw + '</b></span>';
    html += '<span title="今年删掉、且当时没做完的件数">删掉 <b>' + fl.dr + '</b></span>';
    // 认赔是另一件事：删掉是"不想要了"，认赔是"我认下这件事不做了"。
    // 两者混成一个数，那笔了结就没有重量了。
    if (fl.anyQ) {
      html += '<span title="今年主动认下不做了的件数（销账）。不算完成，也不再欠着">认赔 <b>' + fl.wr + '</b></span>';
    }
    if (net > 0) {
      html += '<span title="做完的比新写的多 ' + net + ' 件，在清旧账">多做 <b>' + net + '</b></span>';
    } else if (net < 0) {
      html += '<span title="新写的比做完的多 ' + (-net) + ' 件，清单在变长"><b class="' + cls + '">少做 ' + (-net) + '</b></span>';
    } else {
      html += '<span>进出打平</span>';
    }
    return html + '</div>';
  }

  /* ---------------- 外部数据：日历 / 提醒事项 / 屏幕 ----------------
     口径写在这里，别让人猜：
     · 日历只算「非全天、非已取消、你没点"不参加"」的事项，按开始那天归日；
     · 提醒事项只数件数，不改你库里的任何东西；
     · 屏幕时间来自系统自己的 knowledgeC 记录（需要「完全磁盘访问」），
       读不到就整块不出现 —— 不用 0 冒充"今天没用电脑"。 */

  function hmText(sec) {
    var m = Math.round((sec || 0) / 60);
    if (m < 1) return '不到 1 分钟';
    if (m < 60) return m + ' 分钟';
    var h = Math.floor(m / 60), r = m % 60;
    return h + ' 小时' + (r ? ' ' + r + ' 分' : '');
  }

  function srcOk(k) { return !!(ext && ext[k] && ext[k].st === 'ok'); }

  /* 一组来源行：有内容才包一层细线，空就整块不占位置 */
  function srcBlock(html) {
    if (!html) return '';
    return '<div class="r-srcs">' + html + '</div>';
  }

  /* 一条来源行。k 是稳定键：用户能把这一行永久藏掉，也能单独否掉它的数字。
     藏掉之后 tip 里相关的那句判断也要跟着闭嘴，否则"你说错了"和"我还在说"同时发生。
     title 用来写口径（比如"只比工作日"）——口径要能在原地看到，不该只写在文档里。 */
  function srcRow(k, inner, title) {
    if (state.hide && state.hide[k]) return '';
    return '<div class="r-src" data-k="' + k + '"'
      + (title ? ' title="' + escapeHtml(title) + '"' : '') + '>' + inner
      + '<button class="r-q" data-q="' + k + '" title="这条不对？">?</button></div>';
  }
  function hid(k) { return !!(state.hide && state.hide[k]); }

  /* 今天：日历几个会 + 屏幕/前台多久。没有就不占一行。 */
  function todaySrcLines() {
    var out = '';
    if (srcOk('cal')) {
      var c = ext.cal, s;
      if (c.today > 0) {
        s = '今天 <b>' + c.today + '</b> 个日程';
        if (c.next) s += ' · 下一个 ' + c.next;
      } else {
        s = '今天日历上没有会';
      }
      /* 今天是什么日子：只念系统节假日日历上真有的名字。
         没订阅就是没有——绝不内置节日表（放假安排年年变，写死就是编）。
         名字里的「（休）」「（班）」是日历自己的调休标记，读成人话再说，
         否则会和"节气"混成同一类：小寒不是假期。 */
      var k0 = dayKey(todayStart());
      var hd = (c.holi || {})[k0];
      var hw = (c.hoff || {})[k0];
      if (hd) {
        var nm = escapeHtml(String(hd).replace(/[（(][休班][）)]/g, ''));
        if (hw === 1) s = '<b>' + nm + '</b> 放假 · ' + s;
        else if (hw === 0) s = '<b>' + nm + '</b> 调休上班 · ' + s;
        else s = '<b>' + nm + '</b> · ' + s;   // 节气 / 非假期节日：只报名字
      }
      out += srcRow('cal.d', s);
    }
    if (srcOk('rem') && ext.rem.today > 0) {
      out += srcRow('rem.d', '提醒事项今天到期 <b>' + ext.rem.today + '</b> 件');
    }
    out += screenLine();
    return out;
  }

  /* 优先系统的屏幕时间，其次本工具自己计的前台时间。两个名字不一样，别混着读。 */
  function screenLine() {
    var src = null, label = '';
    if (srcOk('screen') && ext.screen.sec > 0) { src = ext.screen; label = '屏幕'; }
    else if (srcOk('focus') && ext.focus.sec > 0) { src = ext.focus; label = '前台'; }
    if (!src) return '';
    var top = src.apps && src.apps[0];
    var s = label + ' <b>' + hmText(src.sec) + '</b>';
    if (top && top.sec > 60) s += ' · 最多 ' + escapeHtml(top.n) + ' ' + hmText(top.sec);
    return srcRow('screen', s);
  }

  function calYearHtml() {
    if (!srcOk('cal') || !ext.cal.n) return '';
    var c = ext.cal;
    var s = '日历 <b>' + c.n + '</b> 项 · <b>' + Math.round(c.sec / 3600) + '</b> 小时 · <b>'
      + c.days + '</b> 天有会';
    if (c.allday) s += ' · 另有 ' + c.allday + ' 个全天';
    /* 这里原来还有一句「节日 44 天」。删掉了：
       44 是这本节假日日历全年的条目数，既不是剩余天数，也不是你的安排，
       放在"我这一年干了什么"里没有任何解释力，还会被读成倒计时。
       节日只在今天真是节日时说一句（见 todaySrcLines），别处不统计。 */
    return srcRow('cal.y', s);
  }

  /* 有会 / 没会 对照：只比工作日。周末拉进来会把"没会"那组压低，比出来是假的。
     还有三条更硬的，都指向同一个错误——拿不确定的日子充样本：
       · 没开过工具、也没记录的那天，它的 0 件不是"没做"，塞进"没会"组会把日均稀释掉；
       · **明确放假**（日历标了「休」）的日子不是"没会的工作日"，放假那天本来就不干活；
       · 反过来，节气（小寒/立春）和调休上班（标了「班」）**都是工作日**，
         以前按"名字在节假日日历里"一刀切，把 24 个节气日也排掉了，
         等于把正常工作日从样本里删了——现在只认「休」标记。
     样本不够就不出这行，宁可比不出来，也不给一个看着像结论的假数。 */
  function meetingVsDone(year) {
    if (!srcOk('cal') || !ext.cal.per) return null;
    var now = new Date();
    var start = new Date(year, 0, 1).getTime();
    var end = (year === now.getFullYear()) ? todayStart() : new Date(year, 11, 31).getTime();
    var per = ext.cal.per, hoff = ext.cal.hoff || {}, holi = ext.cal.holi || {};
    var aN = 0, aS = 0, bN = 0, bS = 0;
    for (var t = start; t <= end; t = prevDayN(t, -1)) {
      var wd = new Date(t).getDay();
      if (wd === 0 || wd === 6) continue;
      if (!dayObserved(t)) continue;
      var k = dayKey(t), off = hoff[k];
      if (off === 1) continue;                        // 明确放假
      /* 有名字但日历没说「休」也没说「班」：节气（确定上班）和除夕（确定放假）
         混在同一堆里，凭名字分不出来。分不出来就不当样本——这是本文件唯一的规矩。 */
      if (off === undefined && holi[k]) continue;
      var d = dayDone(t);
      if ((per[k] || 0) > 0) { aN++; aS += d; } else { bN++; bS += d; }
    }
    if (aN < 5 || bN < 5) return null;
    return { aN: aN, a: aS / aN, bN: bN, b: bS / bN };
  }

  function meetVsHtml(v) {
    if (!v) return '';
    var s = '有会 <b>' + v.aN + '</b> 天 日均 <b>' + v.a.toFixed(1) + '</b> 件 · 没会 <b>'
      + v.bN + '</b> 天 日均 <b>' + v.b.toFixed(1) + '</b> 件';
    return srcRow('meet', s, '只比确定的工作日：周末、明确放假（日历标「休」）、'
      + '以及分不清休还是班的日子都不进样本；节气与调休上班（标「班」）照常算。'
      + (ext && ext.cal && (ext.cal.hcal || []).length ? '依据「' + ext.cal.hcal[0] + '」日历' : '这台机器没订阅节假日日历'));
  }

  function remYearHtml() {
    if (!srcOk('rem') || !ext.rem.total) return '';
    var r = ext.rem;
    var s = '提醒事项 <b>' + r.done + '</b> 件今年勾掉';
    if (r.open) s += ' · 还剩 <b>' + r.open + '</b>';
    if (r.overdue) s += ' · 其中 <b>' + r.overdue + '</b> 件过期';
    return srcRow('rem.y', s);
  }

  /* 没授权的时候，给一个能点的入口，而不是一句"暂无数据" */
  function permHtml() {
    if (!ext) return '';
    var bits = [];
    var cs = (ext.cal || {}).st, rs = (ext.rem || {}).st, ss = (ext.screen || {}).st;
    if (cs === 'ask' || rs === 'ask') {
      bits.push('<span class="r-lk" data-act="auth">授权后显示日历与提醒事项</span>');
    } else if (cs === 'denied' || rs === 'denied') {
      bits.push('<span class="r-lk" data-act="privacy">系统里被拒绝了 · 去打开</span>');
    }
    if (ss === 'nofda') bits.push('<span class="r-lk" data-act="fda">屏幕使用时间需完全磁盘访问</span>');
    if (ss === 'noschema') bits.push('<span class="r-lk">屏幕时间库读到了，但结构对不上</span>');
    if (ss === 'nofile') bits.push('<span class="r-lk">这台机器没有屏幕使用时间库</span>');
    if (!bits.length) return '';
    return '<div class="r-src">' + bits.join(' · ') + '</div>';
  }

