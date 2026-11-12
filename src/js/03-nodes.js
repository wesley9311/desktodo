  /* ---------------- 渲染 ---------------- */
  function taskNode(t) {
    var li = document.createElement('li');
    li.className = 'task' + (t.done ? ' done' : '') +
      (t.id === ringingId ? ' ringing' : '') + (t.id === drawerId ? ' sel' : '');
    li.dataset.id = t.id;

    var chk = document.createElement('div');
    chk.className = 'check';
    chk.addEventListener('click', function (e) { e.stopPropagation(); toggleDone(t.id); });
    li.appendChild(chk);

    if (t.path) {
      var fk = fileKind(t.path);
      var doc = document.createElement('span');
      doc.className = 'doc-ic fk-' + fk.key;
      doc.innerHTML = fk.icon;
      doc.title = fk.label + '\n单击打开 · 双击更换文件\n' + t.path;
      var lastDoc = 0;
      doc.addEventListener('click', function (e) {
        e.stopPropagation();
        var now = Date.now();
        if (now - lastDoc < 380) { lastDoc = 0; return; }
        lastDoc = now;
        setTimeout(function () {
          if (lastDoc === now) send('open', { path: t.path });
        }, 240);
      });
      doc.addEventListener('dblclick', function (e) {
        e.stopPropagation();
        pickPath('any', 'tbind:' + t.id, t.path);
      });
      li.appendChild(doc);
    }

    if (editingId === t.id) {
      li.appendChild(nameEditor(t, false));
    } else {
      var title = document.createElement('div');
      title.className = 'title';
      title.textContent = t.text;
      title.title = t.text + '\n双击改名';
      title.addEventListener('dblclick', function () { beginEdit(t.id, false); });
      li.appendChild(title);
    }

    if (!t.done && (t.carried || 0) >= 2 && editingId !== t.id) {
      /* 拖了几天，在每天都会看的那张清单上得看得见。
         以前这个数只有收起态（小圆点）和日程视图里有，而那两个地方日常根本不去。 */
      var cd = document.createElement('button');
      cd.className = 'carry';
      cd.textContent = ((t.carried > 99) ? '99+' : t.carried) + '天';
      cd.title = '从到期那天算起，这件已经往后放了 ' + t.carried + ' 天\n点开看欠账：可以放回今天，也可以销账';
      cd.addEventListener('click', function (e) {
        e.stopPropagation();
        openDebts();
      });
      li.appendChild(cd);
    }

    if (!t.done && t.due && t.due > todayStart()) {
      var dt = document.createElement('button');
      dt.className = 'chip day';
      dt.textContent = agendaShort(t.due);
      dt.title = '排在' + agendaLabel(t.due) + '\n点一下再往后挪一天';
      dt.addEventListener('click', function (e) {
        e.stopPropagation();
        var nd = pushDue(t, 1);
        persist();
        render();
        toast('已顺延到 ' + agendaShort(nd));
      });
      li.appendChild(dt);
    }

    var chip = document.createElement('button');
    updateChip(chip, t);
    chip.addEventListener('click', function (e) {
      e.stopPropagation();
      openDrawer(t.id);
    });
    li.appendChild(chip);

    var del = document.createElement('button');
    del.className = 'del';
    del.textContent = '✕';
    del.title = '删除';
    del.addEventListener('click', function (e) { e.stopPropagation(); removeNode(t.id); });
    li.appendChild(del);

    return li;
  }

  function projectNode(p) {
    var li = document.createElement('li');
    li.className = 'project' + (p.collapsed ? ' collapsed' : '');
    li.dataset.id = p.id;

    var kids = state.nodes.filter(function (n) { return n.parentId === p.id; }).sort(taskCmp);
    var pending = kids.filter(function (k) { return !k.done; }).length;

    var head = document.createElement('div');
    head.className = 'p-head' + (targetProject === p.id ? ' targeting' : '');

    var caret = document.createElement('span');
    caret.className = 'p-caret';
    caret.textContent = '▾';
    head.appendChild(caret);

    var isFile = (p.kind === 'file');
    var ic = document.createElement('span');
    ic.className = 'p-ic' + (p.path ? '' : ' nolink');
    ic.innerHTML = p.path ? (isFile ? ICON_DOC : ICON_FOLDER) : (isFile ? ICON_DOC : ICON_FOLDER_OFF);
    ic.title = p.path
      ? ((isFile ? '单击打开文件' : '单击在访达中打开') + '\n双击更换绑定\n' + p.path)
      : '未绑定本地路径，点一下绑定';
    ic.style.cursor = 'pointer';
    if (p.path) {
      var lastIc = 0;
      ic.addEventListener('click', function (e) {
        e.stopPropagation();
        var now = Date.now();
        if (now - lastIc < 380) { lastIc = 0; return; }
        lastIc = now;
        setTimeout(function () {
          if (lastIc === now) send('open', { path: p.path });
        }, 240);
      });
      ic.addEventListener('dblclick', function (e) {
        e.stopPropagation();
        pickPath('any', 'bind:' + p.id, p.path);
      });
    } else {
      ic.addEventListener('click', function (e) {
        e.stopPropagation();
        pickPath('any', 'bind:' + p.id, '');
      });
    }
    head.appendChild(ic);

    if (editingId === p.id) {
      head.appendChild(nameEditor(p, true));
    } else {
      var name = document.createElement('span');
      name.className = 'p-name';
      name.textContent = p.text;
      name.title = (p.path || p.text) + '\n双击改名';
      name.addEventListener('dblclick', function (e) {
        e.stopPropagation();
        beginEdit(p.id, true);
      });
      head.appendChild(name);
    }

    if (kids.length) {
      var cnt = document.createElement('span');
      cnt.className = 'p-count';
      cnt.textContent = pending + '/' + kids.length;
      head.appendChild(cnt);
    }

    var addBtn = document.createElement('button');
    addBtn.className = 'p-act';
    addBtn.innerHTML = '＋';
    addBtn.title = '往这个项目里派一件活';
    addBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      targetProject = (targetProject === p.id) ? null : p.id;
      updatePlaceholder();
      el.input.focus();
      render();
    });
    head.appendChild(addBtn);

    var bindBtn = document.createElement('button');
    bindBtn.className = 'p-act' + (p.path ? ' haslink' : '');
    bindBtn.innerHTML = p.path ? ICON_SWAP : ICON_FOLDER;
    bindBtn.title = p.path
      ? ('更换本地文件 / 文件夹\n当前：' + p.path)
      : '绑定本地文件 / 文件夹';
    bindBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      pickPath('any', 'bind:' + p.id, p.path || '');
    });
    head.appendChild(bindBtn);

    var rm = document.createElement('button');
    rm.className = 'p-act rm';
    rm.textContent = '✕';
    rm.title = '删除（里面的节点会移到外面）';
    rm.addEventListener('click', function (e) {
      e.stopPropagation();
      removeProject(p.id);
    });
    head.appendChild(rm);

    head.addEventListener('click', function (e) {
      if (e.target.closest('.p-act')) return;
      if (e.target.tagName === 'INPUT') return;
      // 延迟折叠：留出双击进入改名的时间，避免双击时先被折叠打断
      if (clickTimer) { clearTimeout(clickTimer); clickTimer = null; return; }
      clickTimer = setTimeout(function () {
        clickTimer = null;
        p.collapsed = !p.collapsed;
        persist();
        render();
      }, 190);
    });

    li.appendChild(head);

    if (!p.collapsed) {
      var sub = document.createElement('ul');
      sub.className = 'p-sub';
      kids.forEach(function (k) { sub.appendChild(taskNode(k)); });
      sub.appendChild(inlineAdd(p));
      li.appendChild(sub);
    }

    return li;
  }

  /* 项目 / 文件容器内的一行输入：直接命名就能写入 */
  function inlineAdd(p) {
    var li = document.createElement('li');
    li.className = 'p-add';
    li.dataset.pid = p.id;

    // 左侧 ＋ 是隐藏的本地入口：选文件（PDF / 文档 / 图片…）自动判断格式挂进这个容器
    var ic = document.createElement('button');
    ic.className = 'p-add-ic';
    ic.type = 'button';
    ic.textContent = '＋';
    ic.title = '从本地选一个文件挂进来（PDF、文档、图片都行，自动识别）';
    ic.addEventListener('click', function (e) {
      e.stopPropagation();
      pickPath('any', 'nodeadd:' + p.id, '');
    });
    li.appendChild(ic);

    var inp = document.createElement('input');
    inp.type = 'text';
    inp.maxLength = 90;
    inp.setAttribute('autocomplete', 'off');
    inp.placeholder = '在「' + p.text + '」里加一件，回车确认';
    inp.addEventListener('keydown', function (e) {
      if (e.isComposing || e.keyCode === 229) return;   // 中文输入法选词中，不算提交
      if (e.key === 'Enter') {
        e.preventDefault();
        var v = inp.value.trim();
        if (!v) return;
        inp.value = '';
        addTaskTo(p.id, v, true);
      } else if (e.key === 'Escape') {
        inp.value = '';
        inp.blur();
      }
    });
    li.appendChild(inp);

    return li;
  }

  function render() {
    el.list.innerHTML = '';
    var projects = state.nodes.filter(function (n) { return n.type === 'project'; })
      .sort(function (a, b) { return a.id - b.id; });
    var loose = state.nodes.filter(function (n) {
      return n.type === 'task' && (!n.parentId || !byId(n.parentId));
    }).sort(taskCmp);

    if (!state.nodes.length) {
      var li = document.createElement('li');
      li.className = 'empty';
      li.textContent = '还没有活。回车记一件，或点 ＋ 新建项目';
      el.list.appendChild(li);
    } else {
      projects.forEach(function (p) { el.list.appendChild(projectNode(p)); });
      loose.forEach(function (t) { el.list.appendChild(taskNode(t)); });
    }

    updateSummary();
    updatePlaceholder();
    renderAgenda();
    updateProgress();
    if (reportOpen) renderReport();
    scheduleResize();

    // 行内输入连续录入：重建 DOM 后把焦点还回去
    if (inlineFocus !== null) {
      var box = el.list.querySelector('.p-add[data-pid="' + inlineFocus + '"] input');
      inlineFocus = null;
      if (box) { try { box.focus(); } catch (err) {} }
    }

    // 刚新增的节点滚到可见位置
    if (scrollToId !== null) {
      var row = el.list.querySelector('[data-id="' + scrollToId + '"]');
      scrollToId = null;
      if (row && row.scrollIntoView) {
        try { row.scrollIntoView({ block: 'nearest' }); } catch (err) { row.scrollIntoView(false); }
      }
    }

    // 换绑路径后，短暂高亮那一行并滚到可见，给个明确回执
    if (flashRowId !== null) {
      var fid = flashRowId;
      flashRowId = null;
      var frow = el.list.querySelector('[data-id="' + fid + '"]');
      if (frow) {
        var fhead = frow.classList.contains('project') ? frow.querySelector('.p-head') : frow;
        if (fhead) {
          fhead.classList.add('justlinked');
          setTimeout(function () { fhead.classList.remove('justlinked'); }, 1200);
        }
        try { frow.scrollIntoView({ block: 'nearest' }); } catch (err) {}
      }
    }

    // 新建空项目后直接进入改名
    if (renamingId !== null) {
      var rid = renamingId;
      renamingId = null;
      editingId = rid;
      editingIsProject = true;
      render();
    }
  }

  function updateSummary() {
    var pending = 0, done = 0;
    state.nodes.forEach(function (n) {
      if (n.type === 'task') { n.done ? done++ : pending++; }
    });
    if (!toastActive) {
      if (!state.nodes.length) el.summary.textContent = '';
      else if (pending === 0) el.summary.textContent = '全部划掉 · 共 ' + done + ' 件';
      else el.summary.textContent = '还剩 ' + pending + ' 件事' + (done ? ' · ' + done + ' 件已划掉' : '');
    }
    el.footer.classList.toggle('hidden', state.nodes.length === 0);

    // 一键清除：有勾选的项才亮起，并带上数量
    el.clear.classList.toggle('idle', done === 0);
    el.clear.innerHTML = '一键清除' + (done ? '<span class="cnt">' + done + '</span>' : '');
    el.clear.title = done
      ? ('清走已划掉的 ' + done + ' 件')
      : '还没有划掉一件';
  }

  /* 轻提示：优先就地替换底部状态文字（不遮挡、不改变窗口高度） */
  function toast(text) {
    clearTimeout(toastTimer);
    /* 判据必须是「footer 此刻是否真的占位置」，不能看 .hidden 类：
       收起态 footer 是被 CSS display:none 的，类上没有 .hidden，
       以前照这个类走的话提示写进隐藏的 footer，屏幕上什么都没有
       ——连「保存失败」都发不出来，那是最坏的一种静默。 */
    var footVisible = el.footer && el.footer.offsetParent !== null;
    if (footVisible) {
      toastActive = true;
      el.summary.textContent = text;
      el.summary.classList.add('flash');
      toastTimer = setTimeout(function () {
        toastActive = false;
        el.summary.classList.remove('flash');
        updateSummary();
      }, 1700);
    } else if (el.toast) {
      el.toast.textContent = text;
      el.toast.classList.add('show');
      toastTimer = setTimeout(function () {
        el.toast.classList.remove('show');
      }, 1700);
    }
  }

  function updatePlaceholder() {
    var p = targetProject ? byId(targetProject) : null;
    if (p) {
      el.input.placeholder = '回车记到「' + p.text + '」';
      el.input.classList.add('targeting');
      el.tgText.textContent = '正在写入 · ' + (p.kind === 'file' ? '文件 ' : '') + p.text;
      el.targetbar.classList.add('show');
    } else {
      el.input.placeholder = '写一件要办的事，回车记上';
      el.input.classList.remove('targeting');
      el.targetbar.classList.remove('show');
      targetProject = null;
    }
  }

  function setTarget(id) {
    targetProject = id;
    inlineFocus = null;
    updatePlaceholder();
    render();
  }

  /* 取消"正在写入"这个目标：点外面、或者选文件时没选，都走这里 */
  function cancelTarget(silent) {
    if (!targetProject) return false;
    var p = byId(targetProject);
    var name = p ? p.text : '';
    targetProject = null;
    updatePlaceholder();
    render();
    if (!silent) toast('已取消写入' + (name ? ' · ' + name : ''));
    return true;
  }

  function refreshChips() {
    var nodes = el.list.querySelectorAll('.task');
    for (var i = 0; i < nodes.length; i++) {
      var t = byId(+nodes[i].dataset.id);
      var chip = nodes[i].querySelector('.chip');
      if (t && chip) updateChip(chip, t);
    }
  }

  /* ---------------- 增删改 ---------------- */
  function addTask(text, remindAt) {
    text = (text || '').trim();
    if (!text) return null;
    var pid = targetProject || null;
    var t = {
      id: state.seq++, type: 'task', text: text.slice(0, 90),
      parentId: pid, path: null,
      done: false, remindAt: remindAt || null, fired: false,
      due: todayStart(),
      created: Date.now()
    };
    state.nodes.push(t);
    bumpFlow('n', 1);
    if (pid) { var p = byId(pid); if (p) p.collapsed = false; }
    scrollToId = t.id;
    persist();
    render();
    return t;
  }

  /* 指定项目 / 文件容器内的新增，不受顶部输入目标影响 */
  function addTaskTo(pid, text, keepFocus) {
    text = (text || '').trim();
    if (!text) return null;
    var p = byId(pid);
    var t = {
      id: state.seq++, type: 'task', text: text.slice(0, 90),
      parentId: pid, path: null,
      done: false, remindAt: null, fired: false,
      due: todayStart(),
      created: Date.now()
    };
    state.nodes.push(t);
    bumpFlow('n', 1);
    if (p) p.collapsed = false;
    if (keepFocus) inlineFocus = pid; else scrollToId = t.id;
    persist();
    render();
    return t;
  }

  function addProject(name, path, kind) {
    var p = {
      id: state.seq++, type: 'project', text: (name || '未命名').slice(0, 40),
      path: path || null, kind: kind || 'folder', collapsed: false, created: Date.now()
    };
    state.nodes.push(p);
    persist();
    render();
    return p;
  }

  function addFileTask(path) {
    var name = baseName(path).replace(/\.[^.]+$/, '');
    var t = {
      id: state.seq++, type: 'task', text: name || '文件任务',
      parentId: targetProject || null, path: path,
      done: false, remindAt: null, fired: false,
      due: todayStart(),
      created: Date.now()
    };
    state.nodes.push(t);
    // 这也是一条「新建」，和 addTask / addTaskTo / addNodeWithPath 一样要记进流水：
    // 少记一笔，年度「新写 N 件」就比真实少，flowLine 的"多做/少做"跟着偏。
    bumpFlow('n', 1);
    if (targetProject) { var pp = byId(targetProject); if (pp) pp.collapsed = false; }
    persist();
    render();
    return t;
  }

  /* 从本地挂一个文件/文件夹进指定容器（左侧 ＋ 的隐藏入口） */
  function addNodeWithPath(pid, path, isDir) {
    var base = baseName(path);
    var name = isDir ? base : base.replace(/\.[^.]+$/, '');
    var t = {
      id: state.seq++, type: 'task', text: (name || base || '本地文件').slice(0, 90),
      parentId: pid || null, path: path,
      done: false, remindAt: null, fired: false,
      due: todayStart(),
      created: Date.now()
    };
    var p = pid ? byId(pid) : null;
    state.nodes.push(t);
    bumpFlow('n', 1);
    if (p) p.collapsed = false;
    flashRowId = t.id;
    persist();
    render();
    return t;
  }

  /* why = 'writeoff' 是用户主动认赔（销账）；其余都是普通删除。
     这两件事以前合成一笔「删掉」，于是一个人的"我认下了这件事不做了"
     和"这条我不想要了"看起来一模一样——账本允许认赔，但认赔的人自己看不见。
     口径只加不减：老的 x 不重算、不反推，q 从这一版开始单独记。 */
  function removeNode(id, why) {
    var gone = byId(id);
    // 只有"删掉一件没做完的"才算放弃；删已划掉的只是清理，不该记成放弃
    if (gone && gone.type === 'task' && !gone.done) {
      bumpFlow(why === 'writeoff' ? 'q' : 'x', 1);
    }
    state.nodes = state.nodes.filter(function (n) { return n.id !== id; });
    if (drawerId === id) { drawerId = null; el.drawer.classList.remove('show'); el.drawer.innerHTML = ''; }
    if (targetProject === id) targetProject = null;
    persist();
    render();
  }

  function removeProject(id) {
    state.nodes.forEach(function (n) {
      if (n.parentId === id) n.parentId = null;
    });
    state.nodes = state.nodes.filter(function (n) { return n.id !== id; });
    if (targetProject === id) targetProject = null;
    persist();
    render();
  }

  function toggleDone(id) {
    var t = byId(id);
    if (!t) return;
    if (t.done) {
      markUndone(t);
    } else {
      markDone(t);
      /* 单次提醒划掉就清（已经做到了，别再响）；
         时间段提醒是"每天这个点，到结束日"的常设承诺，划掉时保留它，
         取消勾选时由 markUndone 重新算下一次，否则 chip 写着「每天 09:30」
         而 remindAt 是空，checkDue 永远跳过 = 提醒静默死亡。 */
      if (!t.range) t.remindAt = null;
      t.fired = false;
    }
    persist();
    render();
  }

  /* ---------------- 就地改名（状态驱动，重建 DOM 也不会丢编辑态） ---------------- */
  function beginEdit(id, isProject) {
    editingId = id;
    editingIsProject = !!isProject;
    render();
  }

  function nameEditor(node, isProject) {
    var inp = document.createElement('input');
    inp.type = 'text';
    inp.maxLength = 90;
    inp.className = isProject ? 'p-edit' : 't-edit';
    inp.value = node.text;
    inp.setAttribute('autocomplete', 'off');
    inp.setAttribute('spellcheck', 'false');

    var closed = false;
    function commit(save) {
      if (closed) return;
      closed = true;
      if (save) {
        var v = inp.value.trim();
        if (v && v !== node.text) {
          node.text = v.slice(0, 90);
          node.custom = true;   // 亲手命名 → 以后换绑定路径不再被文件名覆盖
        }
      }
      editingId = null;
      persist();
      render();
    }

    inp.addEventListener('keydown', function (e) {
      if (e.isComposing || e.keyCode === 229) return;
      if (e.key === 'Enter') { e.preventDefault(); commit(true); }
      else if (e.key === 'Escape') { e.preventDefault(); commit(false); }
      e.stopPropagation();
    });
    inp.addEventListener('blur', function () { commit(true); });
    inp.addEventListener('click', function (e) { e.stopPropagation(); });
    inp.addEventListener('dblclick', function (e) { e.stopPropagation(); });

    setTimeout(function () {
      try { inp.focus(); inp.select(); } catch (err) {}
    }, 0);
    return inp;
  }

  function editTitle(id, node, isProject) {
    beginEdit(id, isProject);
  }

