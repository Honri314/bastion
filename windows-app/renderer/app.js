/* Proxmox Manager (Windows / Electron) 렌더러 */

// ---------- 공용 상태 ----------
const state = {
  resources: [],
  clusterName: '',
  selection: null,   // {kind: 'overview'|'node'|'guest'|'storage'|'tasks'|'api'|'shell', ...}
  filter: '',
  autoTimer: null,
  currentTermId: null,
};

const $ = (s, r = document) => r.querySelector(s);
const el = (tag, cls, html) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html != null) e.innerHTML = html;
  return e;
};

function fmtBytes(v) {
  if (!v || v < 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, n = v;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n >= 100 || i === 0 ? 0 : 1)} ${units[i]}`;
}
function fmtUptime(s) {
  if (!s) return '-';
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
  return d > 0 ? `${d}일 ${h}시간` : h > 0 ? `${h}시간 ${m}분` : `${m}분`;
}
function fmtDate(unix) {
  if (!unix) return '-';
  return new Date(unix * 1000).toLocaleString('ko-KR', { dateStyle: 'medium', timeStyle: 'short' });
}
function pretty(any) {
  try {
    return JSON.stringify(any, (k, v) => v, 1).replace(/^"|"$/g, '') || '-';
  } catch { return String(any); }
}

async function api(method, path, form) {
  const res = await window.pve.api(method, path, form);
  if (!res.ok) throw new Error(res.error);
  return res.data;
}

// ---------- 로그인 ----------
function currentProfileId() {
  const host = $('#l-host').value.trim();
  const port = parseInt($('#l-port').value, 10) || 8006;
  const user = $('#l-user').value.trim();
  return `${host}:${port}:${user}@${$('#l-realm').value}`;
}

$('#l-btn').addEventListener('click', async () => {
  const host = $('#l-host').value.trim();
  const port = parseInt($('#l-port').value, 10) || 8006;
  const user = $('#l-user').value.trim();
  const realm = $('#l-realm').value;
  const password = $('#l-pass').value;
  const otp = $('#l-otp').value.trim();
  if (!host || !password) { $('#login-err').textContent = '서버 주소와 비밀번호를 입력하세요.'; return; }
  $('#l-btn').disabled = true;
  $('#login-err').textContent = '';
  localStorage.setItem('pve.host', host);
  localStorage.setItem('pve.port', port);
  localStorage.setItem('pve.user', user);
  localStorage.setItem('pve.realm', realm);
  const res = await window.pve.login({ host, port, user, realm, password, otp });
  $('#l-btn').disabled = false;
  if (res.ok) {
    // 로그인 성공 → 프로필 저장 (비밀번호는 Main 프로세스에서 OS 보안 스토리지로 암호화)
    try {
      await window.pve.profileSave(
        { id: currentProfileId(), label: host, host, port, user, realm },
        $('#l-save').checked ? password : '',
        $('#l-save').checked);
    } catch { /* 저장 실패는 로그인에 영향 없음 */ }
    startApp();
  }
  else $('#login-err').textContent = res.error;
});

// 저장 프로필 목록 로딩/선택/삭제
async function loadProfileList() {
  let profiles = [];
  try { profiles = await window.pve.profiles() || []; } catch {}
  const sel = $('#l-profile');
  sel.innerHTML = '<option value="">새 서버 입력</option>';
  for (const p of profiles) {
    const o = document.createElement('option');
    o.value = p.id; o.textContent = `${p.label} (${p.user}@${p.realm} · ${p.host}:${p.port})`;
    o.dataset.profile = JSON.stringify(p);
    sel.appendChild(o);
  }
  // 마지막 연결과 일치하는 프로필이 있으면 자동 선택
  const last = profiles.find((p) => p.host === ($('#l-host').value.trim() || localStorage.getItem('pve.host')));
  if (last) {
    sel.value = last.id;
    applyProfile(last, sel);
  }
}

function applyProfile(p) {
  $('#l-host').value = p.host;
  $('#l-port').value = p.port;
  $('#l-user').value = p.user;
  if (p.realm) $('#l-realm').value = p.realm;
  $('#l-save').checked = !!p.savePassword;
  $('#l-pass').value = p.savePassword ? (p.password || '') : '';
  $('#l-del').style.display = '';
}

$('#l-profile').addEventListener('change', async () => {
  const v = $('#l-profile').value;
  $('#l-del').style.display = v ? '' : 'none';
  if (!v) return;
  const opt = $('#l-profile').selectedOptions[0];
  try { applyProfile(JSON.parse(opt.dataset.profile)); } catch {}
});

$('#l-del').addEventListener('click', async () => {
  const id = $('#l-profile').value;
  if (!id) return;
  try { await window.pve.profileDelete(id); } catch {}
  $('#l-host').value = ''; $('#l-user').value = 'root'; $('#l-pass').value = '';
  $('#l-del').style.display = 'none';
  await loadProfileList();
});

// 저장된 주소로 필드 채우기 + realm 목록 + 프로필
(async () => {
  $('#l-host').value = localStorage.getItem('pve.host') || '';
  $('#l-port').value = localStorage.getItem('pve.port') || 8006;
  $('#l-user').value = localStorage.getItem('pve.user') || 'root';
  const realm = localStorage.getItem('pve.realm');
  if (realm) $('#l-realm').value = realm;
  await loadProfileList();
  try {
    const d = await window.pve.api('GET', '/api2/json/access/domains');
    if (d.ok) {
      const list = (d.data || []).map((r) => r.realm);
      if (list.length) {
        const sel = $('#l-realm');
        sel.innerHTML = list.map((n) => `<option>${n}</option>`).join('');
        if (realm) sel.value = realm;
      }
    }
  } catch { /* 미로그인 상태에서 실패해도 무시 */ }
})();

// ---------- 앱 시작 ----------
function startApp() {
  $('#login-overlay').style.display = 'none';
  $('#app').style.display = 'flex';
  select('overview');
  refresh();
  clearInterval(state.autoTimer);
  state.autoTimer = setInterval(() => refresh(), 5000);
}

$('#btn-logout').addEventListener('click', () => location.reload());
$('#btn-refresh').addEventListener('click', () => refresh());
$('#search').addEventListener('input', (e) => { state.filter = e.target.value.trim().toLowerCase(); renderSidebar(); });

async function refresh() {
  try {
    const data = await api('GET', '/api2/json/cluster/resources');
    state.resources = data || [];
    try {
      const st = await api('GET', '/api2/json/cluster/status');
      const c = (st || []).find((x) => x.type === 'cluster');
      state.clusterName = c ? c.name : '단일 노드';
    } catch { state.clusterName = ''; }
    $('#cluster-name').textContent = state.clusterName;
    renderSidebar();
    renderDetail(true);
  } catch (e) {
    // 티켓 만료 진행 상태 등
  }
}

// ---------- 사이드바 ----------
// PVE /cluster/resources 의 게스트 type: QEMU→"qemu", LXC→"lxc" (PVE GUI이 "vm"으로 매핑해 보여줄 뿐)
const isVMKind = (t) => t === 'vm' || t === 'qemu';
const isGuestKind = (t) => isVMKind(t) || t === 'lxc';
function select(sel) { state.selection = sel; renderSidebar(); renderDetail(); }

function renderSidebar() {
  const root = $('#sidebar');
  root.innerHTML = '';
  const nodes = state.resources.filter((r) => r.type === 'node');
  const guests = state.resources.filter((r) => isGuestKind(r.type))
    .filter((r) => !state.filter
      || r.name.toLowerCase().includes(state.filter)
      || String(r.vmid).includes(state.filter))
    .sort((a, b) => (a.vmid || 0) - (b.vmid || 0));

  const mkSection = (title) => {
    const s = el('div', 'side-section', title);
    root.appendChild(s);
  };
  const mkItem = (label, dotState, sel, extra) => {
    const item = el('div', 'side-item' + (JSON.stringify(state.selection) === JSON.stringify(sel) ? ' active' : ''));
    if (dotState !== undefined) {
      const d = el('span', `dot ${dotState ? 'on' : 'off'}`);
      item.appendChild(d);
    }
    if (extra) item.appendChild(extra);
    item.appendChild(el('span', '', label));
    item.addEventListener('click', () => select(sel));
    root.appendChild(item);
  };

  mkSection('클러스터');
  mkItem('개요', undefined, { kind: 'overview' });
  mkItem('태스크', undefined, { kind: 'tasks' });
  mkItem('스토리지', undefined, { kind: 'storage' });
  mkItem('API 탐색기', undefined, { kind: 'api' });

  mkSection('노드');
  for (const n of nodes) {
    mkItem(n.name, n.status === 'online', { kind: 'node', node: n.name });
  }

  mkSection('게스트');
  for (const g of guests) {
    const vmid = el('span', 'side-vmid', `${g.vmid}`);
    mkItem(`${g.name}${g.status !== 'running' ? ' (' + g.status + ')' : ''}`, g.status === 'running',
      { kind: 'guest', node: g.node, type: g.type, vmid: g.vmid }, vmid);
  }
}

// ---------- 상세 렌더링 ----------
function renderDetail(quiet) {
  const root = $('#content');
  const sel = state.selection || { kind: 'overview' };
  root.innerHTML = '';
  if (sel.kind === 'overview') renderOverview(root);
  else if (sel.kind === 'node') renderNode(root, sel.node, quiet);
  else if (sel.kind === 'guest') renderGuest(root, sel, quiet);
  else if (sel.kind === 'storage') renderStorage(root);
  else if (sel.kind === 'tasks') renderTasks(root);
  else if (sel.kind === 'api') renderApiExplorer(root);
}

function paneHead(root, title, sub, actions) {
  const head = el('div', 'pane-head');
  const t = el('div');
  t.appendChild(el('h2', '', title));
  if (sub) t.appendChild(el('div', 'sub', sub));
  head.appendChild(t);
  if (actions) for (const a of actions) head.appendChild(a);
  root.appendChild(head);
}

// 모니터링 스파크라인 (canvas)
function sparkline(canvas, values, color = '#f5a623') {
  const ctx = canvas.getContext('2d');
  const w = canvas.width = canvas.offsetWidth * 2;
  const h = canvas.height = 140;
  ctx.clearRect(0, 0, w, h);
  const v = values.filter((x) => x > 0 || x === 0);
  if (v.length < 2) return;
  let max = Math.max(...v, 1);
  let min = Math.min(...v, v[0]);
  if (max - min < 1e-9) min = Math.max(0, max - 1e-9);
  ctx.strokeStyle = color; ctx.lineWidth = 2.5; ctx.beginPath();
  v.forEach((y, i) => {
    const x = (i / (v.length - 1)) * w;
    const yy = h - 10 - ((y - min) / (max - min || 1)) * (h - 25);
    i === 0 ? ctx.moveTo(x, yy) : ctx.lineTo(x, yy);
  });
  ctx.stroke();
}

async function rrddata(path, series, root) {
  try {
    const pts = (await api('GET', `${path}?timeframe=hour`)) || [];
    for (const s of series) {
      const card = el('div', 'chart');
      card.appendChild(el('div', 'label', s.label));
      const c = el('canvas');
      card.appendChild(c);
      root.appendChild(card);
      sparkline(c, pts.map((p) => p[s.key] || 0), s.color);
    }
  } catch (e) {
    root.appendChild(el('div', 'card', `모니터링 데이터 로드 실패: ${e.message}`));
  }
}

// ---------- 개요 ----------
function renderOverview(root) {
  paneHead(root, '개요', '클러스터 전체 현황 (5초 자동 갱신)');
  const body = el('div', 'pane-body');
  root.appendChild(body);

  const cardGrid = el('div', 'grid');
  nodesOf().forEach((n) => {
    const c = el('div', 'card');
    c.appendChild(el('div', '', `<b>${n.name}</b> <span style="color:${n.status === 'online' ? 'var(--green)' : 'var(--red)'}">● ${n.status}</span>`));
    c.appendChild(el('div', 'kv', `<span class="k">CPU</span><span>${Math.round((n.cpu || 0) * 100)}% / ${n.maxcpu || 0}코어</span>`));
    c.appendChild(el('div', 'kv', `<span class="k">메모리</span><span>${fmtBytes(n.mem)} / ${fmtBytes(n.maxmem)}</span>`));
    c.appendChild(el('div', 'kv', `<span class="k">업타임</span><span>${fmtUptime(n.uptime)}</span>`));
    const bar = el('div', 'bar'); const fill = el('div'); fill.style.width = `${Math.min(100, (n.cpu || 0) * 100)}%`;
    bar.appendChild(fill);
    c.appendChild(bar);
    cardGrid.appendChild(c);
  });
  body.appendChild(cardGrid);
}

function nodesOf() { return state.resources.filter((r) => r.type === 'node'); }

// ---------- 게스트 상세 ----------
let guestTab = 'monitor';
const guestTabCache = new Map();

function renderGuest(root, sel, quiet) {
  const res = state.resources.find((r) => r.type === sel.type && r.vmid === sel.vmid);
  const running = res?.status === 'running';
  const apiPath = `/api2/json/nodes/${sel.node}/${sel.type}/${sel.vmid}`;

  const actions = [];
  const menu = el('select', 'field');
  menu.innerHTML = `<option>액션</option><option value="start">시작</option><option value="stop">정지</option>
    <option value="reboot">재시작</option><option value="shutdown">셧다운</option>
    <option value="reset">리셋</option><option value="suspend">일시정지</option><option value="resume">재개</option>`;
  menu.addEventListener('change', () => {
    const act = menu.value;
    menu.value = '액션';
    if (isVMKind(sel.type) ? false : (act === 'reset' || act === 'suspend' || act === 'resume')) return;
    confirmModal(`"${res?.name}" 게스트에 ${act} 작업을 실행합니다.`, async () => {
      try { await api('POST', `${apiPath}/status/${act}`, {}); } catch (e) { alert(e.message); }
      setTimeout(refresh, 1500);
    });
  });
  actions.push(menu);

  const shellBtn = el('button', 'btn primary', '셸');
  shellBtn.addEventListener('click', () => { guestTab = 'shell'; guestTabCache.delete(sel); renderDetail(); });
  actions.push(shellBtn);
  if (isVMKind(sel.type)) {
    const vncBtn = el('button', 'btn', 'VNC 콘솔');
    vncBtn.addEventListener('click', () => window.pve.openVNC(sel.node, sel.vmid));
    actions.push(vncBtn);
  }

  paneHead(root, `${sel.vmid} · ${res?.name || ''}`,
    `${res?.node || sel.node} · ${running ? '실행 중' : '정지'} · 업타임 ${running ? fmtUptime(res.uptime) : '-'} ${
      (res?.tags || '').split(';').filter(Boolean).map((t) => `<span class="tag">${t}</span>`).join('')}`,
    actions);

  const tabs = el('div', 'pane-body', '');
  const tabBar = el('div', '', '');
  ['monitor|모니터링', 'snapshot|스냅샷', 'backup|백업', 'config|설정', 'shell|셸'].forEach((p) => {
    const [id, label] = p.split('|');
    const b = el('button', 'btn' + (guestTab === id ? ' primary' : ''), label);
    b.addEventListener('click', () => { guestTab = id; renderDetail(); });
    tabBar.appendChild(b);
    b.style.marginRight = '6px';
  });
  root.appendChild(tabBar);
  tabBar.style.padding = '10px 18px';

  if (guestTab === 'monitor') {
    const body = el('div', 'pane-body');
    root.appendChild(body);
    const chartArea = el('div', '');
    body.appendChild(chartArea);
    rrddata(`${apiPath}/rrddata`, [
      { key: 'cpu', label: 'CPU 사용률', color: '#f5a623' },
      { key: 'mem', label: '메모리', color: '#7aa2f7' },
      { key: 'netin', label: '네트워크 IN', color: '#46c78f' },
      { key: 'netout', label: '네트워크 OUT', color: '#bb9af7' },
      { key: 'diskread', label: '디스크 READ', color: '#e05b5b' },
      { key: 'diskwrite', label: '디스크 WRITE', color: '#7dcfff' },
    ], chartArea);
    api('GET', `${apiPath}/status/current`).then((st) => {
      const c = el('div', 'card');
      const rows = [
        ['상태', st.status], ['코어', st.cpus],
        ['메모리', `${fmtBytes(st.mem)} / ${fmtBytes(st.maxmem)}`],
        ['네트워크', `in ${fmtBytes(st.netin)}/s · out ${fmtBytes(st.netout)}/s`],
        ['디스크', `read ${fmtBytes(st.diskread)}/s · write ${fmtBytes(st.diskwrite)}/s`],
      ];
      c.appendChild(el('div', '', rows.map(([k2, v]) => `<div class="kv"><span class="k">${k2}</span><span>${v ?? '-'}</span></div>`).join('')));
      body.appendChild(c);
    }).catch(() => {});
  } else if (guestTab === 'snapshot') {
    renderSnapshots(root, apiPath, sel.type);
  } else if (guestTab === 'backup') {
    renderBackup(root, apiPath, sel);
  } else if (guestTab === 'config') {
    const body = el('div', 'pane-body');
    root.appendChild(body);
    api('GET', `${apiPath}/config`).then((cfg) => {
      body.appendChild(el('pre', 'json', JSON.stringify(cfg, null, 2)));
    });
  } else if (guestTab === 'shell') {
    const panel = el('div', '', '');
    panel.id = 'terminal-panel';
    panel.style.height = 'calc(100vh - 150px)';
    root.appendChild(panel);
    startTerminal(panel, { node: sel.node, vmid: sel.vmid, isVM: isVMKind(sel.type) });
  }
}

// ---------- 확인 모달 ----------
let modalResolve = null;
function confirmModal(bodyText, onOk) {
  $('#modal-body').textContent = bodyText;
  $('#modal-bg').style.display = 'flex';
  modalResolve = onOk;
}
$('#modal-cancel').addEventListener('click', () => { $('#modal-bg').style.display = 'none'; modalResolve = null; });
$('#modal-ok').addEventListener('click', () => {
  $('#modal-bg').style.display = 'none';
  if (modalResolve) modalResolve();
  modalResolve = null;
});

// ---------- 스냅샷 ----------
function renderSnapshots(root, apiPath, type) {
  const body = el('div', 'pane-body');
  root.appendChild(body);
  const head = el('div', '', `<b>스냅샷</b>`);
  head.style.marginBottom = '10px';
  body.appendChild(head);
  const newBtn = el('button', 'btn primary', '+ 스냅샷 생성');
  head.appendChild(newBtn);
  newBtn.style.marginLeft = '10px';

  const table = el('table', '', `<thead><tr><th>이름</th><th>시간</th><th>설명</th><th>작업</th></tr></thead><tbody></tbody>`);
  body.appendChild(table);
  const tbody = $('tbody', table);

  newBtn.addEventListener('click', () => {
    const name = prompt('스냅샷 이름 (영문/숫자/-/_):');
    if (!name) return;
    const desc = prompt('설명 (선택):') || '';
    api('POST', `${apiPath}/snapshot`, { snapname: name, description: desc })
      .then(() => setTimeout(renderDetail, 800))
      .catch((e) => alert(e.message));
  });

  api('GET', `${apiPath}/snapshot`).then((snaps) => {
    for (const s of snaps || []) {
      const tr = el('tr');
      const isCurrent = s.name === 'current';
      tr.appendChild(el('td', '', isCurrent ? `<i style="color:var(--muted)">${s.name} (현재)</i>` : `<b>${s.name}</b>`));
      tr.appendChild(el('td', '', fmtDate(s.snaptime)));
      tr.appendChild(el('td', '', s.description || ''));
      const td = el('td');
      if (!isCurrent) {
        const rb = el('button', 'btn', '롤백');
        rb.addEventListener('click', () => confirmModal(`스냅샷 "${s.name}"(으)로 롤백합니다.`, async () => {
          try { await api('POST', `${apiPath}/snapshot/${encodeURIComponent(s.name)}/rollback`, {}); } catch (e) { alert(e.message); }
          setTimeout(renderDetail, 2000);
        }));
        rb.style.marginRight = '6px';
        const del = el('button', 'btn danger', '삭제');
        del.addEventListener('click', () => confirmModal(`스냅샷 "${s.name}"을(를) 삭제합니다.`, async () => {
          try { await api('DELETE', `${apiPath}/snapshot/${encodeURIComponent(s.name)}`); } catch (e) { alert(e.message); }
          setTimeout(renderDetail, 1500);
        }));
        td.appendChild(rb); td.appendChild(del);
      }
      tr.appendChild(td);
      tbody.appendChild(tr);
    }
  }).catch((e) => body.appendChild(el('div', 'card', `스냅샷 로드 실패: ${e.message}`)));
}

// ---------- 백업 (vzdump + 목록) ----------
function renderBackup(root, apiPath, sel) {
  const body = el('div', 'pane-body');
  root.appendChild(body);
  const bar = el('div', 'row', '');
  bar.innerHTML = '<label>저장소</label>';
  const selStorage = el('select', 'field');
  bar.appendChild(selStorage);
  const runBtn = el('button', 'btn primary', '지금 백업');
  bar.appendChild(runBtn);
  body.appendChild(bar);

  const barnTable = el('table', '', `<thead><tr><th>볼륨</th><th>포맷</th><th>크기</th><th>생성</th></tr></thead><tbody></tbody>`);
  body.appendChild(barnTable);
  const tbody = $('tbody', barnTable);

  api('GET', '/api2/json/cluster/resources?type=storage').then((storages) => {
    const backups = (storages || []).filter((s) => (s.content || '').includes('backup'));
    selStorage.innerHTML = backups.map((s) => `<option value="${s.node}|${s.storage}">${s.node} / ${s.storage}</option>`).join('');
    if (backups.length === 0) throw new Error('backup 컨텐츠를 지원하는 스토리지가 없습니다.');
    const loadRows = async () => {
      const [node, storage] = selStorage.value.split('|');
      try {
        const list = (await api('GET', `/api2/json/nodes/${node}/storage/${storage}/content?content=backup`)) || [];
        tbody.innerHTML = (list.filter((c) => c.vmid == sel.vmid).map((c) =>
          `<tr><td>${c.volid}</td><td>${c.format || '-'}</td><td>${fmtBytes(c.size)}</td><td>${fmtDate(c.creation)}</td></tr>`
        )).join('') || '<tr><td colspan="4">보관된 백업 없음</td></tr>';
      } catch (e) { tbody.innerHTML = `<tr><td colspan="4">${e.message}</td></tr>`; }
    };
    selStorage.addEventListener('change', loadRows);
    runBtn.addEventListener('click', () => confirmModal(
      `VM ${sel.vmid}를 모드 snapshot, 압축 zstd로 ${selStorage.value.split('|')[1]}에 백업합니다.`, async () => {
        const [node, storage] = selStorage.value.split('|');
        try {
          await api('POST', `/api2/json/nodes/${node}/vzdump`, { vmid: String(sel.vmid), storage, mode: 'snapshot', compress: 'zstd' });
          alert('백업 작업이 시작되었습니다 (스토리지 태스크에서 진행 확인).');
          setTimeout(loadRows, 5000);
        } catch (e) { alert(e.message); }
      }));
    loadRows();
  }).catch((e) => body.appendChild(el('div', 'card', e.message)));
}

// ---------- 노드 상세 ----------
function renderNode(root, node, quiet) {
  const actions = [];
  const shellBtn = el('button', 'btn primary', '셸');
  shellBtn.addEventListener('click', () => {
    state.selection.nodeShell = true;
    renderNodeWithShell(root, node);
  });
  actions.push(shellBtn);
  paneHead(root, node, nodesOf().find((n) => n.name === node)?.pveversion || '노드 상세', actions);

  const tabs = el('div', '', '');
  ['monitor|모니터링', 'services|서비스', 'tasks|태스크', 'shell|셸'].forEach((p) => {
    const [id, label] = p.split('|');
    const b = el('button', 'btn' + (nodeTab === id ? ' primary' : ''), label);
    b.addEventListener('click', () => { nodeTab = id; renderDetail(); });
    b.style.margin = '0 6px 0 0';
    b.style.marginTop = '10px';
    b.style.marginLeft = '18px';
    tabs.appendChild(b);
  });
  root.appendChild(tabs);

  if (nodeTab === 'shell') { renderNodeWithShell(root, node); return; }
  const body = el('div', 'pane-body');
  root.appendChild(body);
  const apiPath = `/api2/json/nodes/${node}`;

  if (nodeTab === 'monitor') {
    rrddata(`${apiPath}/rrddata`, [
      { key: 'cpu', label: 'CPU', color: '#f5a623' },
      { key: 'mem', label: '메모리', color: '#7aa2f7' },
      { key: 'loadavg', label: '로드 평균', color: '#46c78f' },
      { key: 'rootused', label: '루트 디스크 사용', color: '#e05b5b' },
      { key: 'netin', label: '네트워크 IN', color: '#7dcfff' },
      { key: 'netout', label: '네트워크 OUT', color: '#bb9af7' },
    ], body);
    api('GET', `${apiPath}/status`).then((st) => {
      const c = el('div', 'card');
      const rows = [
        ['PVE 버전', st.pveversion], ['코어', st.cpus],
        ['로드 평균', (st.loadavg || []).join(' / ')],
        ['메모리', `${fmtBytes(st.mem)} / ${fmtBytes(st.maxmem)}`],
        ['루트 디스크', `${fmtBytes(st.rootfs?.used)} / ${fmtBytes(st.rootfs?.total)}`],
        ['업타임', fmtUptime(st.uptime)],
        ['커널', st.kversion],
      ];
      c.appendChild(el('div', '', rows.map(([k2, v]) => `<div class="kv"><span class="k">${k2}</span><span>${v ?? '-'}</span></div>`).join('')));
      body.appendChild(c);
    }).catch(() => {});
  } else if (nodeTab === 'services') {
    api('GET', `${apiPath}/services`).then((svc) => {
      const t = el('table', '', `<thead><tr><th>상태</th><th>이름</th><th>설명</th></tr></thead><tbody></tbody>`);
      $('tbody', t).innerHTML = (svc || []).map((s) =>
        `<tr><td><span class="dot ${s.state === 'running' ? 'on' : 'off'}"></span> ${s.state}</td><td>${s.name}</td><td style="color:var(--muted)">${s.desc || ''}</td></tr>`
      ).join('');
      body.appendChild(t);
    });
  } else if (nodeTab === 'tasks') {
    api('GET', `${apiPath}/tasks?limit=50`).then((ts) => {
      const t = el('table', '', taskTableHead());
      $('tbody', t).innerHTML = (ts || []).map(taskRow).join('') || '<tr><td colspan="6">없음</td></tr>';
      body.appendChild(t);
    });
  }
}
let nodeTab = 'monitor';

function taskTableHead() {
  return `<thead><tr><th>시간</th><th>유형</th><th>설명</th><th>노드</th><th>사용자</th><th>상태</th></tr></thead>`;
}
function taskRow(t) {
  const run = !t.status && t.starttime && !t.endtime;
  return `<tr><td>${fmtDate(t.starttime)}</td><td>${t.type || ''}</td><td>${t.desc || ''}</td><td>${t.node || ''}</td>
    <td>${t.user || ''}</td><td style="color:${run ? 'var(--green)' : (t.status === 'OK' ? 'var(--green)' : 'var(--red)')}">
    ${run ? '실행 중' : (t.status || '-')}</td></tr>`;
}

// ---------- 태스크 (클러스터) ----------
function renderTasks(root) {
  paneHead(root, '클러스터 태스크', '최근 100개');
  const body = el('div', 'pane-body');
  root.appendChild(body);
  api('GET', '/api2/json/cluster/tasks?limit=100').then((ts) => {
    const t = el('table', '', taskTableHead());
    $('tbody', t).innerHTML = (ts || []).map(taskRow).join('') || '<tr><td colspan="6">없음</td></tr>';
    body.appendChild(t);
  }).catch((e) => body.appendChild(el('div', 'card', e.message)));
}

// ---------- 스토리지 ----------
function renderStorage(root) {
  paneHead(root, '스토리지', '클러스터 스토리지 현황');
  const body = el('div', 'pane-body');
  root.appendChild(body);
  const grid = el('div', 'grid');
  body.appendChild(grid);
  state.resources.filter((r) => r.type === 'storage').forEach((s) => {
    const c = el('div', 'card');
    c.appendChild(el('div', '', `<b>${s.storage}</b> <span style="color:var(--muted);font-size:12px">${s.node}</span>`));
    c.appendChild(el('div', 'kv', `<span class="k">상태</span><span>${s.status}</span>`));
    c.appendChild(el('div', 'kv', `<span class="k">디스크 사용</span><span>${fmtBytes(s.disk)} / ${fmtBytes(s.maxdisk)}</span>`));
    const bar = el('div', 'bar');
    const fill = el('div');
    const frac = s.maxdisk ? (s.disk || 0) / s.maxdisk : 0;
    fill.style.width = `${Math.min(100, frac * 100)}%`;
    bar.appendChild(fill);
    c.appendChild(bar);
    grid.appendChild(c);
  });
}

// ---------- API 탐색기 ----------
function renderApiExplorer(root) {
  paneHead(root, 'API 탐색기', '모든 Proxmox API 엔드포인트에 직접 호출');
  const body = el('div', 'pane-body');
  root.appendChild(body);
  const bar = el('div', 'row');
  const method = el('select', 'field');
  ['GET', 'POST', 'DELETE'].forEach((m) => { const o = el('option', '', m); method.appendChild(o); });
  const pathIn = el('input', 'field');
  pathIn.style.flex = '1';
  pathIn.value = '/api2/json/cluster/status';
  const go = el('button', 'btn primary', '실행');
  bar.appendChild(method); bar.appendChild(pathIn); bar.appendChild(go);
  body.appendChild(bar);
  const bodyIn = el('input', 'field');
  bodyIn.placeholder = '폼 파라미터 key=value&key2=value2 (POST/DELETE)';
  bodyIn.style.marginTop = '8px';
  bodyIn.style.width = '100%';
  body.appendChild(bodyIn);
  const out = el('pre', 'json', '');
  out.style.marginTop = '12px';
  out.textContent = '결과가 여기에 표시됩니다';
  body.appendChild(out);
  go.addEventListener('click', async () => {
    let form = undefined;
    const m = method.value.toUpperCase();
    if (m !== 'GET' && bodyIn.value.trim()) {
      form = {};
      for (const kv of bodyIn.value.split('&')) {
        const [k, v] = kv.split('=');
        if (k) form[k] = v ?? '';
      }
    }
    try {
      const data = await api(m, pathIn.value.trim(), form);
      out.textContent = JSON.stringify(data, null, 2);
    } catch (e) {
      out.textContent = `오류: ${e.message}`;
    }
  });
}

// ---------- 터미널 (xterm + 메인 프로세스 웹소켓 브릿지) ----------
function startTerminal(panel, { node, vmid, isVM }) {
  panel.innerHTML = '';
  const term = new Terminal({
    fontFamily: "'Consolas', 'Menlo', monospace",
    fontSize: 13,
    theme: {
      background: '#10121a', foreground: '#e6e6e6', cursor: '#f5a623',
      black: '#2e3440', red: '#e05b5b', green: '#9ece6a', yellow: '#e0af68',
      blue: '#7aa2f7', magenta: '#bb9af7', cyan: '#7dcfff', white: '#d5d6de',
    },
  });
  term.open(panel);
  const msg = el('div', 'sub', '연결 중...');
  msg.style.padding = '6px 10px';
  panel.parentElement.appendChild(msg);

  window.pve.termStart({ node, vmid: vmid ?? null, isVM: !!isVM, cols: 110, rows: 30 }).then((res) => {
    if (!res.ok) { msg.textContent = `연결 실패: ${res.error}`; return; }
    msg.textContent = '연결됨';
    state.currentTermId = res.id;
    window.pve.termData(res.id, (b64) => {
      const raw = atob(b64);
      const u8 = new Uint8Array(raw.length);
      for (let i = 0; i < raw.length; i++) u8[i] = raw.charCodeAt(i);
      term.write(u8);
    });
    window.pve.termClosed(res.id, (reason) => { msg.textContent = `종료: ${reason}`; });
    term.onData((d) => window.pve.termInput(res.id, d));
    term.onResize(({ cols, rows }) => window.pve.termResize(res.id, cols, rows));
    term.resize(110, 30);
  }).catch((e) => { msg.textContent = `연결 실패: ${e.message}`; });
}

function renderNodeWithShell(root, node) {
  const panel = el('div', '', '');
  panel.id = 'terminal-panel';
  panel.style.height = 'calc(100vh - 150px)';
  root.appendChild(panel);
  startTerminal(panel, { node, vmid: null, isVM: false });
}
