  /* ---------------- 年轮公告 ----------------
     每年 12/20 到次年 1/15 出现一次，看过就不再打扰。
     12/20 之后看的是当年，1/15 之前看的是上一年。
     这里没有"又一年过去了"之类的煽情，只有这一年的数字。 */
  function annivYear(now) {
    var d = now || new Date(), m = d.getMonth() + 1, day = d.getDate();
    if (m === 1 && day <= 15) return d.getFullYear() - 1;
    if (m === 12 && day >= 20) return d.getFullYear();
    return 0;
  }
  window.__annivYear = annivYear;   // 给自动化测试用，不影响运行

  /* __tick 每秒调一次这里。yearStats 要扫满 365 天，
     每秒算一遍纯属浪费（12/20–1/15 那一个月里会一直算）。
     一天只判一次：跨天时 key 变了自然重算，跨年那一刻也能接上。 */
  var annivCheckedOn = '';

  function maybeAnniversary(force) {
    if (!force) {
      var tk = dayKey(Date.now());
      if (annivCheckedOn === tk) return false;
      annivCheckedOn = tk;
    }
    var y = force ? (annivYear() || new Date().getFullYear()) : annivYear();
    if (!y) return false;
    if (!force && state.anniv && state.anniv['seen' + y]) return false;
    var r = yearStats(y);
    if (r.total < 3) return false;        // 数字太少算不上年报，宁可不打扰
    el.annivTitle.textContent = y + ' 年轮';
    // active 是"有产出的天"，observed 是"我看得见的天"——两个数不能混着叫"有记录"
    el.annivSub.textContent = r.total + ' 件 · ' + r.active + ' 天有产出'
      + (r.observed > r.active ? ' · 看得见 ' + r.observed + ' 天' : '')
      + (r.longest >= 2 ? ' · 最长连 ' + r.longest + ' 天' : '');
    el.anniv.dataset.year = String(y);
    el.anniv.dataset.preview = force ? '1' : '0';
    el.anniv.classList.add('show');
    lastHeight = 0;
    setTimeout(scheduleResize, 0);
    return true;
  }

  function hideAnniversary() {
    el.anniv.classList.remove('show');
    lastHeight = 0;
    setTimeout(scheduleResize, 0);
  }

  function annivSeen() {
    if (el.anniv.dataset.preview === '1') return;    // 预览不算"看过了"
    var y = el.anniv.dataset.year;
    if (!y) return;
    if (!state.anniv || typeof state.anniv !== 'object') state.anniv = {};
    state.anniv['seen' + y] = 1;
    persist();
  }

  if (el.annivGo) el.annivGo.addEventListener('click', function (e) {
    e.stopPropagation();
    annivSeen();
    hideAnniversary();
    reportTab = 'yr';
    toggleReport(true);
  });

  if (el.annivX) el.annivX.addEventListener('click', function (e) {
    e.stopPropagation();
    annivSeen();
    hideAnniversary();
  });

  /* 排查用：直接摊开某一页报告（DESKTODO_REPORT=yr 启动即可截图核对） */
  window.__openReport = function (tab) {
    if (tab) reportTab = tab;
    toggleReport(true);
    return reportTab;
  };

  window.__annivPreview = function () {
    var ok = maybeAnniversary(true);
    if (!ok) toast('今年的记录还不到 3 件，攒够了再看');
    return ok;
  };

  /* 自检用：看一眼缩放换算对不对 */
  window.__metrics = function () {
    return {
      css: Math.round(el.wrap.getBoundingClientRect().height),
      scale: uiScale,
      reported: contentHeight()
    };
  };

  /* 排查用：把当前尺寸状态打到原生日志，只在需要时调用 */
  window.__diag = function () {
    var m = window.__metrics();
    m.collapsed = collapsed;
    m.manual = manualSaved;
    m.vh = window.innerHeight;
    m.bodyH = Math.round(document.body.getBoundingClientRect().height);
    send('log', { msg: 'DIAG ' + JSON.stringify(m) });
    return m;
  };

  function tickClock() {
    var d = new Date();
    el.hhmm.textContent = pad(d.getHours()) + ':' + pad(d.getMinutes());
    el.ss.textContent = pad(d.getSeconds());
    renderSub();
    updateProgress();
  }

  window.__load = function (data) {
    if (data && Array.isArray(data.nodes)) {
      state.nodes = data.nodes;
      state.seq = data.seq || (state.nodes.reduce(function (m, t) { return Math.max(m, t.id); }, 0) + 1);
    } else if (data && Array.isArray(data.tasks)) {
      state.nodes = data.tasks.map(function (t) {
        return {
          id: t.id, type: 'task', text: t.text, parentId: null, path: null,
          done: !!t.done, remindAt: t.remindAt || null, fired: !!t.fired,
          due: dayStart(t.created || Date.now()), created: t.created || 0
        };
      });
      state.seq = data.seq || (state.nodes.reduce(function (m, t) { return Math.max(m, t.id); }, 0) + 1);
      persist();
    } else {
      state.nodes = [];
      // 清空之后 id 计数器也回到 1：留着旧的值，等于把"你以前建过 57 个条目"
      // 这件事继续写在 data.json 里，那不是清空。
      state.seq = 1;
    }
    state.log = (data && Array.isArray(data.log)) ? data.log : [];
    state.daily = (data && data.daily && typeof data.daily === 'object') ? data.daily : {};
    state.flow = (data && data.flow && typeof data.flow === 'object') ? data.flow : {};
    state.byProj = (data && data.byProj && typeof data.byProj === 'object') ? data.byProj : {};
    state.anniv = (data && data.anniv && typeof data.anniv === 'object') ? data.anniv : {};
    state.fb = (data && Array.isArray(data.fb)) ? data.fb : [];
    state.hide = (data && data.hide && typeof data.hide === 'object') ? data.hide : {};
    state.gap = (data && data.gap && typeof data.gap === 'object') ? data.gap : {};
    state.gapOff = (data && Number(data.gapOff)) || 0;
    state.said = (data && data.said && typeof data.said === 'object') ? data.said : {};
    state.saidN = (data && data.saidN && typeof data.saidN === 'object') ? data.saidN : {};
    state.vote = (data && data.vote && typeof data.vote === 'object') ? data.vote : {};
    state.seen = (data && data.seen && typeof data.seen === 'object') ? data.seen : {};
    state.seenFrom = (data && typeof data.seenFrom === 'string') ? data.seenFrom : '';
    if (rollover()) persist();   // 跨夜：没做完的自动继承到今天
    render();
    tickClock();
    maybeAnniversary();
    setTimeout(scheduleResize, 120);
    setTimeout(scheduleResize, 400);
  };

