  /* ---------------- 选择本地路径 ---------------- */
  function pickPath(mode, tag, start) {
    var id = tag || ('p' + (++pickSeq));
    pendingPick[id] = { mode: mode };
    send('pick', { mode: mode, id: id, start: start || '' });
  }

  window.__onPick = function (id, path, isDir) {
    delete pendingPick[id];
    if (!path) {
      // 面板被取消 / 没点文件：自动收掉"正在写入"，别让它一直挂着
      if (id.indexOf('nodeadd:') === 0) {
        toast('没有选择文件 · 已取消');
      } else {
        cancelTarget(false);
      }
      render();
      return;
    }

    // 一次选择，自动判断：文件夹 = 项目容器，文件 = 文件容器
    if (id === 'newany') {
      var np = addProject(baseName(path), path, isDir ? 'folder' : 'file');
      setTarget(np.id);
      el.input.focus();
      return;
    }

    if (id === 'newproject') {
      var pp = addProject(baseName(path), path, 'folder');
      setTarget(pp.id);
      el.input.focus();
      return;
    }

    if (id === 'newfile') {
      addFileTask(path);
      return;
    }

    // 容器内左下 ＋：把本地文件挂成这个容器的一个节点
    if (id.indexOf('nodeadd:') === 0) {
      addNodeWithPath(+id.slice(8), path, isDir);
      return;
    }

    // 重新绑定项目 / 文件容器（选错了换一个）
    if (id.indexOf('bind:') === 0) {
      var p = byId(+id.slice(5));
      if (p) {
        p.path = path;
        p.kind = isDir ? 'folder' : 'file';
        // 没手动改过名 → 跟着新路径走；改过 → 尊重用户的名字
        if (!p.custom) {
          var nm2 = isDir ? baseName(path) : baseName(path).replace(/\.[^.]+$/, '');
          if (nm2) p.text = nm2;
        }
        flashRowId = p.id;
      }
      persist();
      render();
      return;
    }

    // 重新绑定任务上的文件
    if (id.indexOf('tbind:') === 0) {
      var tt = byId(+id.slice(6));
      if (tt) {
        tt.path = path;
        if (!tt.custom) {
          var nm3 = baseName(path).replace(/\.[^.]+$/, '');
          if (nm3) tt.text = nm3;
        }
        flashRowId = tt.id;
      }
      persist();
      render();
    }
  };

  /* ---------------- + 菜单 ---------------- */
  function closeMenu() {
    el.popmenu.classList.remove('show');
    el.popmenu.innerHTML = '';
  }

  function openMenu() {
    if (el.popmenu.classList.contains('show')) { closeMenu(); return; }
    el.popmenu.innerHTML =
      '<button data-act="task"><span class="mi">＋</span>新建待办<span class="ms">回车</span></button>' +
      '<button data-act="any"><span class="mi">▤</span>从本地选择<span class="ms">文件 / 文件夹</span></button>' +
      '<button data-act="blank"><span class="mi">▧</span>新建空项目<span class="ms">先起名</span></button>';
    el.popmenu.classList.add('show');

    var r = document.getElementById('btnAdd').getBoundingClientRect();
    var w = 200, h = el.popmenu.offsetHeight;
    var left = r.right - w;
    if (left < 8) left = 8;
    var top = r.bottom + 6;
    if (top + h > window.innerHeight - 6) top = Math.max(6, r.top - h - 6);
    el.popmenu.style.left = left + 'px';
    el.popmenu.style.top = top + 'px';

    var btns = el.popmenu.querySelectorAll('button');
    for (var i = 0; i < btns.length; i++) {
      btns[i].addEventListener('click', function (e) {
        e.stopPropagation();
        var act = e.currentTarget.dataset.act;
        closeMenu();
        if (act === 'task') {
          if (el.input.value.trim()) {
            addTask(el.input.value);
            el.input.value = '';
          }
          el.input.focus();
        } else if (act === 'any') {
          pickPath('any', 'newany');
        } else if (act === 'blank') {
          var np = addProject('未命名', null, 'folder');
          targetProject = np.id;
          renamingId = np.id;
          updatePlaceholder();
          render();
        }
      });
    }
  }

  /* ---------------- 提醒抽屉 ---------------- */
  function closeDrawer() {
    if (!drawerId) return;
    drawerId = null;
    el.drawer.classList.remove('show');
    el.drawer.innerHTML = '';
    render();
  }

  function setRemind(id, ts, range) {
    var t = byId(id);
    if (!t) return;
    t.remindAt = ts;
    t.fired = false;
    if (range) t.range = range;
    else if (t.range) delete t.range;
    persist();
    closeDrawer();
  }

  function openDrawer(id) {
    var t = byId(id);
    if (!t) return;
    if (drawerId === id) { closeDrawer(); return; }
    drawerId = id;

    // 定时面板默认值：已有提醒就用它的时刻和日子，否则取 5 分钟后
    var base = t.remindAt ? new Date(t.remindAt) : new Date(Date.now() + 5 * 60000);
    if (base.getTime() <= Date.now()) base = new Date(Date.now() + 5 * 60000);
    var dayOffset = 0;
    if (t.remindAt) {
      var midnight = new Date(); midnight.setHours(0, 0, 0, 0);
      var d0 = new Date(t.remindAt); d0.setHours(0, 0, 0, 0);
      var off = Math.round((d0.getTime() - midnight.getTime()) / 86400000);
      if (off >= 0 && off <= 2) dayOffset = off;
    }

    // 自定义时间段默认值
    var today0 = new Date(); today0.setHours(0, 0, 0, 0);
    var rgBase = new Date(Date.now() + 5 * 60000);
    var fromDay = new Date(today0), toDay = new Date(today0);
    if (t.range) {
      fromDay = new Date(t.range.from); fromDay.setHours(0, 0, 0, 0);
      toDay = new Date(t.range.to); toDay.setHours(0, 0, 0, 0);
      rgBase = new Date(today0);
      rgBase.setHours(t.range.hh, t.range.mm, 0, 0);
    }

    el.drawer.innerHTML =
      '<div class="dr">' +
        '<div class="dr-h">' +
          '<span class="dr-t">提醒</span>' +
          '<span class="dr-n">' + escapeHtml(t.text) + '</span>' +
          '<button class="dr-x" id="drX">✕</button>' +
        '</div>' +

        '<div class="dr-row" id="drQuick">' +
          '<button data-min="5">5 分钟</button>' +
          '<button data-min="15">15 分钟</button>' +
          '<button data-min="30">30 分钟</button>' +
          '<button data-min="60">1 小时</button>' +
        '</div>' +

        '<div class="dr-seg" id="drSeg">' +
          '<button data-mode="range" class="on">自定义时间段</button>' +
          '<button data-mode="at">定时</button>' +
        '</div>' +

        '<div class="dr-pane on" id="paneRange">' +
          '<div class="dr-row">' +
            '<button class="dr-date" id="dFrom">--</button>' +
            '<span class="lb">至</span>' +
            '<button class="dr-date" id="dTo">--</button>' +
            '<span class="sp"></span>' +
            '<input id="rgH" type="text" inputmode="numeric" maxlength="2" value="' + pad(rgBase.getHours()) + '">' +
            '<span class="lb">:</span>' +
            '<input id="rgM" type="text" inputmode="numeric" maxlength="2" value="' + pad(rgBase.getMinutes()) + '">' +
          '</div>' +
          '<div class="cal" id="cal">' +
            '<div class="cal-h">' +
              '<button id="calPrev">‹</button>' +
              '<span class="cal-t" id="calTitle"></span>' +
              '<button id="calNext">›</button>' +
            '</div>' +
            '<div class="cal-w"><span>日</span><span>一</span><span>二</span><span>三</span><span>四</span><span>五</span><span>六</span></div>' +
            '<div class="cal-g" id="calGrid"></div>' +
          '</div>' +
        '</div>' +

        '<div class="dr-pane" id="paneAt">' +
          '<div class="dr-row">' +
            '<button class="dseg" data-day="0">今天</button>' +
            '<button class="dseg" data-day="1">明天</button>' +
            '<button class="dseg" data-day="2">后天</button>' +
            '<span class="sp"></span>' +
            '<input id="atH" type="text" inputmode="numeric" maxlength="2" value="' + pad(base.getHours()) + '">' +
            '<span class="lb">:</span>' +
            '<input id="atM" type="text" inputmode="numeric" maxlength="2" value="' + pad(base.getMinutes()) + '">' +
          '</div>' +
        '</div>' +

        '<button class="dr-go" id="drGo">⏰ 设为闹钟</button>' +
        (t.remindAt ? '<button class="dr-clear" id="drClear">清除提醒</button>' : '') +
      '</div>';

    el.drawer.classList.add('show');

    var q = function (sel) { return el.drawer.querySelector(sel); };
    var mode = 'range';

    /* 快捷时长：一点就设（延后） */
    var quick = el.drawer.querySelectorAll('#drQuick button');
    for (var i = 0; i < quick.length; i++) {
      quick[i].addEventListener('click', function (e) {
        setRemind(drawerId, Date.now() + (+e.currentTarget.dataset.min) * 60000);
      });
    }

    q('#drX').addEventListener('click', closeDrawer);

    /* 只允许数字 */
    var nums = el.drawer.querySelectorAll('.dr-pane input');
    for (var n = 0; n < nums.length; n++) {
      nums[n].addEventListener('input', function (e) {
        var v = e.target.value.replace(/\D/g, '').slice(0, 2);
        if (v !== e.target.value) e.target.value = v;
        e.target.classList.remove('bad');
        if (e.target.id === 'atH' || e.target.id === 'atM') syncDay();
      });
    }

    /* ---------- 自定义时间段：起止日期 + 内嵌月历 ---------- */
    var calTarget = 'from';
    var calY = fromDay.getFullYear(), calM = fromDay.getMonth();

    function dayLabel(d) { return (d.getMonth() + 1) + '/' + d.getDate(); }
    function sameDay(a, b) {
      return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
    }
    function calOpen() { return q('#cal').classList.contains('show'); }

    function refreshDates() {
      q('#dFrom').textContent = dayLabel(fromDay);
      q('#dTo').textContent = dayLabel(toDay);
      q('#dFrom').classList.toggle('editing', calOpen() && calTarget === 'from');
      q('#dTo').classList.toggle('editing', calOpen() && calTarget === 'to');
      q('#dFrom').classList.remove('bad');
      q('#dTo').classList.remove('bad');
    }

    function renderCal() {
      q('#calTitle').textContent = calY + ' 年 ' + (calM + 1) + ' 月 · 选' +
        (calTarget === 'from' ? '开始' : '结束');
      var grid = q('#calGrid');
      grid.innerHTML = '';
      var startPad = new Date(calY, calM, 1).getDay();
      var days = new Date(calY, calM + 1, 0).getDate();
      var today = new Date(); today.setHours(0, 0, 0, 0);
      for (var p = 0; p < startPad; p++) grid.appendChild(document.createElement('span'));
      for (var dn = 1; dn <= days; dn++) {
        (function (dn) {
          var d = new Date(calY, calM, dn);
          var b = document.createElement('button');
          b.type = 'button';
          b.textContent = dn;
          if (sameDay(d, today)) b.className = 'today';
          if (d >= fromDay && d <= toDay) b.classList.add('inrange');
          if (sameDay(d, fromDay) || sameDay(d, toDay)) b.classList.add('edge');
          b.addEventListener('click', function () {
            if (calTarget === 'from') {
              fromDay = new Date(d);
              if (toDay < fromDay) toDay = new Date(fromDay);
            } else {
              toDay = new Date(d);
              if (toDay < fromDay) fromDay = new Date(toDay);
            }
            refreshDates();
            renderCal();
          });
          grid.appendChild(b);
        })(dn);
      }
    }

    function openCal(which) {
      calTarget = which;
      var ref = (which === 'from') ? fromDay : toDay;
      calY = ref.getFullYear();
      calM = ref.getMonth();
      q('#cal').classList.add('show');
      refreshDates();
      renderCal();
      scheduleResize();
    }
    function closeCal() {
      q('#cal').classList.remove('show');
      refreshDates();
      scheduleResize();
    }

    q('#dFrom').addEventListener('click', function () {
      if (calOpen() && calTarget === 'from') closeCal(); else openCal('from');
    });
    q('#dTo').addEventListener('click', function () {
      if (calOpen() && calTarget === 'to') closeCal(); else openCal('to');
    });
    q('#calPrev').addEventListener('click', function () {
      calM--; if (calM < 0) { calM = 11; calY--; }
      renderCal();
    });
    q('#calNext').addEventListener('click', function () {
      calM++; if (calM > 11) { calM = 0; calY++; }
      renderCal();
    });
    refreshDates();

    /* 分段切换 */
    var segBtns = el.drawer.querySelectorAll('#drSeg button');
    for (var s = 0; s < segBtns.length; s++) {
      segBtns[s].addEventListener('click', function (e) {
        mode = e.currentTarget.dataset.mode;
        for (var k = 0; k < segBtns.length; k++) segBtns[k].classList.toggle('on', segBtns[k] === e.currentTarget);
        q('#paneRange').classList.toggle('on', mode === 'range');
        q('#paneAt').classList.toggle('on', mode === 'at');
        if (mode === 'at') { closeCal(); syncDay(); }
        scheduleResize();
      });
    }

    /* 选"今天"但时刻已过，自动挪到明天，避免设了个不会响的闹钟 */
    var dayBtns = el.drawer.querySelectorAll('.dr-pane .dseg');
    function markDay(off) {
      dayOffset = off;
      for (var k = 0; k < dayBtns.length; k++) {
        dayBtns[k].classList.toggle('on', +dayBtns[k].dataset.day === off);
      }
    }
    function syncDay() {
      var hh = parseInt(q('#atH').value, 10);
      var mm = parseInt(q('#atM').value, 10);
      if (isNaN(hh) || isNaN(mm) || hh > 23 || mm > 59) return;
      var d = new Date();
      d.setDate(d.getDate() + dayOffset);
      d.setHours(hh, mm, 0, 0);
      if (d.getTime() <= Date.now() && dayOffset < 2) markDay(dayOffset + 1);
    }
    for (var b = 0; b < dayBtns.length; b++) {
      dayBtns[b].addEventListener('click', function (e) {
        markDay(+e.currentTarget.dataset.day);
      });
    }
    markDay(dayOffset);

    /* 提交 */
    function commit() {
      if (mode === 'range') {
        var hh = parseInt(q('#rgH').value, 10);
        var mm = parseInt(q('#rgM').value, 10);
        var bad = false;
        if (isNaN(hh) || hh > 23) { q('#rgH').classList.add('bad'); bad = true; }
        if (isNaN(mm) || mm > 59) { q('#rgM').classList.add('bad'); bad = true; }
        if (bad) return;

        var start = new Date(fromDay); start.setHours(hh, mm, 0, 0);
        var endLimit = new Date(toDay); endLimit.setHours(23, 59, 59, 999);
        if (start.getTime() <= Date.now()) start.setDate(start.getDate() + 1);
        if (start.getTime() > endLimit.getTime()) {
          q('#dFrom').classList.add('bad');
          q('#dTo').classList.add('bad');
          toast('这段时间已经过去了');
          return;
        }
        setRemind(drawerId, start.getTime(), {
          from: fromDay.getTime(), to: toDay.getTime(), hh: hh, mm: mm
        });
      } else {
        var h2 = parseInt(q('#atH').value, 10);
        var m2 = parseInt(q('#atM').value, 10);
        if (isNaN(h2) || isNaN(m2) || h2 > 23 || m2 > 59) {
          if (h2 > 23 || isNaN(h2)) q('#atH').classList.add('bad');
          if (m2 > 59 || isNaN(m2)) q('#atM').classList.add('bad');
          return;
        }
        var d = new Date();
        d.setDate(d.getDate() + dayOffset);
        d.setHours(h2, m2, 0, 0);
        if (d.getTime() <= Date.now()) d.setDate(d.getDate() + 1);
        setRemind(drawerId, d.getTime());
      }
    }

    q('#drGo').addEventListener('click', commit);
    el.drawer.querySelectorAll('.dr-pane input').forEach(function (inp) {
      inp.addEventListener('keydown', function (e) {
        if (e.isComposing || e.keyCode === 229) return;
        if (e.key === 'Enter') { e.preventDefault(); commit(); }
      });
    });

    var clr = q('#drClear');
    if (clr) clr.addEventListener('click', function () { setRemind(drawerId, null); });

    render();
  }

  /* ---------------- 提醒触发 ---------------- */
  function showBanner(text) {
    el.bannerText.textContent = text;
    el.banner.classList.add('show');
    clearTimeout(bannerTimer);
    bannerTimer = setTimeout(function () {
      el.banner.classList.remove('show');
      scheduleResize();
    }, 7000);
    scheduleResize();
  }

  function fire(t) {
    t.fired = true;
    ringingId = t.id;
    send('alert', { title: t.text });
    showBanner(t.text);
    // 时间段提醒：响了之后自动排到下一天，直到结束日
    if (t.range && t.remindAt) {
      var next = nextRangeAt(t.range, Date.now());
      if (next) {
        t.remindAt = next;
        t.fired = false;
      }
    }
    persist();
    render();
    setTimeout(function () {
      ringingId = null;
      var node = el.list.querySelector('.task[data-id="' + t.id + '"]');
      if (node) node.classList.remove('ringing');
    }, 6000);
  }

  function checkDue() {
    var now = Date.now();
    var changed = false;
    state.nodes.forEach(function (t) {
      if (t.type !== 'task' || t.done || !t.remindAt || t.fired) return;
      if (now >= t.remindAt) {
        if (now - t.remindAt > 6 * 3600000) {
          // 错过太久：时间段提醒可以顺延到下一次，单次的直接标成已响
          if (t.range) {
            var nx = nextRangeAt(t.range, now);
            if (nx) { t.remindAt = nx; changed = true; return; }
          }
          t.fired = true;
          changed = true;
        } else {
          fire(t);
        }
      }
    });
    if (changed) persist();
  }

