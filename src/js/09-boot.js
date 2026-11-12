  /* ---------------- 交互 ---------------- */
  document.getElementById('btnAdd').addEventListener('click', function (e) {
    e.stopPropagation();
    openMenu();
  });

  el.input.addEventListener('keydown', function (e) {
    // 中文输入法选词时的回车不算提交，否则会把拼音当成任务写进去
    if (e.isComposing || e.keyCode === 229) return;
    if (e.key === 'Enter') {
      e.preventDefault();
      var v = el.input.value;
      if (!v.trim()) return;
      addTask(v);
      el.input.value = '';
    } else if (e.key === 'Escape') {
      if (targetProject) { targetProject = null; updatePlaceholder(); render(); }
      else el.input.blur();
    }
  });

  el.tgClear.addEventListener('click', function (e) {
    e.stopPropagation();
    targetProject = null;
    updatePlaceholder();
    render();
    el.input.focus();
  });

  el.clear.addEventListener('click', function () {
    var doneList = state.nodes.filter(function (n) { return n.type === 'task' && n.done; });
    if (!doneList.length) {
      toast('还还没有划掉一件');
      render();
      return;
    }
    var n = doneList.length;
    state.nodes = state.nodes.filter(function (x) { return !(x.type === 'task' && x.done); });
    persist();
    render();
    toast('清走已划掉的 · ' + n + ' 件');
  });

  document.getElementById('btnMore').addEventListener('click', function (e) {
    e.stopPropagation();
    send('menu');
  });

  function setCollapsedState(v, notify) {
    v = !!v;
    if (v === collapsed) return;
    collapsed = v;
    document.body.classList.toggle('collapsed', v);
    // 收起态高度跟着内容走（紧凑日程），手动尺寸只在展开态生效
    document.documentElement.classList.toggle('manual', manualSaved && !v);
    if (v) { closeDrawer(); closeMenu(); }
    if (notify !== false) send('collapse', { value: v });
    lastHeight = 0;
    render();
    tickClock();
    // 收起 / 展开都由内容高度决定，避免留下空白框
    setTimeout(scheduleResize, 0);
    setTimeout(scheduleResize, 240);
  }

  window.__setCollapsed = function (v) { setCollapsedState(v, false); };
  window.__toggleCollapse = function () { setCollapsedState(!collapsed, true); };
  window.__debugState = function () { return state; };
  window.__toast = function (t) { if (t) toast(String(t)); };

  /* 写盘失败：原生侧回执才会调到这里。
     这件事故意做得吵一点——界面一切正常、数据却没落盘，是最坏的一种失败。
     8 秒内只提示一次，免得磁盘真的满了的时候每勾一件弹一次。 */
  var saveFailAt = 0;
  window.__saveFail = function () {
    var now = Date.now();
    if (now - saveFailAt < 8000) return;
    saveFailAt = now;
    toast('保存失败：这次改动没写进磁盘');
  };

  /* 磁盘上的 ledger.json 被另一个实例改过：原生把那份合法 JSON 交过来，
     页面按磁盘版本重新载入（以磁盘为准，不让两边各写各的）。
     重载期间静音写盘——刚载入的就是磁盘版本，回写只会制造多余的写。
     解析失败就只提示、不动内存：宁可停在旧内容，也不拿半份数据覆盖。 */
  window.__storeConflict = function (diskJson) {
    var data = null;
    try { data = JSON.parse(String(diskJson || '')); } catch (err) { data = null; }
    if (!data || typeof data !== 'object') {
      toast('数据文件被另一个窗口改过，但那份文件读不出来，先不动当前内容');
      return false;
    }
    saveMuted = true;
    try {
      window.__load(data);
    } finally {
      saveMuted = false;
    }
    if (state.loadBlocked) {
      toast('数据文件被另一个窗口改过，那是一份更新版本的数据，先不载入');
      return false;
    }
    toast('数据文件被另一个窗口改过，已按磁盘版本重新载入');
    return true;
  };

  /* 外观：auto 跟随系统 / light / dark（Swift 侧同时切窗口材质） */
  window.__setTheme = function (mode) {
    themeMode = (mode === 'light' || mode === 'dark') ? mode : 'auto';
    var root = document.documentElement;
    if (themeMode === 'auto') root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', themeMode);
    lastHeight = 0;
    setTimeout(scheduleResize, 0);
  };

  /* 手动尺寸：高度由用户定，列表自己滚 */
  window.__setManual = function (v) {
    manualSaved = !!v;
    document.documentElement.classList.toggle('manual', manualSaved && !collapsed);
    lastHeight = 0;
    setTimeout(scheduleResize, 0);
  };

  /* 视图大小：只影响"页面高度→窗口高度"的换算，字体本身由原生侧 pageZoom 放大 */
  window.__setZoom = function (z) {
    var v = Number(z);
    uiScale = (v > 0.5 && v < 3) ? v : 1;
    lastHeight = 0;
    setTimeout(scheduleResize, 30);
    setTimeout(scheduleResize, 260);
  };

  /* ---------------- 外部数据来源（日历 / 提醒事项 / 屏幕） ----------------
     全部来自系统，读不到就不显示，不用 0 顶替。 */

  window.__ext = function (o) {
    ext = (o && typeof o === 'object') ? o : null;
    if (reportOpen) renderReport();
  };

  window.__extAuth = function (kind) { send('extAuth', { kind: kind || 'both' }); };
  window.__extRefresh = function () { send('extRefresh'); };

  /* 要离开窗口了：先问一句"现在方便收起吗"，顺手把没落地的写入取消 */
  window.__beforeBlur = function () {
    if (composing || resizing) return true;
    if (el.popmenu.classList.contains('show')) return true;
    if (editingId !== null) {
      var ae = document.activeElement;
      if (ae && ae.blur) { try { ae.blur(); } catch (err) {} }
    }
    return false;
  };

  window.__onBlur = function () {
    // 窗口已被原生 orderOut（收成小圆点）：从这一刻起渲染都不算「被看见」
    pageVisible = false;
    cancelTarget(true);
    closeMenu();
    clearTimeout(clickTimer);
    clickTimer = null;
  };

  window.__onShow = function () {
    // 先置可见再 render：日结条要等到这一步才允许落账（见 02-plan.js）
    pageVisible = true;
    if (rollover()) persist();
    render();
    tickClock();
    setTimeout(scheduleResize, 60);
  };

  document.getElementById('btnCollapse').addEventListener('click', function () {
    setCollapsedState(!collapsed, true);
  });

  var dragging = false, raf = 0;
  el.dragbar.addEventListener('pointerdown', function (e) {
    if (e.target.closest('button')) return;
    dragging = true;
    try { el.dragbar.setPointerCapture(e.pointerId); } catch (err) {}
    send('dragStart');
    e.preventDefault();
  });
  el.dragbar.addEventListener('pointermove', function () {
    if (!dragging || raf) return;
    raf = requestAnimationFrame(function () { raf = 0; send('dragMove'); });
  });
  function endDrag(e) {
    if (!dragging) return;
    dragging = false;
    try { el.dragbar.releasePointerCapture(e.pointerId); } catch (err) {}
  }
  el.dragbar.addEventListener('pointerup', endDrag);
  el.dragbar.addEventListener('pointercancel', endDrag);

  /* ---------- 窗口边缘：上下左右随意拉 ---------- */
  function bindGrip(node) {
    var edge = node.dataset.edge;
    node.addEventListener('pointerdown', function (e) {
      e.preventDefault();
      e.stopPropagation();
      resizing = true;
      document.body.classList.add('resizing');
      var sx = e.clientX, sy = e.clientY;
      send('resizeStart');
      try { node.setPointerCapture(e.pointerId); } catch (err) {}

      function onMove(ev) {
        send('resizeDrag', { edge: edge, dw: ev.clientX - sx, dh: ev.clientY - sy });
      }
      function onUp() {
        if (!resizing) return;
        resizing = false;
        document.body.classList.remove('resizing');
        node.removeEventListener('pointermove', onMove);
        node.removeEventListener('pointerup', onUp);
        node.removeEventListener('pointercancel', onUp);
        try { node.releasePointerCapture(e.pointerId); } catch (err) {}
        send('resizeEnd');
        window.__setManual(true);
      }
      node.addEventListener('pointermove', onMove);
      node.addEventListener('pointerup', onUp);
      node.addEventListener('pointercancel', onUp);
    });
  }
  var grips = document.querySelectorAll('.grip');
  for (var gi = 0; gi < grips.length; gi++) bindGrip(grips[gi]);

  /* 拼音选词中不算离开窗口，避免误收起 */
  document.addEventListener('compositionstart', function () { composing = true; });
  document.addEventListener('compositionend', function () { composing = false; });

  document.addEventListener('mousedown', function (e) {
    if (!el.popmenu.classList.contains('show')) return;
    if (e.target.closest('#btnAdd')) return;
    if (!el.popmenu.contains(e.target)) closeMenu();
  }, true);

  document.addEventListener('contextmenu', function (e) { e.preventDefault(); });

  /* 一秒一拍：给原生侧也能叫醒（收成小圆点时网页定时器会被系统降频） */
  window.__tick = function () {
    // 跨天补戳：哪怕整夜开着，第二天也会有记录，不会被当成"没记录"
    if (markSeen()) persist();
    if (rollover()) { persist(); render(); }
    tickClock();
    checkDue();
    refreshChips();
    // 跨年那一刻应用可能一直开着：每秒看一眼要不要出年度公告
    if (!el.anniv.classList.contains('show')) maybeAnniversary();
  };

  setInterval(function () {
    window.__tick();
  }, 1000);

  tickClock();

  setTimeout(function () {
    if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
  }, 80);

  window.addEventListener('load', function () {
    setTimeout(scheduleResize, 100);
  });
