  /* ---------------- 今天 / 明天 / 后天：自动接续的日程 ----------------
     未完成的活过夜自动继承到第二天；当天全部勾完后，收起态自动接到下一天。 */

  function dayStart(ts) {
    var d = new Date(ts);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  }
  function todayStart() { return dayStart(Date.now()); }

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
        n.carried = Math.min((n.carried || 0) + Math.max(1, gap), 999);
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
    var m = el.agenda && el.agenda.querySelector('.a-meta');
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
      b.title = '这件已经在清单上放了 ' + t.carried + ' 天';
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
      var d = new Date(t.due || todayStart());
      d.setDate(d.getDate() + 1);
      t.due = dayStart(d.getTime());
      t.moved = true;
      persist();
      render();
      renderAgenda();
      agendaFlash('已顺延到 ' + agendaShort(t.due));
    });
    row.appendChild(mv);

    return row;
  }

  function renderAgenda() {
    if (!el.agenda) return;
    var info = agendaInfo();
    var host = el.agenda;
    host.innerHTML = '';

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
    var carried = info.list.filter(function (x) { return (x.carried || 0) >= 2; }).length;
    if (carried) bits.push(carried + ' 件拖了 2 天以上');
    if (doneToday) bits.push('今日已做 ' + doneToday);
    var hasAny = state.nodes.some(function (n) { return n.type === 'task'; });
    if (bits.length) meta.textContent = bits.join(' · ');
    else meta.textContent = hasAny ? '已全部完成' : '还没有待办';
    if (info.nextDay && total) meta.title = '今天的都做完了，已自动接到' + agendaShort(info.day);
    head.appendChild(day);
    head.appendChild(meta);
    host.appendChild(head);

    if (!total) {
      var em = document.createElement('div');
      em.className = 'a-empty';
      em.textContent = hasAny
        ? (doneToday ? '今日已完成 ' + doneToday + ' 件 · 明天见' : '这一天的都做完了 · 展开看全部')
        : '点箭头展开，写第一条待办';
      host.appendChild(em);
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

