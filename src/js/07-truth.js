  /* ---------------- 让用户能否掉我 ----------------
     三层：行级「?」、日级对账、月级否决。
     全部只写本机 data.json：不联网、不上报、不统计。
     一条原则：用户说"忘了记"，我也不会替他补数——补了就回到自欺。 */

  function monthKey(ts) {
    var d = new Date(ts || Date.now()), m = d.getMonth() + 1;
    return d.getFullYear() + '-' + (m < 10 ? '0' + m : m);
  }

  var saidTimer = null;
  /* 登记"我说过这句话"，月级否决才有东西可投。文本去标签，投票时才好看。 */
  function noteSaid(k, text) {
    if (!text) return;
    var ym = monthKey();
    if (!state.said) state.said = {};
    var box = state.said[ym] || (state.said[ym] = {});
    var plain = String(text).replace(/<[^>]+>/g, '');
    if (box[k] === plain) return;
    box[k] = plain;
    clearTimeout(saidTimer);
    saidTimer = setTimeout(persist, 900);
  }

  /* 同一类判断被说两次「不准」，以后就只给数、不给话 */
  function muted(k) { return !!(state.saidN && state.saidN[k] >= 2); }

  /* 日级对账：日历上明显有事、账本却是 0 才问。三个条件缺一不可，否则闭嘴。 */
  function gapAskHtml() {
    if (!srcOk('cal') || hid('cal.d')) return '';
    var t = todayStart(), k = dayKey(t);
    if (state.gap && state.gap[k] !== undefined) return '';
    if (state.gapOff && t - state.gapOff < 14 * 86400000) return '';
    if ((ext.cal.today || 0) < 2) return '';
    if (dayDone(t) > 0) return '';
    return '<div class="r-ask" data-ask="gap">'
      + '<span class="r-ask-t">今天日历上有 ' + ext.cal.today + ' 个日程，账本 0 件。</span>'
      + '<span class="r-ask-b">'
      + '<button data-gap="0">没做事</button>'
      + '<button data-gap="1">忘了记</button>'
      + '<button data-gap="off">别问</button>'
      + '</span></div>';
  }

  /* 用户自己承认漏记的天数。不猜、不按日程推算。 */
  function gapForgot(year) {
    var n = 0, pre = String(year) + '-';
    Object.keys(state.gap || {}).forEach(function (k) {
      if (k.indexOf(pre) === 0 && state.gap[k] === 1) n++;
    });
    return n;
  }

  /* 月级否决：每月 1-7 号，把上个月实际说过的话摆出来，一句一句投。 */
  function voteHtml() {
    var now = new Date();
    if (now.getDate() > 7) return '';
    var prev = monthKey(new Date(now.getFullYear(), now.getMonth() - 1, 2).getTime());
    var said = state.said && state.said[prev];
    if (!said) return '';
    var voted = (state.vote && state.vote[prev]) || {};
    var keys = Object.keys(said).filter(function (k) { return !voted[k]; }).slice(0, 3);
    if (!keys.length) return '';
    var rows = '';
    keys.forEach(function (k) {
      rows += '<div class="r-vt"><span>' + escapeHtml(said[k]) + '</span>'
        + '<button data-vote="' + k + '|ok">准</button>'
        + '<button data-vote="' + k + '|no">不准</button></div>';
    });
    return '<div class="r-ask" data-ask="vote">'
      + '<span class="r-ask-t">上个月我说过这些话，哪些不准？</span>' + rows + '</div>';
  }

  /* 纠正次数：给自己看的，不是勋章 */
  function fbStatHtml() {
    var n = (state.fb || []).length;
    var h = Object.keys(state.hide || {}).length;
    if (!n && !h) return '';
    var out = '你纠正过我 ' + n + ' 次';
    if (h) out += ' · <span class="r-lk" data-act="unhide">把那 ' + h + ' 行放回来</span>';
    return '<div class="r-fbstat">' + out + '</div>';
  }

  /* 点「?」：原地插一行三个选项，不弹浮层（浮层在这窗口里会挡住数字）。 */
  function toggleFb(btn) {
    var row = btn.closest ? btn.closest('.r-src') : null;
    if (!row) return;
    var nx = row.nextElementSibling;
    if (nx && nx.className === 'r-fb') { nx.parentNode.removeChild(nx); resizeSoon(); return; }
    var opened = document.querySelectorAll('.r-fb');
    for (var i = 0; i < opened.length; i++) opened[i].parentNode.removeChild(opened[i]);
    var d = document.createElement('div');
    d.className = 'r-fb';
    d.setAttribute('data-for', btn.getAttribute('data-q'));
    d.innerHTML = '<span>这行不对？</span>'
      + '<button data-fb="wrong">数不对</button>'
      + '<button data-fb="hide">不该显示</button>'
      + '<button data-fb="ok">没事</button>';
    row.parentNode.insertBefore(d, row.nextSibling);
    resizeSoon();
  }

  function doFb(kind, btn) {
    var box = btn.closest ? btn.closest('.r-fb') : null;
    if (!box) return;
    var k = box.getAttribute('data-for');
    var row = box.previousElementSibling;
    var txt = row ? (row.textContent || '').replace(/\?/g, '').replace(/\s+/g, ' ').trim() : '';
    if (kind === 'hide') {
      if (!state.hide) state.hide = {};
      state.hide[k] = 1;
      persist();
      renderReport();
      toast('这一行不再显示了');
    } else {
      if (kind === 'wrong') {
        if (!state.fb) state.fb = [];
        state.fb.push({ at: Date.now(), k: k, v: txt.slice(0, 60) });
        if (state.fb.length > 200) state.fb = state.fb.slice(-200);
        persist();
        if (box.parentNode) box.parentNode.removeChild(box);
        renderReport();          // 统计行要跟着变
        /* 这里不许承诺"以后会记得不牢"——fb 只存下来给用户自己看，
           没有任何代码会因为它改变输出。能改行为的只有月级投票（saidN）。
           说了做不到，比不说更糟。 */
        toast('记下了 · 这个数我不改（改了就成假账）。年度页里那句判断，你可以在下面投「不准」');
      } else if (box.parentNode) {
        box.parentNode.removeChild(box);
      }
    }
    resizeSoon();
  }

  function doGap(v) {
    var t = todayStart(), k = dayKey(t);
    if (v === 'off') {
      state.gapOff = t;
      toast('14 天内不再问');
    } else {
      if (!state.gap) state.gap = {};
      state.gap[k] = Number(v);
      toast(v === '1' ? '记下了：这天可能漏记，但我不替你补数' : '记下了：这天确实没做');
    }
    persist();
    renderReport();
    resizeSoon();
  }

  function doVote(v) {
    var p = String(v).split('|'), k = p[0], verdict = p[1];
    var now = new Date();
    var prev = monthKey(new Date(now.getFullYear(), now.getMonth() - 1, 2).getTime());
    if (!state.vote) state.vote = {};
    var box = state.vote[prev] || (state.vote[prev] = {});
    box[k] = verdict;
    if (verdict === 'no') {
      if (!state.saidN) state.saidN = {};
      state.saidN[k] = (state.saidN[k] || 0) + 1;
      toast(state.saidN[k] >= 2
        ? '这类话我两次不准了，以后只给数、不给判断'
        : '记下了 · 再被你说一次不准，这类话我就不说了');
    } else {
      toast('留着');
    }
    persist();
    renderReport();
    resizeSoon();
  }

  function resizeSoon() {
    lastHeight = 0;
    setTimeout(scheduleResize, 0);
    setTimeout(scheduleResize, 120);
  }

  /* 一年一屏：只念这一屏能看到的数，不吹、不劝、不编 */
  function tipYear(r, fl, months, mv) {
    var out = [];
    /* 每说一句判断就登记一次：月级否决靠它才有东西可投；
       同类判断被说过 2 次不准，就静音——只留数，不留话。 */
    function say(k, text) {
      if (muted(k)) return;
      out.push(text);
      noteSaid(k, text);
    }
    if (!r.total) {
      if (fl.nw) return '今年写了 ' + fl.nw + ' 件，一件都还没划掉。账本是空的，但清单不是。';
      return '今年账本还是空的。没记录不等于没干活，只是那些事没走这个窗。';
    }
    var s = '今年划掉 ' + r.total + ' 件';
    if (r.active >= 3) s += '，落在 ' + r.active + ' 天里，动手那天平均 ' + (r.total / r.active).toFixed(1) + ' 件';
    else if (r.active === 1) s += '，全在一天里';
    else if (r.active > 1) s += '，散在 ' + r.active + ' 天里';
    say('avg', s + '。');
    var gf = gapForgot(new Date(r.end).getFullYear());
    if (gf) say('gap', '其中 ' + gf + ' 天你自己标了「可能漏记」，那几天按 0 算。');
    /* 这条是原则，不是客套：我知道的和我不知道的必须分开说。
       不写这句，热力图里的空白就会被读成"那天你什么都没干"。 */
    /* 关键的诚实：把「那时候我还不记」和「记了但没记录」分开。
       混成一句，会把功能上线前的几个月说成「那些天你没干活」。 */
    var from = keyToTs(state.seenFrom);
    var before = from > r.start ? Math.round((from - r.start) / 86400000) : 0;
    var gap = Math.max(0, (r.days - before) - r.observed);
    if (before > 0) {
      say('seen0', '从 ' + shortDate(from) + ' 起我才开始记「哪天开着」，之前的 ' + before + ' 天算不了。');
    }
    if (gap > 0 && r.observed > 0) {
      say('seen', '这之后我开着 ' + r.observed + ' 天，还有 ' + gap + ' 天没有任何记录——'
        + '那几天按「不知道」算，没算成 0 件；连续天数也只数看得见的天，中间断了不算。');
    }

    // 只拿"已经过完的月份"比，当月没过完，样本少，比出来的"最猛"是假的
    var curM = new Date(r.end).getMonth();
    var bestM = -1, bestV = 0;
    months.forEach(function (v, i) {
      if (i >= curM) return;
      if (v > bestV) { bestV = v; bestM = i; }
    });
    if (bestV > 0 && bestV > r.total * 0.2) say('peak', '最重的活压在 ' + (bestM + 1) + ' 月，' + bestV + ' 件。');

    if (fl.nw || fl.dr) {
      var net = r.total - fl.nw;
      var line = '新写 ' + fl.nw + ' 件';
      if (fl.dr) line += '、删掉 ' + fl.dr + ' 件没做的';
      if (net > 0) line += '，做完的比新写的多 ' + net + ' 件，在清旧账。';
      else if (net < 0) line += '，新写的比做完的多 ' + (-net) + ' 件，清单在变长。';
      else line += '，进出打平。';
      say('flow', line);
    }
    var st7 = staleCount(7);
    if (st7) say('stale', '还有 ' + st7 + ' 件已经被往后推了一周以上，还没做。');

    // 日历对照：只在两边样本都够的时候说一句
    if (mv && mv.b > 0 && !hid('meet')) {
      if (mv.a === 0) say('meet', '有会的那 ' + mv.aN + ' 天，一件都没划掉。');
      else if (mv.a < mv.b * 0.75) say('meet', '有会的日子，日均划掉掉到没会时的 ' + Math.round(mv.a / mv.b * 100) + '%。');
      else if (mv.a > mv.b * 1.25) say('meet', '有会的日子反而做得多，会没白开。');
      else say('meet', '有没有会，日均差不多。');
    }

    // 按数据说一句实话，条件不成立就闭嘴
    if (fl.nw >= 10 && r.total / fl.nw >= 0.8) say('tone', '写下来的几乎都做完了，这比做得多更难。');
    else if (r.longest >= 7) say('tone', '能连着做，比某天猛做一天难。');
    else if (r.active >= 100) say('tone', '一百多天里动过手，这一年没白过。');
    else if (r.total >= 200) say('tone', '这个量不是靠热情撑住的。');
    else if (r.total >= 20 && r.active >= 10) say('tone', '不快，但一直在动。');
    return out.join(' ');
  }

  function tabBtn(k, label) {
    return '<button data-tab="' + k + '"' + (reportTab === k ? ' class="on"' : '') + '>' + label + '</button>';
  }

  function numCell(v, label) {
    return '<div class="r-num"><b>' + v + '</b><span>' + label + '</span></div>';
  }

  /* --- 人话总结：只说这一屏能看到的数字，不吹、不劝 --- */
  function tipDay(st, stk) {
    var out = [];
    if (st.total === 0) {
      /* 「今天没有到期的活」不等于「今天什么都没写」：可能今天新建了几件，
         全排到了以后。流水里有据可查（n = 今天新建的件数），用它说真话——
         否则底栏说「还剩 N 件事」、这张卡说「今天还什么都没写」，同一屏两句话打架。 */
      var fn = (flowMap()[dayKey(Date.now())] || {}).n || 0;
      out.push(fn ? '今天写了 ' + fn + ' 件，都排到了以后。' : '今天还什么都没写。');
    } else if (st.pending === 0) out.push(st.done + ' 件全清了，可以关电脑了。');
    else if (st.done === 0) out.push('还没动。挑最短的那件，先破个零。');
    else {
      var s = '做了 ' + st.done + ' 件，还剩 ' + st.pending + ' 件。';
      if (st.done * 2 >= st.total) s += '过半了。';
      out.push(s);
    }
    if (stk >= 2 && !muted('streak')) { out.push('连着 ' + stk + ' 天有产出。'); noteSaid('streak', '连着 ' + stk + ' 天有产出。'); }
    if (st.carried) out.push('另有 ' + st.carried + ' 件拖过两天。');
    return out.join(' ');
  }

  function tipRange(r) {
    if (!r.total) {
      return r.observed
        ? '这 ' + r.days + ' 天里我开着 ' + r.observed + ' 天，一件都没划掉。'
        : '这 ' + r.days + ' 天没有任何记录，我不知道那几天做没做。';
    }
    var s = r.days + ' 天里划掉 ' + r.total + ' 件';
    if (r.active) s += '，动手的 ' + r.active + ' 天平均 ' + (r.total / r.active).toFixed(1) + ' 件';
    s += '。';
    if (r.best.n > 1) s += '最猛 ' + shortDate(r.best.day) + '，一天 ' + r.best.n + ' 件。';
    /* 两个数必须分开说：
       observed - active = 我看见了、但你没勾（这是真的 0）
       days - observed   = 我根本没看见（这不能算 0） */
    var seen0 = r.observed - r.active;
    var unknown = r.days - r.observed;
    if (seen0 > 0) s += '另外 ' + seen0 + ' 天有记录但没划掉。';
    if (unknown > 0) s += '还有 ' + unknown + ' 天没有任何记录，那几天不算 0 件。';
    return s;
  }

  /* 只收原文可考的句子，不乱挂作者、不缩写改写。
     拿不准逐字原文的（比如纪录片旁白、没核到版本的商业书），宁可先不放。 */
  var QUOTES = [
    ['也无风雨也无晴', '苏轼《定风波》'],
    ['行到水穷处，坐看云起时', '王维《终南别业》'],
    ['悟已往之不谏，知来者之可追', '陶渊明《归去来兮辞》'],
    ['譬如为山，未成一篑', '《论语·子罕》'],
    ['纸上得来终觉浅，绝知此事要躬行', '陆游《冬夜读书示子聿》'],
    ['人间有味是清欢', '苏轼《浣溪沙》'],
    ['山重水复疑无路，柳暗花明又一村', '陆游《游山西村》'],
    ['不积跬步，无以至千里', '《荀子·劝学》'],
    ['千里之行，始于足下', '老子《道德经》第六十四章'],
    ['天下大事，必作于细', '老子《道德经》第六十三章'],
    ['知人者智，自知者明', '老子《道德经》第三十三章'],
    ['胜人者有力，自胜者强', '老子《道德经》第三十三章'],
    ['知足者富', '老子《道德经》第三十三章'],
    ['慎终如始，则无败事', '老子《道德经》第六十四章'],
    ['少则得，多则惑', '老子《道德经》第二十二章'],
    ['士不可以不弘毅，任重而道远', '《论语·泰伯》'],
    ['工欲善其事，必先利其器', '《论语·卫灵公》'],
    ['知是行之始，行是知之成', '王阳明《传习录》'],
    ['岁月本长，而忙者自促', '洪应明《菜根谭》'],
    ['不义而富且贵，于我如浮云', '《论语·述而》']
  ];

  function quoteHtml() {
    var start = new Date(new Date().getFullYear(), 0, 0).getTime();
    var idx = Math.floor((todayStart() - start) / 86400000) % QUOTES.length;
    var q = QUOTES[idx];
    return '<div class="r-quote">「' + q[0] + '」 <b>—— ' + q[1] + '</b></div>';
  }

  /* 报告卡的"只增不减"高度锁。
     五个页签的内容高度从 200px 到 700px，高度跟着内容走的话，
     切一次页签整个窗口就弹一下——读数字的时候眼睛在抖，还会把窗口推到屏幕外。
     做法：打开报告时按当前页签定一个高度，之后切页签只可能更高，不会缩回来。
     切回短页签会留白，但窗口不动；宁可一次留白，也不要每次切都跳。 */
  var reportLockH = 0;
  var REPORT_MAX_H = 640;

  function lockReportHeight(force) {
    if (!el.report) return;
    if (force) {
      reportLockH = 0;
      el.report.style.height = '';
    }
    var natural = el.report.scrollHeight;
    if (!natural) return;
    reportLockH = reportLockH ? Math.max(reportLockH, natural) : natural;
    var h = Math.min(reportLockH, REPORT_MAX_H);
    el.report.style.height = h + 'px';
  }

  function renderReport() {
    if (!el.report || !reportOpen) return;
    var st = statsToday();
    var stk = streakDays();
    var d = new Date();
    /* 报告卡看哪一年：默认跟着今天；从年度公告点进来时是公告报的那一年
       （1/1–1/15 公告报去年，点进去必须也是去年，不能是今年的空账本）。 */
    var yr = reportYearSel || d.getFullYear();

    var head = '<div class="r-head"><span class="r-title">账本</span>'
      + '<span class="r-sub">' + (reportTab === 'yr'
        ? (yr + ' 年度 · 截至 ' + shortDate(d.getTime()))
        : (shortDate(d.getTime()) + ' ' + weekday(d))) + '</span>'
      + '<button class="r-x" data-act="close">收起</button></div>'
      + '<div class="r-tabs">'
      + tabBtn('day', '今日') + tabBtn('wk', '本周') + tabBtn('d30', '30 天')
      + tabBtn('h1', '半年') + tabBtn('yr', '年度')
      + '</div>';

    var body = '';

    if (reportTab === 'day') {
      var ratio = st.total ? st.done / st.total : 0;
      var pct = Math.round(ratio * 100);
      var off = (138.2 * (1 - ratio)).toFixed(1);
      /* 环里原来只有一个「46%」，没有说明，被当成专注度。
         它其实只回答一件事：今天清单上划掉了多少。补一个 6 个字的标签，
         并且 0 件事的时候不写 0%——0/0 不是"划掉 0%"，是"今天没排事"。 */
      var pctIn = st.total ? (pct + '<small>%</small>') : '—';
      var pctNote = st.total ? '今日划掉' : '还没排事';
      body = '<div class="r-top"><div class="r-donut-wrap" title="今日清单：划掉 '
        + st.done + ' 件 / 共 ' + st.total + ' 件">'
        + '<svg class="r-donut" viewBox="0 0 50 50"><circle class="bg" cx="25" cy="25" r="22"></circle>'
        + '<circle class="fg" cx="25" cy="25" r="22" style="stroke-dashoffset:' + off + '"></circle></svg>'
        + '<div class="r-pct"><b>' + pctIn + '</b><i>' + pctNote + '</i></div></div>'
        + '<div class="r-nums">' + numCell(st.done, '已划掉') + numCell(st.pending, '待办') + numCell(stk, '连续天数')
        + '</div></div>'
        + '<div class="r-week">' + sevenBars() + '</div>'
        + srcBlock(todaySrcLines())
        + gapAskHtml()
        + '<div class="r-tip">' + tipDay(st, stk) + '</div>';
    } else if (reportTab === 'wk') {
      /* 本周 = 周一到今天。天数按"已经过了几天"算，不按 7 天算：
         拿 5 天除以 7 当分母，等于提前给这一周判了个低分。 */
      var wn = weekIdx(todayStart()) + 1;
      var rw = rangeStats(wn);
      var wnote;
      if (rw.total) {
        wnote = '周一到今天 ' + rw.days + ' 天，划掉 ' + rw.total + ' 件';
        if (rw.active) wnote += '，动手的 ' + rw.active + ' 天平均 ' + (rw.total / rw.active).toFixed(1) + ' 件';
        wnote += '。';
        if (rw.best.n > 1) wnote += '最猛 ' + shortDate(rw.best.day) + '，一天 ' + rw.best.n + ' 件。';
      } else if (rw.observed) {
        // observed < days 时，没记录的那几天不能算进"我开着"
        wnote = rw.observed === rw.days
          ? '这 ' + rw.days + ' 天我开着，一件都没划掉。'
          : '这 ' + rw.days + ' 天里我开着 ' + rw.observed + ' 天，一件都没划掉。';
      } else {
        wnote = '这 ' + rw.days + ' 天没有任何记录，我不知道那几天做没做。';
      }
      body = '<div class="r-nums r-nums-wide">'
        + numCell(rw.total, '本周划掉') + numCell(rw.active, '动手的天') + numCell(rw.best.n, '最猛一天')
        + '</div>' + weekBars(wn)
        + '<div class="r-tip">' + wnote + '</div>' + quoteHtml();
    } else if (reportTab === 'd30') {
      var r30 = rangeStats(30);
      body = '<div class="r-nums r-nums-wide">'
        + numCell(r30.total, '30 天划掉') + numCell(r30.active, '动手的天') + numCell(r30.best.n, '最猛一天')
        + '</div>' + thirtyBars(30)
        + '<div class="r-tip">' + tipRange(r30) + '</div>' + quoteHtml();
    } else if (reportTab === 'h1') {
      var rh = rangeStats(182);
      /* 只要区间里有一天「我看不见」，连续就只能说「至少这么多」：
         没记录的日子会被当成断点，真实值只会更长。全看见了才敢写确定值。 */
      var rhLong = longestStreak(182);
      body = '<div class="r-nums r-nums-wide">'
        + numCell(rh.total, '半年划掉') + numCell(rh.active, '有干活的天')
        + numCell((rh.observed < rh.days ? '≥ ' : '') + rhLong, '最长连续')
        + '</div>' + heatSvg(prevDayN(todayStart(), 181), todayStart())
        + '<div class="r-tip">' + tipRange(rh) + '</div>' + quoteHtml();
    } else {
      var ry = yearStats(yr);
      var yfl = yearFlow(yr);
      var ymo = yearMonths(yr);
      var mv = meetingVsDone(yr);
      body = '<div class="r-nums r-nums-wide">'
        + numCell(ry.total, '划掉') + numCell(ry.active, '动手的天')
        + numCell((ry.observed < ry.days ? '≥ ' : '') + ry.longest, '最长连续')
        + '</div>'
        + monthBars(yr)
        + flowLine(yfl, ry.total)
        + backlogLine()
        + projLine(yr, ry.total)
        + heatSvg(ry.start, ry.end)
        + srcBlock(calYearHtml() + meetVsHtml(mv) + remYearHtml() + permHtml())
        + '<div class="r-tip">' + tipYear(ry, yfl, ymo, mv) + '</div>'
        + voteHtml()
        + fbStatHtml()
        + quoteHtml();
    }

    el.report.innerHTML = head + body;
    lockReportHeight();
  }

  function toggleReport(force) {
    reportOpen = (typeof force === 'boolean') ? force : !reportOpen;
    el.report.classList.toggle('show', reportOpen);
    if (reportOpen) {
      /* 年份选择只在「年度公告点进来」的那一次有效；用户自己再点开报告
         就回到今天所在的年份，别一直停在去年。 */
      if (!annivJump) reportYearSel = 0;
      annivJump = false;
      lockReportHeight(true);    // 每次重新打开都按当前页签重新定高，不留上次的留白
      renderReport();
    } else {
      reportLockH = 0;
      el.report.style.height = '';
    }
    lastHeight = 0;
    setTimeout(scheduleResize, 0);
    setTimeout(scheduleResize, 240);
  }

  if (el.prog) el.prog.addEventListener('click', function (e) {
    e.stopPropagation();
    toggleReport();
  });
  if (el.report) el.report.addEventListener('click', function (e) {
    var t = e.target;
    if (!t || !t.getAttribute) return;
    // 行级纠错 / 日级对账 / 月级否决：都挂在 button 上，先拦掉
    var btn = (t.closest && t.closest('button')) || t;
    var q = btn.getAttribute && btn.getAttribute('data-q');
    if (q) { e.stopPropagation(); toggleFb(btn); return; }
    var fbk = btn.getAttribute && btn.getAttribute('data-fb');
    if (fbk) { e.stopPropagation(); doFb(fbk, btn); return; }
    var gv = btn.getAttribute && btn.getAttribute('data-gap');
    if (gv) { e.stopPropagation(); doGap(gv); return; }
    var vv = btn.getAttribute && btn.getAttribute('data-vote');
    if (vv) { e.stopPropagation(); doVote(vv); return; }
    // 点在小字（<b>/<i>）上也要能触发整条的动作
    var host = (t.closest && t.closest('[data-act]')) || t;
    var act = host.getAttribute('data-act');
    if (act === 'close') { e.stopPropagation(); toggleReport(false); return; }
    if (act === 'unhide') { e.stopPropagation(); state.hide = {}; persist(); renderReport(); resizeSoon(); toast('都放回来了'); return; }
    if (act === 'auth') { e.stopPropagation(); send('extAuth', { kind: 'both' }); return; }
    if (act === 'privacy') {
      e.stopPropagation();
      var cs = ext && ext.cal ? ext.cal.st : '';
      send('privacy', { pane: (cs === 'denied') ? 'Privacy_Calendars' : 'Privacy_Reminders' });
      return;
    }
    if (act === 'fda') { e.stopPropagation(); send('fda'); return; }
    var tab = t.getAttribute('data-tab');
    if (tab) {
      e.stopPropagation();
      reportTab = tab;
      renderReport();
      lastHeight = 0;
      setTimeout(scheduleResize, 0);
      setTimeout(scheduleResize, 220);
    }
  });
  if (el.wx) el.wx.addEventListener('click', function (e) {
    e.stopPropagation();
    if (!weather) toast('正在取天气…');
    send('weatherRefresh');
  });

