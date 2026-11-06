  /* ---------------- 今天 / 明天 / 后天：自动接续的日程 ----------------
     未完成的活过夜自动继承到第二天；当天全部勾完后，收起态自动接到下一天。 */

  function dayStart(ts) {
    var d = new Date(ts);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }
  function todayStart() { return dayStart(Date.now()); }

  /* 手动顺延。以前这里只写 `t.due = 明天`，不动 carried ——
     后果是「→」变成一张无限次免罚券：每天早上点一下，一件东西能在清单上躺一年，
     欠账面板里永远是 0 件，徽标永远不出现。同一件事，过夜自动继承要计账，
     手动往后放就免账，那这个账本记的不是我做了什么，而是我用哪个按钮做的。

     carried 的含义从此统一为：这件东西从到期日算起，被往后放了多少天。
     自动继承和手动顺延是产生积压的两条路径，不是两种待遇。 */
  function pushDue(t, days) {
    var step = days || 1;
    var base = (typeof t.due === 'number' && isFinite(t.due)) ? t.due : todayStart();
    var d = new Date(base);
    d.setDate(d.getDate() + step);
    t.due = dayStart(d.getTime());
    // 位移几天就记几天（同一天连点两次「→」是推了 2 天，不是推了 1 次）。
    // 上界和 rollover 里那条一致，不允许手动路径绕过 366。
    t.carried = Math.min((t.carried || 0) + step, 366);
    return t.due;
  }

  function rollover() {
    var t0 = todayStart(), changed = false;
    state.nodes.forEach(function (n) {
      if (n.type !== 'task') return;
      if (typeof n.due !== 'number' || !isFinite(n.due)) {
        n.due = dayStart(n.created || Date.now());
        changed = true;
      }
      // 老数据里顺延计数被算爆过（8473 这种）：按真实的创建日重新折算
      if ((n.carried || 0) > 366) {
        var real = Math.max(0, Math.round((t0 - dayStart(n.created || Date.now())) / 86400000));
        n.carried = Math.min(real, 366);
        changed = true;
      }
      if (n.done) return;
      if (n.due < t0) {
        // 过夜没做完：自动继承到今天，并记一笔顺延天数
        var gap = Math.round((t0 - n.due) / 86400000);
        n.due = t0;
        /* 上界必须和上面那条重算的上界一致（都是 366）。
           以前这里写 999、上面写 366，于是一条真拖了一年的任务会先涨到 999，
           下次启动又被折回 366——用户会看见「顺延 999 天」自己变小。
           账本可以难看，但不能自己改数。 */
        n.carried = Math.min((n.carried || 0) + Math.max(1, gap), 366);
        changed = true;
      }
      // 注：以前这里还有一段"没挪过却被排到未来就拉回创建日"的纠正，
      // 它会把今天继承出来的 due 又顶回昨天，下一拍再当逾期顺延 —— 每秒抖一次、
      // 每秒写一次盘、顺延数无限涨。已删除：due 只由创建日和手动顺延决定。
    });
    return changed;
  }

  /* 收起态看哪一天：今天还有没做完的就看今天；今天清空了就自动接到明天、后天… */
  function agendaInfo() {
    var t0 = todayStart();
    var tasks = state.nodes.filter(function (n) { return n.type === 'task'; });
    var undone = tasks.filter(function (n) { return !n.done; });
    // 今天已经做掉几件：收起态也要能看出"今天完成了什么、明天接什么"。
    // 必须走 dayDone（daily 账本，记的是"哪天勾掉的"），不能用 due 反推：
    // 一件昨天到期、今天才勾掉的任务，due 仍是昨天，按 due 数就会漏掉。
    var todayDone = dayDone(t0);

    var todayLeft = undone.filter(function (n) { return n.due <= t0; }).sort(taskCmp);
    if (todayLeft.length) {
      return { day: t0, list: todayLeft, todayDone: todayDone, nextDay: false };
    }

    var future = undone.filter(function (n) { return n.due > t0; })
      .sort(function (a, b) { return (a.due - b.due) || taskCmp(a, b); });
    if (future.length) {
      var d0 = future[0].due;
      return {
        day: d0,
        list: future.filter(function (n) { return n.due === d0; }).sort(taskCmp),
        todayDone: todayDone,
        nextDay: true
      };
    }
    return { day: t0, list: [], todayDone: todayDone, nextDay: false };
  }

  function agendaShort(day) {
    var diff = Math.round((dayStart(day) - todayStart()) / 86400000);
    if (diff === 0) return '今天';
    if (diff === 1) return '明天';
    if (diff === 2) return '后天';
    var d = new Date(day);
    return (d.getMonth() + 1) + '/' + d.getDate();
  }

  function agendaLabel(day) {
    var d = new Date(day);
    var diff = Math.round((dayStart(day) - todayStart()) / 86400000);
    var lead = (diff === 0 || diff === 1 || diff === 2) ? agendaShort(day)
      : (diff < 0 ? '逾期' : (d.getMonth() + 1) + '月' + d.getDate() + '日');
    return lead + ' · ' + (d.getMonth() + 1) + '/' + d.getDate() + ' ' + weekday(d);
  }

  var agendaNoteTimer = null;
  function agendaFlash(text) {
    // 展开态看不见 .a-meta（那条被 CSS 藏了），别把话写进一个看不见的地方
    var m = (document.body.classList.contains('collapsed')) && el.agenda && el.agenda.querySelector('.a-meta');
    if (!m) { toast(text); return; }
    clearTimeout(agendaNoteTimer);
    m.textContent = text;
    m.classList.add('flash');
    agendaNoteTimer = setTimeout(function () { renderAgenda(); }, 1800);
  }

  function agendaToggle(id) {
    var t = byId(id);
    if (!t) return;
    markDone(t);
    t.remindAt = null;
    t.fired = false;
    persist();
    render();
    var info = agendaInfo();
    if (!info.list.length) {
      agendaFlash('全部都完成了 · 明天见');
    } else if (dayStart(info.day) > todayStart()) {
      agendaFlash('今天完成 · 已接上' + agendaShort(info.day) + '，还剩 ' + info.list.length + ' 件');
    } else {
      agendaFlash('还剩 ' + info.list.length + ' 件');
    }
  }

  function agendaRow(t) {
    var row = document.createElement('div');
    row.className = 'a-row';
    row.dataset.id = t.id;

    var chk = document.createElement('div');
    chk.className = 'check';
    chk.title = '勾掉这件';
    chk.addEventListener('click', function (e) { e.stopPropagation(); agendaToggle(t.id); });
    row.appendChild(chk);

    var title = document.createElement('div');
    title.className = 'a-t';
    title.textContent = t.text;
    title.title = t.text + (t.parentId ? (function () {
      var pp = byId(t.parentId);
      return pp ? '\n属于「' + pp.text + '」' : '';
    })() : '');
    row.appendChild(title);

    // 挂在项目下的任务，收起态也标一下归属，免得勾错
    if (t.parentId) {
      var pp = byId(t.parentId);
      if (pp && pp.type === 'project') {
        var pj = document.createElement('span');
        pj.className = 'a-proj';
        pj.textContent = pp.text;
        pj.title = '属于项目「' + pp.text + '」';
        row.appendChild(pj);
      }
    }

    // 只隔一天就做掉的算正常节奏，不刷徽章；拖了 2 天以上才提醒
    if ((t.carried || 0) >= 2) {
      var b = document.createElement('span');
      b.className = 'a-badge';
      b.textContent = '顺延' + t.carried + '天';
      b.title = '从到期那天算起，这件已经往后放了 ' + t.carried + ' 天';
      row.appendChild(b);
    }

    var mv = document.createElement('button');
    mv.className = 'a-move';
    mv.textContent = '→';
    mv.title = '顺延到' + (function () {
      var d = new Date(t.due || todayStart()); d.setDate(d.getDate() + 1);
      return agendaShort(d.getTime());
    })();
    mv.addEventListener('click', function (e) {
      e.stopPropagation();
      var nd = pushDue(t, 1);
      persist();
      render();
      renderAgenda();
      agendaFlash('已顺延到 ' + agendaShort(nd));
    });
    row.appendChild(mv);

    return row;
  }

  /* ---------------- 日结：每天第一次打开，先把昨天结一句 ----------------
     只报「昨天结了 N 件」——daily 账本里有据可查，用户能自己数回来。
     不报「昨天欠了几件」：历史上的未完成数没法从 data.json 可靠重建
     （任务会被删、会被顺延、会被销账），编一个看起来像真的数，比不报恶劣得多。
     今天欠多少，在下面的「欠账」里另算——那是还活着的任务，不是历史。 */
  /* 「哪天已经给看过」存在 state.settle 里（会写盘）。
     以前只是个内存变量，结果一天里关掉再打开三次，就刷三次。 */
  function settleSeenToday() {
    return state.settle === dayKey(Date.now());
  }

  function settleText() {
    var y = prevDay(todayStart());
    if (!dayObserved(y)) return '';        // 昨天没记录：不编，也不打扰
    var n = dayDone(y);
    return n > 0 ? '昨天结了 ' + n + ' 件' : '昨天没结下东西';
  }

  var debtOpen = false;

  /* 从清单上的「N天」直接进欠账面板。
     销账这件事有两个入口是必要的：一条总账（拖了 2 天以上有几件），
     一条单件（这件拖了几天）。只有总账的话，看到单件的天数时没地方去。 */
  function openDebts() {
    if (!debts().length) { toast('没有拖过 2 天的'); return; }
    debtOpen = true;
    renderAgenda();
  }

  function renderDebt(host) {
    var list = debts();
    // 销到最后一件就自动退回今天，不让人停在一个空面板上
    if (!list.length) { debtOpen = false; renderAgenda(); return; }
    var worst = list[0].carried || 0;

    var head = document.createElement('div');
    head.className = 'a-head';
    var ttl = document.createElement('span');
    ttl.className = 'a-day';
    ttl.textContent = '欠账 · ' + list.length + ' 件';
    var meta = document.createElement('span');
    meta.className = 'a-meta';
    meta.textContent = '最久 ' + worst + ' 天';
    var back = document.createElement('button');
    back.className = 'd-back';
    back.textContent = '返回';
    back.title = '回到今天的清单';
    back.addEventListener('click', function (e) {
      e.stopPropagation();
      debtOpen = false;
      renderAgenda();
    });
    head.appendChild(ttl);
    head.appendChild(meta);
    head.appendChild(back);
    host.appendChild(head);

    list.forEach(function (t) {
      var row = document.createElement('div');
      row.className = 'd-row';

      var n = document.createElement('span');
      n.className = 'd-n';
      n.textContent = (t.carried || 0) + '天';
      n.title = '从到期那天算起，这件已经往后放了 ' + (t.carried || 0) + ' 天';

      var tx = document.createElement('span');
      tx.className = 'd-t';
      tx.textContent = t.text;
      tx.title = t.text;

      var go = document.createElement('button');
      go.className = 'd-go-btn';
      go.textContent = '今天';
      go.title = '放回今天，今天就看得见它';
      go.addEventListener('click', function (e) {
        e.stopPropagation();
        t.due = todayStart();
        persist();
        render();
        toast('放回今天了');
      });

      var wv = document.createElement('button');
      wv.className = 'd-wv';
      wv.textContent = '销账';
      wv.title = '记一笔放弃：不算完成，也不再欠着';
      wv.addEventListener('click', function (e) {
        e.stopPropagation();
        removeNode(t.id, 'writeoff');   // 认赔记一笔 q，跟"我不想要了"分开
        toast('已销账 · 不算完成');
      });

      row.appendChild(n);
      row.appendChild(tx);
      row.appendChild(go);
      row.appendChild(wv);
      host.appendChild(row);
    });

    var note = document.createElement('div');
    note.className = 'd-note';
    note.textContent = '销账 = 认下这件不做了。不算完成，也不再欠着。';
    host.appendChild(note);
  }

  /* 展开态要的东西和收起态不一样。
     收起态：日程是主体（日期、还剩几件、今天这几条）。
     展开态：下面就是完整的清单，日期和"还剩 N 件"是重复的；
            这里只该留「要你处理」的两条——日结、欠账。
     都没有就把整块清空（CSS 里 .agenda:empty 不占位置）。 */
  function trimForExpanded(host) {
    if (!el.agenda || document.body.classList.contains('collapsed')) return;
    var keep = host.querySelectorAll('.a-settle, .a-debt');
    if (!keep.length) { host.innerHTML = ''; return; }
    Array.prototype.slice.call(host.children).forEach(function (c) {
      if (!c.classList.contains('a-settle') && !c.classList.contains('a-debt')) {
        host.removeChild(c);
      }
    });
  }

  function renderAgenda() {
    if (!el.agenda) return;
    var info = agendaInfo();
    var host = el.agenda;
    host.innerHTML = '';

    if (debtOpen) { renderDebt(host); return; }

    var head = document.createElement('div');
    head.className = 'a-head';
    var day = document.createElement('span');
    day.className = 'a-day';
    day.textContent = agendaLabel(info.day);
    var meta = document.createElement('span');
    meta.className = 'a-meta';
    var total = info.list.length;
    var doneToday = info.todayDone || 0;
    var bits = [];
    if (total) bits.push('还剩 ' + total + ' 件');
    if (doneToday) bits.push('今日已做 ' + doneToday);
    var hasAny = state.nodes.some(function (n) { return n.type === 'task'; });
    if (bits.length) meta.textContent = bits.join(' · ');
    else meta.textContent = hasAny ? '已全部完成' : '还没有待办';
    if (info.nextDay && total) meta.title = '今天的都做完了，已自动接到' + agendaShort(info.day);
    head.appendChild(day);
    head.appendChild(meta);
    host.appendChild(head);

    // 日结：每天第一次打开露一次，看过就不再出现（标记写盘，重启也不重来）
    var settle = settleText();
    if (settle && !settleSeenToday()) {
      var pend = statsToday().pending;
      var sb = document.createElement('div');
      sb.className = 'a-settle';
      var stx = document.createElement('span');
      stx.className = 'st-t';
      stx.textContent = settle + ' · 今天' + (pend ? '还剩 ' + pend + ' 件' : '还没写');
      stx.title = '每天第一次打开时结一次，看过就不再出现';
      var sx = document.createElement('button');
      sx.className = 'st-x';
      sx.textContent = '✕';
      sx.title = '现在就收起来';
      sx.addEventListener('click', function (e) {
        e.stopPropagation();
        renderAgenda();
      });
      sb.appendChild(stx);
      sb.appendChild(sx);
      host.appendChild(sb);
      // 出现即算看过：不点 ✕ 也算，否则关掉再开又会来一次
      state.settle = dayKey(Date.now());
      persist();
    }

    // 欠账入口：原来这里只有半句话，点不动也销不掉
    var dl = debts();
    if (dl.length) {
      var db = document.createElement('button');
      db.className = 'a-debt';
      db.innerHTML = '有 <b>' + dl.length + '</b> 件拖了 2 天以上'
        + '<span class="d-max">最久 ' + (dl[0].carried || 0) + ' 天</span>'
        + '<span class="d-go">看</span>';
      db.title = '点开看是哪几件：可以放回今天，也可以销账';
      db.addEventListener('click', function (e) {
        e.stopPropagation();
        debtOpen = true;
        renderAgenda();
      });
      host.appendChild(db);
    }

    if (!total) {
      var em = document.createElement('div');
      em.className = 'a-empty';
      em.textContent = hasAny
        ? (doneToday ? '今日已完成 ' + doneToday + ' 件 · 明天见' : '这一天的都做完了 · 展开看全部')
        : '点箭头展开，写第一条待办';
      host.appendChild(em);
      trimForExpanded(host);
      return;
    }

    var MAX = 6;
    info.list.slice(0, MAX).forEach(function (t) { host.appendChild(agendaRow(t)); });
    if (total > MAX) {
      var more = document.createElement('button');
      more.className = 'a-more';
      more.textContent = '还有 ' + (total - MAX) + ' 件 · 点这里展开';
      more.addEventListener('click', function (e) {
        e.stopPropagation();
        setCollapsedState(false, true);
      });
      host.appendChild(more);
    }
    trimForExpanded(host);
  }

  /* 时间段提醒的下一次触发：从 fromMs 之后找最近的 hh:mm，超过结束日就没有了。
     以前只往后推一天，隔几天没开电脑就永远追不上（直接被标成"已结束"），
     这里改成一步跳到未来。 */
  function nextRangeAt(rg, fromMs) {
    var base = (typeof fromMs === 'number' && isFinite(fromMs)) ? fromMs : Date.now();
    var d = new Date(base);
    d.setSeconds(0, 0);
    var cur = d.getHours() * 60 + d.getMinutes();
    var target = rg.hh * 60 + rg.mm;
    if (cur >= target) d.setDate(d.getDate() + 1);
    d.setHours(rg.hh, rg.mm, 0, 0);
    var end = new Date(rg.to); end.setHours(23, 59, 59, 999);
    if (d.getTime() > end.getTime()) return null;
    return d.getTime();
  }

  function rangeLabel(rg) {
    var f = new Date(rg.from), e = new Date(rg.to);
    var fl = (f.getMonth() + 1) + '/' + f.getDate();
    var el2 = (e.getMonth() + 1) + '/' + e.getDate();
    return (fl === el2 ? fl : fl + '–' + el2) + ' 每天 ' + pad(rg.hh) + ':' + pad(rg.mm);
  }

  function updateChip(chip, t) {
    chip.className = 'chip';
    // 时间段提醒：每天同一时刻响，直到结束日
    if (t.range && !t.done) {
      if (t.fired) {
        chip.className = 'chip fired';
        chip.textContent = '已结束';
      } else {
        chip.className = 'chip range';
        chip.textContent = '每天 ' + pad(t.range.hh) + ':' + pad(t.range.mm);
      }
      chip.title = '时间段提醒：' + rangeLabel(t.range) + '（点击修改）';
      return;
    }
    if (t.done || !t.remindAt) {
      chip.className = 'chip none';
      chip.textContent = '⏰';
      chip.title = '设置提醒';
      return;
    }
    chip.title = '点击修改提醒';
    if (t.fired) {
      chip.className = 'chip fired';
      chip.textContent = dayStr(t.remindAt) + ' 已响';
      return;
    }
    var diff = t.remindAt - Date.now();
    if (diff <= 0) {
      chip.className = 'chip warn';
      chip.textContent = '现在';
      return;
    }
    var sameDay = new Date(t.remindAt).toDateString() === new Date().toDateString();
    if (!sameDay) {
      chip.textContent = dayStr(t.remindAt);
      return;
    }
    if (diff < 3600000) {
      chip.className = 'chip' + (diff < 300000 ? ' warn' : '');
      chip.textContent = Math.ceil(diff / 60000) + ' 分钟后';
    } else {
      chip.textContent = clockStr(t.remindAt);
    }
  }

