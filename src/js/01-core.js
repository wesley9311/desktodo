
  var bridge = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) || null;
  function send(type, obj) {
    if (!bridge) return;
    bridge.postMessage(Object.assign({ type: type }, obj || {}));
  }

  /* fb    用户点过的「不对/不该显示」记录（只在本机，不上报）
     hide  被用户隐藏的来源行
     gap   日级对账结果：{'YYYY-MM-DD': 0 没做事 / 1 忘了记}
     said  当月输出过的判断句（月级否决用）
     saidN 某类判断累计被说「不准」的次数，>=2 就永不再说
     vote  当月已投过的票，防重复打扰
     seen  {'YYYY-MM-DD': 1} 这天 app 开着。只有这个字段能区分
           「那天做了 0 件」和「那天我根本没开」——缺了它，年报会把
           所有没记录的日子都当成 0 件，那是伪造。 */
  var state = {
    nodes: [], seq: 1, log: [], daily: {}, flow: {}, byProj: {}, anniv: {},
    fb: [], hide: {}, gap: {}, gapOff: 0, said: {}, saidN: {}, vote: {},
    seen: {}, seenFrom: '',           // seenFrom = 第一次记下「这天开着」的日期，用来划清「之前不算」
    settle: ''                        // 日结条已经给哪天看过。存盘，否则一天开关三次就见三次
  };

  /* 数据格式版本。加字段只加不改；导出的"读我.md"里也写这个数——
     哪天这个 app 不在了，别人靠它对得上格式。 */
  var SCHEMA_V = 2;
  var weather = null;       // {city,temp,feels,hum,code,isDay,tmax,tmin,rain}
  var ext = null;           // 系统数据：{cal, rem, screen, focus}，读不到就是 null / st!=='ok'
  var reportOpen = false;
  var uiScale = 1;          // 视图缩放系数：页面上报的内容高度要按它折成实际点
  var el = {
    wrap: document.getElementById('wrap'),
    hhmm: document.getElementById('hhmm'),
    ss: document.getElementById('ss'),
    sub: document.getElementById('sub'),
    input: document.getElementById('input'),
    list: document.getElementById('list'),
    banner: document.getElementById('banner'),
    bannerText: document.getElementById('bannerText'),
    summary: document.getElementById('summary'),
    footer: document.getElementById('footer'),
    clear: document.getElementById('btnClear'),
    toast: document.getElementById('toast'),
    drawer: document.getElementById('drawer'),
    popmenu: document.getElementById('popmenu'),
    dragbar: document.getElementById('dragbar'),
    targetbar: document.getElementById('targetbar'),
    tgText: document.getElementById('tgText'),
    tgClear: document.getElementById('tgClear'),
    agenda: document.getElementById('agenda'),
    report: document.getElementById('report'),
    wx: document.getElementById('wx'),
    wxIcon: document.getElementById('wxIcon'),
    wxTemp: document.getElementById('wxTemp'),
    prog: document.getElementById('btnProg'),
    progN: document.getElementById('progN'),
    ringFg: document.getElementById('ringFg'),
    anniv: document.getElementById('anniv'),
    annivTitle: document.getElementById('annivTitle'),
    annivSub: document.getElementById('annivSub'),
    annivGo: document.getElementById('annivGo'),
    annivX: document.getElementById('annivX'),
    databar: document.getElementById('databar'),
    dbText: document.getElementById('dbText'),
    dbGo: document.getElementById('dbGo'),
    dbX: document.getElementById('dbX')
  };

  var collapsed = false;
  var ringingId = null;
  var drawerId = null;
  var targetProject = null;
  var inlineFocus = null;   // 回车提交后需要重新聚焦的行内输入所属项目 id
  var scrollToId = null;    // 新增节点后滚动到可见，避免“以为没写进去”
  var renamingId = null;    // 新建空项目后自动进入改名态
  var editingId = null;     // 正在就地改名的节点 id（render 时据此渲染成输入框）
  var editingIsProject = false;
  var clickTimer = null;    // 延迟折叠，给双击改名留出时间
  var flashRowId = null;    // 换绑后短暂高亮那一行，给个视觉回执
  var selectedDayOffset = 0;
  var pendingPick = {};
  var pickSeq = 0;
  var lastHeight = 0;
  var resizeTimer = null;
  var bannerTimer = null;
  var toastTimer = null;
  var toastActive = false;   // 底部状态文字正被临时提示占用
  var composing = false;     // 拼音选词中：这时候点外面不算"离开"
  var resizing = false;      // 正在拉窗口边缘
  var manualSaved = false;   // 用户自己定过尺寸
  var themeMode = 'auto';    // auto / light / dark

  var ICON_FOLDER = '<svg width="13" height="13" viewBox="0 0 14 14"><path d="M1.6 4.3c0-.55.45-1 1-1h2.5l1.05 1.25h5.25c.55 0 1 .45 1 1v4.35c0 .55-.45 1-1 1H2.6c-.55 0-1-.45-1-1V4.3z" fill="none" stroke="currentColor" stroke-width="1.15" stroke-linejoin="round"/></svg>';
  var ICON_FOLDER_OFF = '<svg width="13" height="13" viewBox="0 0 14 14"><path d="M1.6 4.3c0-.55.45-1 1-1h2.5l1.05 1.25h5.25c.55 0 1 .45 1 1v4.35c0 .55-.45 1-1 1H2.6c-.55 0-1-.45-1-1V4.3z" fill="none" stroke="currentColor" stroke-width="1.15" stroke-linejoin="round" stroke-dasharray="1.6 1.4"/></svg>';
  var ICON_DOC = '<svg width="11" height="12" viewBox="0 0 12 14"><path d="M2.2 1.4h4.3L9.8 4.5v8.1H2.2V1.4z" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/><path d="M6.4 1.5v3.2h3.3" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linejoin="round"/></svg>';
  var ICON_SWAP = '<svg width="12" height="12" viewBox="0 0 14 14"><path d="M2.8 4.9h7.1M8.3 3.2l1.7 1.7-1.7 1.7" fill="none" stroke="currentColor" stroke-width="1.15" stroke-linecap="round" stroke-linejoin="round"/><path d="M11.2 9.1H4.1M5.7 10.8 4 9.1l1.7-1.7" fill="none" stroke="currentColor" stroke-width="1.15" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  function pad(n) { return n < 10 ? '0' + n : '' + n; }
  function clockStr(ts) {
    var d = new Date(ts);
    return pad(d.getHours()) + ':' + pad(d.getMinutes());
  }
  function dayStr(ts) {
    var d = new Date(ts), n = new Date();
    var same = d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate();
    if (same) return clockStr(ts);
    return (d.getMonth() + 1) + '/' + d.getDate() + ' ' + clockStr(ts);
  }
  function weekday(d) {
    return ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][d.getDay()];
  }
  function byId(id) {
    for (var i = 0; i < state.nodes.length; i++) if (state.nodes[i].id === id) return state.nodes[i];
    return null;
  }
  function baseName(p) {
    var parts = (p || '').split('/').filter(Boolean);
    return parts.length ? parts[parts.length - 1] : '未命名';
  }

  /* 按扩展名自动判断文件类型：图标颜色和提示都跟着变 */
  var ICON_PDF = '<svg width="11" height="12" viewBox="0 0 12 14"><path d="M2.4 1.4h4.1L9.6 4.5v8.1H2.4V1.4z" fill="currentColor" fill-opacity=".16" stroke="currentColor" stroke-width="1.05" stroke-linejoin="round"/><path d="M3.9 8.9h1.1a1.05 1.05 0 0 0 0-2.1H3.9v3.3" fill="none" stroke="currentColor" stroke-width="1.05" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  var ICON_IMG = '<svg width="11" height="12" viewBox="0 0 12 14"><rect x="2" y="2.4" width="8" height="9.2" rx="1.2" fill="currentColor" fill-opacity=".16" stroke="currentColor" stroke-width="1.05"/><circle cx="4.6" cy="5.2" r="1" fill="currentColor"/><path d="M2.6 10.4 5.4 7.6l1.6 1.6 1.2-1.2 1.2 1.2" fill="none" stroke="currentColor" stroke-width="1.05" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  function fileKind(path) {
    var m = (path || '').match(/\.([A-Za-z0-9]+)$/);
    var ext = m ? m[1].toLowerCase() : '';
    var has = function (list) { return list.indexOf(ext) >= 0; };

    if (ext === 'pdf') return { key: 'pdf', label: 'PDF 文档', icon: ICON_PDF };
    if (has(['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'bmp', 'tiff', 'svg', 'avif']))
      return { key: 'img', label: '图片', icon: ICON_IMG };
    if (has(['doc', 'docx', 'pages', 'rtf', 'wps', 'odt']))
      return { key: 'doc', label: '文档', icon: ICON_DOC };
    if (has(['xls', 'xlsx', 'csv', 'tsv', 'numbers', 'et']))
      return { key: 'sheet', label: '表格', icon: ICON_DOC };
    if (has(['ppt', 'pptx', 'key', 'dps']))
      return { key: 'slide', label: '演示文稿', icon: ICON_DOC };
    if (has(['md', 'markdown', 'txt', 'log', 'json', 'js', 'ts', 'css', 'html', 'swift', 'py', 'sh', 'yaml', 'yml']))
      return { key: 'text', label: '文本', icon: ICON_DOC };
    if (has(['zip', 'rar', '7z', 'tar', 'gz']))
      return { key: 'zip', label: '压缩包', icon: ICON_DOC };
    if (!ext) return { key: 'file', label: '文件夹 / 无扩展名', icon: ICON_FOLDER };
    return { key: 'file', label: '文件', icon: ICON_DOC };
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function pendingCount() {
    return state.nodes.filter(function (n) { return n.type === 'task' && !n.done; }).length;
  }

  function persist() {
    send('save', {
      payload: JSON.stringify({
        v: SCHEMA_V,
        nodes: state.nodes, seq: state.seq, log: state.log || [], daily: state.daily || {},
        flow: state.flow || {}, byProj: state.byProj || {}, anniv: state.anniv || {},
        fb: state.fb || [], hide: state.hide || {}, gap: state.gap || {},
        gapOff: state.gapOff || 0, said: state.said || {}, saidN: state.saidN || {},
        vote: state.vote || {}, seen: state.seen || {}, seenFrom: state.seenFrom || '',
        settle: state.settle || ''
      })
    });
    send('status', { pending: pendingCount() });
  }

  function contentHeight() {
    var h = el.wrap.getBoundingClientRect().height;
    if (el.drawer.classList.contains('show')) h += el.drawer.getBoundingClientRect().height;
    // 视图放大后，页面里的 CSS 像素要折回窗口的实际点
    return Math.ceil(h * uiScale);
  }

  function scheduleResize() {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () {
      var h = contentHeight();
      if (h < 44) h = 44;
      if (Math.abs(h - lastHeight) > 3) {
        lastHeight = h;
        send('resize', { height: h });
      }
    }, 60);
  }

  function taskCmp(a, b) {
    if (a.done !== b.done) return a.done ? 1 : -1;
    var ar = a.remindAt || 0, br = b.remindAt || 0;
    if (ar && br) return ar - br;
    if (ar) return -1;
    if (br) return 1;
    return a.id - b.id;
  }

