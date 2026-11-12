/* ══════════════════════════════════════════════════════════════
   FileSync 控制台 · 前端逻辑
   400ms 轮询 /api/state，DOM 增量更新（不重建节点，按钮不会闪）
   ══════════════════════════════════════════════════════════════ */

'use strict';

const $  = (id) => document.getElementById(id);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

const RING_CIRC = 358.14;   // 2π × 57，与 app.css 里的半径一致

const state = {
  data: null,
  page: 'overview',
  failStreak: 0,
  lastOkAt: 0,
  settingsDirty: false,
  settingsFilled: false,
  logsLoaded: false,
  disksLoaded: false,
  currentLog: null,
  lastIssueKey: '',
  lastActKey: '',
  lastChipKey: '',
};

/* ─────────────── 工具 ─────────────── */
function pad2(n) { return String(n).padStart(2, '0'); }

function clockText(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d)) return '';
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

function hhmm(iso) {
  const t = clockText(iso);
  return t ? t.slice(0, 5) : '';
}

function agoText(ms) {
  if (!ms) return '—';
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 3) return '刚刚';
  if (s < 60) return `${Math.floor(s)} 秒前`;
  if (s < 3600) return `${Math.floor(s / 60)} 分钟前`;
  if (s < 86400) return `${Math.floor(s / 3600)} 小时前`;
  return `${Math.floor(s / 86400)} 天前`;
}

function fmtBytes(n) {
  n = Number(n) || 0;
  if (n < 1024) return n + ' B';
  const u = ['KB', 'MB', 'GB', 'TB'];
  let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
  return n.toFixed(n >= 100 ? 0 : n >= 10 ? 1 : 2) + ' ' + u[i];
}

function escapeHtml(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/* ─────────────── 请求 ─────────────── */
async function apiGet(path) {
  const r = await fetch(path, { cache: 'no-store' });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.json();
}

async function apiPost(path, body) {
  const r = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-DiskSync': '1' },
    body: JSON.stringify(body || {}),
  });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.json();
}

/* ─────────────── Toast ─────────────── */
function toast(msg, kind = 'info', ms = 3200) {
  const box = $('toasts');
  const el = document.createElement('div');
  el.className = 'toast';
  el.dataset.k = kind;
  el.innerHTML = `<span class="t-dot"></span><span>${escapeHtml(msg)}</span>`;
  box.appendChild(el);
  setTimeout(() => {
    el.style.transition = 'opacity .18s, transform .18s';
    el.style.opacity = '0';
    el.style.transform = 'translateY(6px)';
    setTimeout(() => el.remove(), 200);
  }, ms);
}

/* ─────────────── 页面切换 ─────────────── */
const PAGE_META = {
  overview: ['概览', '这块硬盘、这个文件夹，两端一致'],
  disk:     ['硬盘', '按序列号认盘，换 USB 口也认得出'],
  logs:     ['日志', '每次同步的原始记录'],
  settings: ['设置', '改完立刻生效'],
};

function switchPage(name) {
  if (!PAGE_META[name]) name = 'overview';
  state.page = name;
  if (location.hash !== '#' + name) {
    history.replaceState(null, '', '#' + name);
  }
  $$('.nav-item').forEach(b => b.classList.toggle('is-active', b.dataset.page === name));
  $$('.page').forEach(p => { p.hidden = p.id !== 'page-' + name; });
  const meta = PAGE_META[name] || ['', ''];
  $('pgTitle').textContent = meta[0];
  $('pgSub').textContent = meta[1];

  if (name === 'disk') {
    if (!state.disksLoaded) loadDisks();
    if (!histOpenSnap) loadHistory();
  }
  if (name === 'logs' && !state.logsLoaded) loadLogs();
  if (name === 'settings') fillSettings(true);
}

/* ─────────────── 渲染概览 ─────────────── */
function modeOf(s, srv) {
  if (!srv.watchAlive) return 'err';
  if (s.syncing) return 'work';
  if (s.mode === 'Error') return 'err';
  if (s.mode === 'Warn') return 'warn';
  if (s.mode === 'Done') return 'done';
  if (s.mode === 'Work') return 'work';
  return 'idle';
}

const BADGE = {
  work: '正在同步', done: '已完成', warn: '部分完成', err: '需要处理', idle: '待命',
};

function setChips(list) {
  const key = list.map(x => x.text).join('|');
  if (key === state.lastChipKey) return;
  state.lastChipKey = key;
  $('heroChips').innerHTML = list.map(x =>
    `<span class="chip">${x.icon
      ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><use href="#i-check"/></svg>'
      : ''}${escapeHtml(x.text)}</span>`
  ).join('');
}

/* ─────────────── 概览：任务摘要行 ─────────────── */
function renderTaskRows(d) {
  const card = $('tasksCard'), box = $('taskRows');
  if (!card || !box) return;
  const tasks = (d.config && d.config.tasks) || [];
  if (!tasks.length) { card.hidden = true; return; }
  card.hidden = false;
  box.innerHTML = tasks.map(t => {
    const dests = (t.dests || []).map(dd => {
      const dot = dd.kind === 'folder' ? 'ok' : (dd.online ? 'ok' : 'off');
      const st = dd.kind === 'folder' ? '本地文件夹' : (dd.online ? '在线' : '未插入');
      const last = dd.lastSyncAt ? ' · 上次 ' + escapeHtml(dd.lastSyncAt) : '';
      return `<span class="dest-chip"><span class="led ${dot === 'ok' ? 'ok' : 'warn'}"></span>${escapeHtml(destText(dd))}<i>${st}${last}</i></span>`;
    }).join('') || '<span class="dest-chip"><i>还没有目的地</i></span>';
    return `<div class="task-row">
      <b class="tr-name">${escapeHtml(t.name)}</b>
      <div class="tr-flow">
        <code class="tr-src" title="${escapeHtml(t.source)}">${escapeHtml(t.source || '—')}</code>
        <svg class="tr-arr" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><use href="#i-arrow"/></svg>
        <div class="tr-dests">${dests}</div>
      </div>
    </div>`;
  }).join('');
}

function renderOverview(d) {
  const s = d.sync || {};
  const srv = d.server || {};
  const mode = modeOf(s, srv);

  const hero = $('heroCard');
  hero.dataset.mode = mode;

  let badge = BADGE[mode];
  const isBound = !!(d.bind && d.bind.bound);
  if (mode === 'idle' && !isBound) badge = '未绑定';
  else if (mode === 'idle' && s.connected === false) badge = '未连接';
  if (mode === 'err' && !srv.watchAlive) badge = '监听未运行';
  $('heroBadge').textContent = badge;
  $('heroTime').textContent = s.ts ? clockText(s.ts) : '';

  $('heroTitle').textContent = s.title || '等待状态…';
  $('heroDetail').textContent = s.detail || '';

  // ── 环形进度 ──
  const pct = Math.max(0, Math.min(100, Number(s.percent) || 0));
  const showRing = !!(s.syncing || pct > 0 || mode === 'done' || mode === 'warn');
  const ringPct = mode === 'done' ? 100 : pct;
  const ring = $('ringValue');
  ring.style.strokeDasharray = showRing
    ? `${(RING_CIRC * ringPct / 100).toFixed(1)} ${RING_CIRC}`
    : `0 ${RING_CIRC}`;
  const numTxt = showRing ? String(ringPct) : '—';
  $('ringNum').textContent = numTxt;
  $('ringNum').dataset.len = numTxt.length;
  $('ringUnit').textContent = showRing ? '%' : '';

  // ── 胶囊标签：速度 / 剩余 / 提示 ──
  const chips = [];
  if (s.meta) {
    String(s.meta).split('·').map(x => x.trim()).filter(Boolean)
      .forEach(t => chips.push({ text: t }));
  }
  if (s.hint) chips.push({ text: s.hint, icon: mode === 'done' });
  setChips(chips);

  // ── 顶栏主按钮（图标跟着文字一起换）──
  const topBtn = $('btnPrimary');
  const topTxt = $('btnPrimaryText');
  const topIco = topBtn.querySelector('use');
  if (s.syncing) {
    topTxt.textContent = '停止同步';
    topIco.setAttribute('href', '#i-stop');
    topBtn.classList.remove('btn-primary');
    topBtn.classList.add('btn-danger');
  } else {
    topTxt.textContent = '立即同步';
    topIco.setAttribute('href', '#i-sync');
    topBtn.classList.add('btn-primary');
    topBtn.classList.remove('btn-danger');
  }
  topBtn.disabled = false;

  const bp = $('btnPause');
  const bpTxt = $('btnPauseText');
  const bpIco = bp.querySelector('use');
  bp.hidden = false;
  bpTxt.textContent = s.paused ? '恢复' : '暂停';
  bpIco.setAttribute('href', s.paused ? '#i-play' : '#i-pause');
  bp.title = s.paused ? '恢复后插盘就会自动同步' : '暂停后插盘不再自动同步';

  // ── 指标 ──
  const disk = d.disk || {};
  $('mDisk').textContent = disk.present
    ? `${disk.letter || ''} ${disk.label || '移动硬盘'}`.trim()
    : '未连接';
  $('mDiskSub').textContent = disk.present
    ? `${disk.freeGB} GB 可用 / 共 ${disk.totalGB} GB`
    : (isBound ? '插上就会自动同步' : '还没绑定');

  const total = Number(disk.totalGB) || 0;
  const free = Number(disk.freeGB) || 0;
  const usedPct = total > 0 ? Math.max(0, Math.min(100, ((total - free) / total) * 100)) : 0;
  $('diskMeterWrap').hidden = !(disk.present && total > 0);
  $('diskMeter').style.width = usedPct.toFixed(1) + '%';

  $('mSize').textContent = s.size && s.size !== '—' ? s.size : '—';
  $('mFilesSub').textContent = s.files && s.files !== '—'
    ? `${s.files.replace(/个$/, '')} 个文件`
    : (s.syncing ? '正在统计…' : '还没比对过');

  const at = s.lastSyncAt ? new Date(s.lastSyncAt) : null;
  $('mLast').textContent = at && !isNaN(at) ? hhmm(at.toISOString()) : (s.lastSync || '—');
  $('mLastSub').textContent = at && !isNaN(at)
    ? agoText(at.getTime())
    : (s.lastSync && s.lastSync !== '—' && s.lastSync !== '还没同步过' ? '上一次运行' : '还没同步过');

  // 没绑定时给一条引导，别让页面空着
  $('bindCta').hidden = isBound;

  // ── 任务摘要（多任务 / 多目的地） ──
  renderTaskRows(d);

  // ── 侧栏与状态栏 ──
  const ledS = !srv.watchAlive ? 'err'
    : s.syncing ? 'work'
    : s.connected ? 'ok'
    : 'warn';
  $('sideLed').dataset.s = ledS;
  $('sbLed').dataset.s = ledS;

  let sideT = '待命', sideS = '';
  if (!srv.watchAlive) { sideT = '监听未运行'; sideS = '不会自动同步'; }
  else if (s.paused)   { sideT = '已暂停';     sideS = '插盘不自动同步'; }
  else if (s.syncing)  { sideT = '正在同步';   sideS = pct + '% · 别拔盘'; }
  else if (!isBound)   { sideT = '未绑定';     sideS = '到硬盘页选一块'; }
  else if (s.connected) { sideT = '已连接';    sideS = disk.present ? `${disk.letter}: 就绪` : '硬盘在线'; }
  else                 { sideT = '等待硬盘';   sideS = '插上后自动开始'; }
  $('sideStateT').textContent = sideT;
  $('sideStateS').textContent = sideS;

  $('sbText').textContent = s.footer || (srv.watchAlive ? '监听中' : '监听未运行');
  $('sbPort').textContent = '127.0.0.1:' + (srv.port || '—');

  // ── 绑定卡 ──
  $('bindName').textContent = isBound ? (d.bind.name || '已绑定') : '尚未绑定';
  $('bindMeta').textContent = isBound
    ? (d.bind.serial ? '序列号 ' + d.bind.serial : '按硬件序列号识别') +
      (d.bind.boundAt ? ' · ' + d.bind.boundAt : '')
    : '插上硬盘后，在下面选一块';
  $('bindLed').dataset.s = disk.present ? 'ok' : (isBound ? 'warn' : '');

  // ── 同步范围 ──
  const cfg = d.config || {};
  $('kvSource').textContent = cfg.sourcePath || '—';
  $('kvTarget').textContent = disk.present && disk.folder
    ? disk.folder
    : `硬盘\\${cfg.targetFolderName || ''}`;

  renderIssues(s, srv, mode);
  renderActivity(s);
}

function renderIssues(s, srv, mode) {
  const card = $('issueCard');
  const list = Array.isArray(s.issues) ? s.issues.slice() : [];

  if (!srv.watchAlive) {
    list.unshift({
      level: 'Error',
      reason: '监听进程没在运行',
      target: '同步不会自动触发',
      advice: '点右上角「立即同步」会把它拉起来，或到设置页点「重启监听」',
    });
  }

  if (list.length === 0) {
    card.hidden = true;
    state.lastIssueKey = '';
    return;
  }
  card.hidden = false;

  // 整张卡的色调跟着主状态走：只有真正的失败才铺红，
  // 「部分完成」用琥珀，免得一小撮失败把整页染红
  const hasErr = list.some(x => x.level === 'Error');
  card.dataset.level = (mode === 'err' || (mode === 'idle' && hasErr)) ? 'err' : 'warn';

  const reasons = [...new Set(list.map(x => x.reason))];
  $('issueTitle').textContent = reasons.length === 1
    ? reasons[0]
    : `${reasons.length} 类问题`;
  $('issueTag').textContent = `${list.length} 条 · ` + (hasErr ? '需要处理' : '不影响结果');

  // 行：内容没变就不重建，避免每 400ms 闪一次
  const key = list.slice(0, 6).map(x => x.level + x.reason + x.target).join('|');
  if (key !== state.lastIssueKey) {
    state.lastIssueKey = key;
    const ul = $('issueList');
    ul.innerHTML = '';
    const shown = Math.min(list.length, 6);
    let prevReason = null;
    for (let i = 0; i < shown; i++) {
      const it = list[i];
      const li = document.createElement('li');
      li.className = 'issue-row';
      li.dataset.l = it.level || 'Warn';
      // 连续几行同一个原因，只在第一行标出来
      const showReason = it.reason !== prevReason;
      prevReason = it.reason;
      li.innerHTML =
        `<span class="issue-bar"></span>` +
        `<span class="issue-reason">${showReason ? escapeHtml(it.reason) : ''}</span>` +
        `<span class="issue-target" title="${escapeHtml(it.target)}">${escapeHtml(it.target)}</span>`;
      ul.appendChild(li);
    }
    if (list.length > shown) {
      const more = document.createElement('div');
      more.className = 'issue-more';
      more.textContent = `另有 ${list.length - shown} 条，见日志`;
      ul.appendChild(more);
    }
  }

  const adv = (list.find(x => x.advice) || {}).advice || '';
  $('issueAdvice').hidden = !adv;
  $('issueAdvice').textContent = adv;
}

function renderActivity(s) {
  const arr = Array.isArray(s.activity) ? s.activity : [];
  const key = arr.length + '|' + (arr.length ? arr[arr.length - 1].t + arr[arr.length - 1].msg : '');
  if (key === state.lastActKey) return;
  state.lastActKey = key;

  const ul = $('activityList');
  if (arr.length === 0) {
    ul.innerHTML = '<li class="is-empty">暂无记录</li>';
    return;
  }
  ul.innerHTML = arr.slice(-14).reverse().map(a =>
    `<li data-l="${escapeHtml(a.level)}"><i class="tl-dot"></i>` +
    `<span class="tl-time">${escapeHtml(String(a.t || '').slice(0, 5))}</span>` +
    `<span class="tl-msg">${escapeHtml(a.msg)}</span></li>`
  ).join('');
}

/* ─────────────── 版本历史（双向同步删除保护） ─────────────── */
let histOpenSnap = null;

async function loadHistory() {
  const card = $('histCard');
  const list = $('histList');
  try {
    const r = await apiGet('/api/history');
    if (!r.ok) { card.hidden = true; return; }
    card.hidden = false;
    if (histOpenSnap) { renderHistFiles(histOpenSnap); return; }   // 正在看某个快照就不打断
    $('histFiles').hidden = true;
    list.hidden = false;
    const snaps = r.snaps || [];
    if (!r.present || snaps.length === 0) {
      list.innerHTML = '<div class="empty">还没有快照。双向同步删除/覆盖文件时会自动留版本。</div>';
      return;
    }
    list.innerHTML = snaps.map(s => {
      const dt = `${s.name.slice(0, 4)}-${s.name.slice(4, 6)}-${s.name.slice(6, 8)} ${s.name.slice(9, 11)}:${s.name.slice(11, 13)}:${s.name.slice(13, 15)}`;
      return `<div class="hist-row" data-snap="${s.name}">
        <span class="hist-name">${escapeHtml(dt)}</span>
        <span class="hist-meta">${s.files} 个文件 · ${fmtBytes(s.bytes)}</span>
        <button class="btn btn-ghost btn-sm">查看</button>
      </div>`;
    }).join('');
  } catch (e) {
    card.hidden = true;
  }
}

async function renderHistFiles(snap) {
  histOpenSnap = snap;
  const listEl = $('histList');
  const filesEl = $('histFiles');
  listEl.hidden = true;
  filesEl.hidden = false;
  $('histSnapName').textContent = snap;
  const box = $('histFileList');
  box.innerHTML = '<div class="empty">正在读取…</div>';
  try {
    const r = await apiGet('/api/history/files?snap=' + encodeURIComponent(snap));
    if (!r.ok) { box.innerHTML = `<div class="empty">${escapeHtml(r.message || '读取失败')}</div>`; return; }
    const files = r.files || [];
    if (files.length === 0) { box.innerHTML = '<div class="empty">这个快照是空的</div>'; return; }
    const more = r.total > files.length ? `<div class="empty">… 另有 ${r.total - files.length} 个文件未列出</div>` : '';
    box.innerHTML = files.map(f =>
      `<div class="hist-row is-file" data-rel="${escapeHtml(f.rel)}">
        <span class="hist-name" title="${escapeHtml(f.rel)}">${escapeHtml(f.rel)}</span>
        <span class="hist-meta">${fmtBytes(f.size)}</span>
        <button class="btn btn-ghost btn-sm">恢复</button>
      </div>`).join('') + more;
  } catch (e) {
    box.innerHTML = '<div class="empty">读取失败：' + escapeHtml(e.message) + '</div>';
  }
}

async function restoreHistFile(snap, rel) {
  try {
    const r = await apiPost('/api/history/restore', { snap, rel });
    toast(r.ok ? (r.message || '已恢复') : (r.message || '恢复失败'), r.ok ? 'ok' : 'err', 4200);
    if (r.ok) renderHistFiles(snap);
  } catch (e) { toast('请求失败：' + e.message, 'err'); }
}

/* ─────────────── 硬盘页 ─────────────── */
async function loadDisks() {
  const box = $('diskList');
  box.innerHTML = '<div class="empty">正在扫描…</div>';
  if (!state.data) { try { await tick(); } catch (e) { } }
  try {
    const r = await apiGet('/api/disks');
    state.disksLoaded = true;
    const disks = r.disks || [];
    const boundName = (state.data && state.data.bind && state.data.bind.name) || '';
    $('diskHint').textContent = disks.length ? `${disks.length} 块` : '没有可用磁盘';

    if (disks.length === 0) {
      box.innerHTML = '<div class="empty">没有找到可绑定的磁盘。移动硬盘插好了吗？</div>';
      return;
    }
    box.innerHTML = disks.map(d => {
      const vols = (d.volumes || []);
      const totGB = vols.reduce((a, v) => a + (Number(v.sizeGB) || 0), 0);
      const freGB = vols.reduce((a, v) => a + (Number(v.freeGB) || 0), 0);
      const usedPct = totGB > 0 ? Math.max(0, Math.min(100, ((totGB - freGB) / totGB) * 100)) : 0;
      const volTxt = vols.map(v => `${v.letter}:${v.label ? ' ' + v.label : ''}`).join('　') || '无盘符';
      const isBound = boundName && boundName.indexOf(d.model) === 0;
      return `<div class="disk-item${isBound ? ' is-bound' : ''}">
        <span class="disk-ico"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><use href="#i-disk"/></svg></span>
        <div class="disk-main">
          <span class="disk-name">${escapeHtml(d.model)}${isBound ? ' · 已绑定' : ''}</span>
          <span class="disk-meta">
            <span>${escapeHtml(volTxt)}</span>
            <span>${d.sizeGB} GB</span>
            <span>${escapeHtml(d.busType || '')}</span>
            <span>序列号 ${escapeHtml(d.serial || '读不到')}</span>
          </span>
          <div class="meter"><i style="width:${usedPct.toFixed(1)}%"></i></div>
        </div>
        <button class="btn ${isBound ? 'btn-ghost' : 'btn-primary'} btn-sm" data-bind="${d.number}">
          ${isBound ? '重新绑定' : '绑定'}
        </button>
      </div>`;
    }).join('');
  } catch (e) {
    box.innerHTML = '<div class="empty">扫描失败：' + escapeHtml(e.message) + '</div>';
  }
}

async function bindDisk(number) {
  const ok = confirm('把「磁盘 ' + number + '」绑定为同步目标？\n\n之后只有这块盘会触发自动同步，其它盘一律不动。');
  if (!ok) return;
  try {
    const r = await apiPost('/api/bind', { diskNumber: Number(number) });
    if (r.ok) {
      toast(r.message || '已绑定', 'ok', 4000);
      state.disksLoaded = false;
      setTimeout(loadDisks, 400);
      setTimeout(tick, 200);
    } else {
      toast(r.message || '绑定失败', 'err', 5000);
    }
  } catch (e) {
    toast('绑定请求失败：' + e.message, 'err');
  }
}

/* ─────────────── 日志页 ─────────────── */
async function loadLogs() {
  const ul = $('logList');
  ul.innerHTML = '<li class="empty">正在读取…</li>';
  try {
    const r = await apiGet('/api/logs');
    state.logsLoaded = true;
    const files = r.files || [];
    if (files.length === 0) {
      ul.innerHTML = '<li class="empty">还没有日志</li>';
      return;
    }
    ul.innerHTML = files.map(f =>
      `<li data-log="${escapeHtml(f.name)}">
        <span class="log-name">${escapeHtml(f.name)}</span>
        <span class="log-sub">${escapeHtml(f.mtime)} · ${fmtBytes(f.size)}</span>
      </li>`
    ).join('');
    // 不用让用户先点一下 —— 直接打开最新那份
    if (!state.currentLog) openLog(files[0].name);
  } catch (e) {
    ul.innerHTML = '<li class="empty">读取失败：' + escapeHtml(e.message) + '</li>';
  }
}

async function openLog(name) {
  state.currentLog = name;
  $$('#logList li').forEach(li => li.classList.toggle('is-sel', li.dataset.log === name));
  $('logTitle').textContent = name;
  $('logBody').textContent = '正在读取…';
  try {
    const r = await apiGet('/api/log?name=' + encodeURIComponent(name) + '&tail=600');
    if (!r.ok) { $('logBody').textContent = r.message || '读取失败'; return; }
    $('logMeta').textContent = `${r.mtime} · ${fmtBytes(r.size)}`;
    const body = $('logBody');
    // 按级别给行上色，扫一眼就知道哪几行出了问题
    const text = r.text || '(空)';
    body.innerHTML = text.split('\n').map(line => {
      let cls = '';
      if (line.indexOf('[ERROR]') >= 0) cls = 'is-err';
      else if (line.indexOf('[WARN]') >= 0) cls = 'is-warn';
      else if (line.indexOf('[OK]') >= 0) cls = 'is-ok';
      return cls ? `<span class="${cls}">${escapeHtml(line)}</span>` : escapeHtml(line);
    }).join('\n');
    body.scrollTop = body.scrollHeight;
  } catch (e) {
    $('logBody').textContent = '读取失败：' + e.message;
  }
}

/* ─────────────── 设置页 ─────────────── */
function setBarModeUI(v) {
  const box = $('setBarMode');
  if (!box) return;
  box.dataset.value = v;
  Array.from(box.querySelectorAll('button')).forEach(b => b.setAttribute('aria-pressed', String(b.dataset.v === v)));
  box.setAttribute('aria-disabled', String(!$('setShowWindow').checked));
}

/* ─────────────── 任务编辑器（多任务 / 多目的地） ─────────────── */
let editorDisks = null;

async function fetchDisks(force) {
  if (editorDisks && !force) return editorDisks;
  try {
    const r = await fetch('/api/disks', { headers: { 'X-DiskSync': '1' } });
    const j = await r.json();
    if (j.ok) editorDisks = j.disks || [];
  } catch (e) { editorDisks = editorDisks || []; }
  return editorDisks;
}

function destText(d) {
  if (d.kind === 'folder') return d.path || d.label || '';
  return (d.label || '移动硬盘') + (d.sub ? ' \\ ' + d.sub : '');
}

function destDataset(d) {
  return `data-kind="${d.kind}" data-label="${escapeHtml(d.label || '')}" data-sub="${escapeHtml(d.sub || '')}" data-path="${escapeHtml(d.path || '')}" data-serials='${d.serials ? escapeHtml(JSON.stringify(d.serials)) : ''}'`;
}

function renderTasksEditor(tasks) {
  const box = $('taskList');
  if (!box) return;
  box.innerHTML = '';
  if (!tasks || tasks.length === 0) {
    box.innerHTML = '<div class="empty">还没有任务：点下面「添加任务」，选一个源目录和目的地</div>';
    return;
  }
  tasks.forEach((t, ti) => {
    const el = document.createElement('div');
    el.className = 'task-box';
    el.dataset.ti = ti;
    const dests = (t.dests || []).map((d, di) => `
      <div class="dest-row" ${destDataset(d)} data-di="${di}">
        <span class="dest-ico"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><use href="#${d.kind === 'folder' ? 'i-data' : 'i-disk'}"/></svg></span>
        <div class="dest-txt">
          <b>${escapeHtml(destText(d))}</b>
          <span>${d.kind === 'disk' ? (d.online ? '移动硬盘 · <i class="st-ok">在线</i>' : '移动硬盘 · <i class="st-off">未插入</i>') : '本地文件夹'}${d.lastSyncAt ? ' · 上次 ' + escapeHtml(d.lastSyncAt) : ''}</span>
        </div>
        <button type="button" class="dest-del" title="移除">×</button>
      </div>`).join('') || '<div class="empty-sm">还没有目的地，在下面添加</div>';
    el.innerHTML = `
      <div class="task-head">
        <input type="text" class="task-name" value="${escapeHtml(t.name || ('任务 ' + (ti + 1)))}" spellcheck="false">
        <button type="button" class="btn btn-ghost btn-sm task-del">删除任务</button>
      </div>
      <div class="task-grid">
        <div class="task-col task-src">
          <span class="f-label">源目录（要备份的文件夹）</span>
          <input type="text" class="task-src-input" value="${escapeHtml(t.source || '')}" spellcheck="false" placeholder="例如 E:\\资料">
          <span class="f-help">整个文件夹连子目录一起备份；排除规则在下方设置</span>
        </div>
        <div class="task-col task-dest">
          <span class="f-label">备份目的地（可多个：硬盘插入即备，文件夹定时即备）</span>
          <div class="dest-list">${dests}</div>
          <div class="dest-add">
            <select class="dest-disk-pick"><option value="">＋ 选择硬盘…</option></select>
            <button type="button" class="btn btn-ghost btn-sm dest-add-folder">＋ 本地文件夹</button>
          </div>
          <div class="dest-folder-row" hidden>
            <input type="text" class="dest-folder-input" placeholder="D:\\备份\\工作资料" spellcheck="false">
            <button type="button" class="btn btn-primary btn-sm dest-folder-ok">添加</button>
          </div>
        </div>
      </div>`;
    box.appendChild(el);
    fetchDisks().then(disks => {
      const sel = el.querySelector('.dest-disk-pick');
      if (!sel) return;
      (disks || []).forEach(dk => {
        const v = dk.volumes && dk.volumes[0];
        if (!v) return;
        const opt = document.createElement('option');
        opt.value = JSON.stringify({ model: dk.model, serial: dk.serial, vol: v.volserial || '', label: v.label || '', letter: v.letter || '' });
        opt.textContent = dk.model + ' (' + v.letter + ':) ' + dk.sizeGB + ' GB';
        sel.appendChild(opt);
      });
    });
  });
}

const SAVE_IDLE_HINT = '尚未改动 · 保存范围：任务 / 执行 / 进度条 / 安全闸 / 排除规则';
function setSaveState(dirty, hint) {
  state.settingsDirty = dirty;
  const btnSave = $('btnSaveCfg'), btnReset = $('btnResetCfg'), h = $('saveHint');
  if (btnSave) btnSave.disabled = !dirty;
  if (btnReset) btnReset.disabled = !dirty;
  if (h) h.textContent = hint || (dirty ? '有未保存的改动，点右侧「保存设置」生效' : SAVE_IDLE_HINT);
}
function markDirty() {
  setSaveState(true);
}

function addDestRow(box, d) {
  const list = box.querySelector('.dest-list');
  const empty = list.querySelector('.empty-sm');
  if (empty) empty.remove();
  const div = document.createElement('div');
  div.className = 'dest-row';
  div.setAttribute('data-kind', d.kind);
  div.setAttribute('data-label', d.label || '');
  div.setAttribute('data-sub', d.sub || '');
  div.setAttribute('data-path', d.path || '');
  div.setAttribute('data-serials', d.serials ? JSON.stringify(d.serials) : '');
  div.innerHTML = `
    <span class="dest-ico"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><use href="#${d.kind === 'folder' ? 'i-data' : 'i-disk'}"/></svg></span>
    <div class="dest-txt">
      <b>${escapeHtml(destText(d))}</b>
      <span>${d.kind === 'disk' ? '移动硬盘' : '本地文件夹'}</span>
    </div>
    <button type="button" class="dest-del" title="移除">×</button>`;
  list.appendChild(div);
}

function wireTaskEditor() {
  const list = $('taskList');
  if (!list) return;
  list.addEventListener('click', async (e) => {
    const box = e.target.closest('.task-box');
    if (!box) return;
    if (e.target.closest('.task-del')) {
      if (confirm('删除整个任务（源目录和它的所有目的地）？')) { box.remove(); markDirty(); }
      return;
    }
    if (e.target.closest('.dest-del')) {
      e.target.closest('.dest-row').remove();
      markDirty();
      return;
    }
    if (e.target.closest('.dest-add-folder')) {
      const row = box.querySelector('.dest-folder-row');
      row.hidden = !row.hidden;
      if (!row.hidden) row.querySelector('input').focus();
      return;
    }
    if (e.target.closest('.dest-folder-ok')) {
      const p = box.querySelector('.dest-folder-input').value.trim();
      if (!p) { toast('先填一个文件夹路径', 'warn'); return; }
      if (!/^[A-Za-z]:[/\\].+/.test(p)) { toast('要绝对路径，比如 D:\\备份\\资料', 'warn'); return; }
      addDestRow(box, { kind: 'folder', path: p });
      box.querySelector('.dest-folder-row').hidden = true;
      box.querySelector('.dest-folder-input').value = '';
      markDirty();
      return;
    }
  });
  list.addEventListener('change', (e) => {
    const box = e.target.closest('.task-box');
    if (!box) return;
    if (e.target.classList.contains('dest-disk-pick') && e.target.value) {
      let info;
      try { info = JSON.parse(e.target.value); } catch (err) { return; }
      addDestRow(box, {
        kind: 'disk',
        label: (info.model || '移动硬盘') + (info.letter ? ' (' + info.letter + ':)' : ''),
        sub: 'FileSync备份',
        serials: { disk: info.serial || '', phys: '', volume: info.vol || '' },
      });
      e.target.value = '';
      markDirty();
    }
  });
  list.addEventListener('input', (e) => {
    if (e.target.matches('.task-name, .task-src-input')) markDirty();
  });
}

function collectTasks() {
  const out = [];
  document.querySelectorAll('#taskList .task-box').forEach(box => {
    const dests = [];
    box.querySelectorAll('.dest-row').forEach(row => {
      const d = {
        kind: row.getAttribute('data-kind'),
        label: row.getAttribute('data-label') || '',
        sub: row.getAttribute('data-sub') || '',
        path: row.getAttribute('data-path') || '',
        serials: null,
      };
      const raw = row.getAttribute('data-serials');
      if (raw) { try { d.serials = JSON.parse(raw); } catch (e) { } }
      dests.push(d);
    });
    out.push({
      name: box.querySelector('.task-name').value.trim(),
      source: box.querySelector('.task-src-input').value.trim(),
      dests,
    });
  });
  return out;
}

function setSyncModeUI(v) {
  const box = $('setSyncMode');
  if (!box) return;
  box.dataset.value = v;
  Array.from(box.querySelectorAll('button')).forEach(b => b.setAttribute('aria-pressed', String(b.dataset.v === v)));
}

function fillSettings(force) {
  const d = state.data;
  if (!d || !d.config) return;
  if (state.settingsDirty && !force) return;

  const c = d.config;
  renderTasksEditor(c.tasks || []);
  setSyncModeUI(c.syncMode === 'twoway' ? 'twoway' : 'mirror');
  $('setThreads').value = c.threads || 8;
  $('setDebounce').value = c.debounce == null ? 60 : c.debounce;
  $('setFolderSync').value = c.folderSyncMinutes == null ? 0 : c.folderSyncMinutes;
  $('setShowWindow').checked = c.showWindow !== false;
  setBarModeUI(c.miniBarMode || 'auto');
  $('setGuard').checked = c.guardEnabled !== false;
  $('setGuardPct').value = c.guardMaxDelete || 20;
  $('setExcludeDirs').value = (c.excludeDirs || []).join('\n');
  $('setExcludeFiles').value = (c.excludeFiles || []).join('\n');

  const srv = d.server || {};
  $('kvPort').textContent = 'http://127.0.0.1:' + (srv.port || '—') + '/';
  $('kvWatch').textContent = srv.watchAlive
    ? `运行中${srv.watchRestarts ? '（重启 ' + srv.watchRestarts + ' 次）' : ''}`
    : '未运行';
  $('setAutostart').checked = !!srv.autostart;

  state.settingsFilled = true;
  setSaveState(false);
}

async function saveSettings() {
  const body = {
    tasks: collectTasks(),
    syncMode: $('setSyncMode').dataset.value || 'mirror',
    threads: Number($('setThreads').value) || 8,
    debounce: Number($('setDebounce').value) || 0,
    folderSyncMinutes: Number($('setFolderSync').value) || 0,
    showWindow: $('setShowWindow').checked,
    miniBarMode: $('setBarMode').dataset.value || 'auto',
    guardEnabled: $('setGuard').checked,
    guardMaxDelete: Number($('setGuardPct').value) || 20,
    excludeDirs: $('setExcludeDirs').value.split('\n').map(x => x.trim()).filter(Boolean),
    excludeFiles: $('setExcludeFiles').value.split('\n').map(x => x.trim()).filter(Boolean),
  };
  const btn = $('btnSaveCfg');
  btn.disabled = true;
  btn.textContent = '保存中…';
  try {
    const r = await apiPost('/api/config', body);
    if (r.ok) {
      toast('设置已保存，下一次同步生效', 'ok');
      await tick();
      fillSettings(true);
      $('saveHint').textContent = '已保存 · ' + clockText(new Date().toISOString()) + ' · 保存范围：任务 / 执行 / 进度条 / 安全闸 / 排除规则';
    } else {
      toast(r.message || '保存失败', 'err', 5000);
    }
  } catch (e) {
    toast('保存失败：' + e.message, 'err');
  } finally {
    btn.textContent = '保存设置';
    btn.disabled = !state.settingsDirty;
  }
}

/* ─────────────── 操作 ─────────────── */
async function doSync() {
  const s = (state.data && state.data.sync) || {};
  const cmd = s.syncing ? 'stop' : 'sync';
  try {
    const r = await apiPost('/api/cmd', { cmd });
    if (!r.ok) { toast('指令没送到：' + (r.message || ''), 'err'); return; }
    toast(cmd === 'stop' ? '已请求停止，正在收尾' : '已请求同步', 'ok', 2200);
    setTimeout(tick, 500);
  } catch (e) {
    toast('请求失败：' + e.message, 'err');
  }
}

async function doPause() {
  const s = (state.data && state.data.sync) || {};
  try {
    await apiPost('/api/cmd', { cmd: s.paused ? 'resume' : 'pause' });
    toast(s.paused ? '已恢复自动同步' : '已暂停自动同步', 'ok', 2200);
    setTimeout(tick, 400);
  } catch (e) { toast('请求失败：' + e.message, 'err'); }
}

async function doOpen(what) {
  try {
    const r = await apiPost('/api/open', { what });
    if (!r.ok) toast(r.message || '打不开', 'warn');
  } catch (e) { toast('请求失败：' + e.message, 'err'); }
}

// 把桌面窗口叫回来（关掉之后想再看一眼）
async function cmdAndToast(cmd, okMsg) {
  try {
    const r = await apiPost('/api/cmd', { cmd });
    toast(r.ok ? okMsg : (r.message || '没成功，监听可能没在跑'), r.ok ? 'ok' : 'warn', 3200);
  } catch (e) { toast('请求失败：' + e.message, 'err'); }
}

/* ─────────────── 轮询 ─────────────── */
function showExitScreen(msg) {
  document.body.innerHTML =
    '<div style="display:grid;place-items:center;height:100vh;font:14.5px var(--font);color:#888;text-align:center;line-height:2">' +
    (msg || 'FileSync 已退出') +
    '<br><span style="font-size:13.5px">可以关掉这个页面了；下次双击 FileSync 图标即可再启动</span></div>';
}

async function tick() {
  try {
    const d = await apiGet('/api/state');
    state.data = d;
    state.failStreak = 0;
    state.lastOkAt = Date.now();

    renderOverview(d);
    // 侧栏副标题跟着同步方向走
    const bm = $('brandMode');
    if (bm && d.config) bm.textContent = d.config.syncMode === 'twoway' ? '双向同步' : '镜像同步';
    const sm = $('scopeMode');
    if (sm && d.config) sm.textContent = d.config.syncMode === 'twoway' ? '双向同步 · 两边互相补齐，删除同步并留版本' : '单向镜像 · 以源端为准';
    if (state.page === 'settings' && !state.settingsFilled) fillSettings(true);

    $('sbTick').textContent = '更新于 ' + clockText(new Date().toISOString());
  } catch (e) {
    state.failStreak++;
    // 服务连续没响应 = 控制台已经退出（比如托盘菜单点的退出）。
    // 别干转"断开重试"，直接翻到已退出页，轮询也停掉。
    if (state.failStreak >= 5) {
      state.dead = true;
      showExitScreen('FileSync 已退出');
      return;
    }
    $('sideLed').dataset.s = 'err';
    $('sbLed').dataset.s = 'err';
    $('sbText').textContent = '与服务断开，正在重试…';
    $('sideStateT').textContent = '断开';
    $('sideStateS').textContent = state.failStreak > 3 ? '服务可能已退出' : '重试中';
  } finally {
    if (state.dead) return;
    const hidden = document.hidden;
    let delay = hidden ? 2000 : 400;
    if (state.failStreak > 0) delay = Math.min(3000, 500 * state.failStreak);
    setTimeout(tick, delay);
  }
}

/* ─────────────── 事件绑定 ─────────────── */
function bindEvents() {
  $$('.nav-item').forEach(b => b.addEventListener('click', () => switchPage(b.dataset.page)));

  $('btnPrimary').addEventListener('click', doSync);
  $('btnPause').addEventListener('click', doPause);
  $('btnGoBind').addEventListener('click', () => switchPage('disk'));

  $('btnRefreshDisks').addEventListener('click', () => { state.disksLoaded = false; loadDisks(); });

  // 版本历史：点快照 → 文件列表；点文件「恢复」→ 恢复到两边
  $('histList').addEventListener('click', (e) => {
    const row = e.target.closest('[data-snap]');
    if (row) renderHistFiles(row.dataset.snap);
  });
  $('histBack').addEventListener('click', () => {
    histOpenSnap = null;
    $('histFiles').hidden = true;
    $('histList').hidden = false;
    loadHistory();
  });
  $('histFileList').addEventListener('click', (e) => {
    const btn = e.target.closest('button');
    if (!btn) return;
    const row = e.target.closest('[data-rel]');
    if (row) {
      const rel = row.dataset.rel;
      if (confirm(`把「${rel}」恢复到本地和硬盘？\n会覆盖这两处现在的同名文件。`)) restoreHistFile(histOpenSnap, rel);
    }
  });
  $('btnReloadLogs').addEventListener('click', () => { state.logsLoaded = false; loadLogs(); });
  $('btnSaveCfg').addEventListener('click', saveSettings);
  $('btnResetCfg').addEventListener('click', () => { state.settingsDirty = false; fillSettings(true); });

  // 迷你条出现策略 + 立刻叫出来
  $('setBarMode').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-v]');
    if (!b) return;
    setBarModeUI(b.dataset.v);
    markDirty();
  });

  // 同步方向（镜像 / 双向）—— 跟着保存按钮一起提交
  $('setSyncMode').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-v]');
    if (!b) return;
    setSyncModeUI(b.dataset.v);
    markDirty();
  });

  // 开机自启：开关即生效，不走保存按钮
  $('setAutostart').addEventListener('change', async () => {
    const want = $('setAutostart').checked;
    try {
      const r = await apiPost('/api/autostart', { enabled: want });
      if (r.ok) {
        $('setAutostart').checked = r.enabled;
        toast(r.message || (want ? '已开启开机自启' : '已关闭开机自启'), 'ok', 3200);
      } else {
        $('setAutostart').checked = !want;
        toast(r.message || '设置失败', 'err', 5000);
      }
    } catch (e) {
      $('setAutostart').checked = !want;
      toast('请求失败：' + e.message, 'err');
    }
  });
  $('setShowWindow').addEventListener('change', () => {
    setBarModeUI($('setBarMode').dataset.value || 'auto');
    markDirty();
  });
  $('btnShowBar').addEventListener('click', () => cmdAndToast('showbar', '进度条已叫出来，看右下角'));
  $('btnShowConsole').addEventListener('click', () => cmdAndToast('showconsole', '桌面控制台已打开'));

  $('btnRestartWatch').addEventListener('click', async () => {
    try {
      const r = await apiPost('/api/watch/restart', {});
      toast(r.alive ? '监听进程已重启' : '重启后没起来，看看日志', r.alive ? 'ok' : 'warn', 4000);
      setTimeout(tick, 800);
    } catch (e) { toast('请求失败：' + e.message, 'err'); }
  });

  $('btnStopAll').addEventListener('click', async () => {
    if (!confirm('退出后自动同步和网页都会停止。\n下次要恢复，双击 FileSync 图标即可。\n\n确定退出？')) return;
    try {
      state.dead = true;
      await apiPost('/api/cmd', { cmd: 'quit' });
      showExitScreen('FileSync 已退出');
    } catch (e) { state.dead = false; toast('请求失败：' + e.message, 'err'); }
  });

  // 事件委托：磁盘绑定按钮、日志项、打开文件夹
  document.addEventListener('click', (ev) => {
    const b = ev.target.closest('[data-bind]');
    if (b) { bindDisk(b.dataset.bind); return; }

    const l = ev.target.closest('[data-log]');
    if (l) { openLog(l.dataset.log); return; }

    const o = ev.target.closest('[data-open]');
    if (o) { doOpen(o.dataset.open); return; }
  });

  // 设置页：动过就记脏
  ['setThreads','setDebounce','setGuard','setGuardPct','setExcludeDirs','setExcludeFiles','setFolderSync']
    .forEach(id => {
      const el = $(id);
      if (el) el.addEventListener('input', markDirty);
    });

  // 任务编辑器
  wireTaskEditor();
  $('btnAddTask').addEventListener('click', () => {
    const box = $('taskList');
    const empty = box.querySelector('.empty');
    if (empty) empty.remove();
    // 造一个空白任务块
    const el = document.createElement('div');
    el.className = 'task-box';
    el.innerHTML = `
      <div class="task-head">
        <input type="text" class="task-name" value="新任务" spellcheck="false">
        <button type="button" class="btn btn-ghost btn-sm task-del">删除任务</button>
      </div>
      <div class="task-grid">
        <div class="task-col task-src">
          <span class="f-label">源目录（要备份的文件夹）</span>
          <input type="text" class="task-src-input" value="" spellcheck="false" placeholder="例如 E:\\资料">
          <span class="f-help">整个文件夹连子目录一起备份；排除规则在下方设置</span>
        </div>
        <div class="task-col task-dest">
          <span class="f-label">备份目的地（可多个：硬盘插入即备，文件夹定时即备）</span>
          <div class="dest-list"><div class="empty-sm">还没有目的地，在下面添加</div></div>
          <div class="dest-add">
            <select class="dest-disk-pick"><option value="">＋ 选择硬盘…</option></select>
            <button type="button" class="btn btn-ghost btn-sm dest-add-folder">＋ 本地文件夹</button>
          </div>
          <div class="dest-folder-row" hidden>
            <input type="text" class="dest-folder-input" placeholder="D:\\备份\\工作资料" spellcheck="false">
            <button type="button" class="btn btn-primary btn-sm dest-folder-ok">添加</button>
          </div>
        </div>
      </div>`;
    box.appendChild(el);
    fetchDisks().then(disks => {
      const sel = el.querySelector('.dest-disk-pick');
      (disks || []).forEach(dk => {
        const v = dk.volumes && dk.volumes[0];
        if (!v) return;
        const opt = document.createElement('option');
        opt.value = JSON.stringify({ model: dk.model, serial: dk.serial, vol: v.volserial || '', label: v.label || '', letter: v.letter || '' });
        opt.textContent = dk.model + ' (' + v.letter + ':) ' + dk.sizeGB + ' GB';
        sel.appendChild(opt);
      });
    });
    markDirty();
    el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  });
}

/* ─────────────── 初次使用引导 ─────────────── */
function maybeShowGuide() {
  // 只有第一次打开（localStorage 没记过）才弹；设置页里有「查看引导」可随时再看
  if (localStorage.getItem('ds_onboarded')) return;
  setTimeout(() => { $('guideOverlay').hidden = false; }, 350);
}
function closeGuide() {
  if ($('guideDontShow').checked) {
    try { localStorage.setItem('ds_onboarded', '1'); } catch (e) { }
  }
  $('guideOverlay').hidden = true;
}

/* ─────────────── 启动 ─────────────── */
bindEvents();
switchPage((location.hash || '').replace('#', '') || 'overview');
tick();
maybeShowGuide();

$('btnGuideStart').addEventListener('click', closeGuide);
$('guideOverlay').addEventListener('click', (e) => {
  if (e.target === $('guideOverlay')) closeGuide();   // 点空白处也算看完
});
$('btnShowGuide').addEventListener('click', () => {
  $('guideDontShow').checked = true;
  $('guideOverlay').hidden = false;
});

window.addEventListener('hashchange', () => {
  switchPage((location.hash || '').replace('#', '') || 'overview');
});

document.addEventListener('visibilitychange', () => {
  if (!document.hidden) tick();
});
