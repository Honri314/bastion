const { app, BrowserWindow, ipcMain, shell, safeStorage } = require('electron');
const path = require('path');
const https = require('https');
const { URL, URLSearchParams } = require('url');
const WebSocket = require('ws');

// 자체 서명 인증서 수용 (PVE 기본값)
app.commandLine.appendSwitch('ignore-certificate-errors');

// ------- PVE 클라이언트 상태 -------
const pve = {
  host: '', port: 8006,
  ticket: '', csrf: '', user: '', realm: 'pam',
  password: '', // 자동 재로그인용 (메모리에만 유지)
};

function pveUrl(p) {
  return new URL(`https://${pve.host}:${pve.port}${p}`);
}

function encodeForm(form) {
  const sp = new URLSearchParams();
  for (const [k, v] of Object.entries(form || {})) sp.append(k, String(v));
  return sp.toString();
}

function httpClient(method, fullUrl, { headers = {}, body = null } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(fullUrl);
    const req = https.request({
      hostname: u.hostname,
      port: u.port || 443,
      path: u.pathname + u.search,
      method,
      headers,
      rejectUnauthorized: false,
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    req.setTimeout(20000, () => req.destroy(new Error('연결 시간 초과')));
    if (body) req.write(body);
    req.end();
  });
}

async function pveRequest(method, p, form) {
  const headers = {
    Cookie: `PVEAuthCookie=${encodeURIComponent(pve.ticket)}`,
    'User-Agent': 'pve-electron-client',
  };
  if (method !== 'GET' && method !== 'HEAD') headers['CSRFPreventionToken'] = pve.csrf;
  let body = null;
  if (form && Object.keys(form).length) {
    body = encodeForm(form);
    headers['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
  }
  let res = await httpClient(method, pveUrl(p).toString(), { headers, body });
  let obj = {};
  try { obj = JSON.parse(res.body); } catch { obj = { message: res.body }; }
  if (res.status === 401 && pve.password) {
    await pveLogin(pve.user, pve.realm, pve.password, '');
    return pveRequest(method, p, form);
  }
  if (res.status >= 400) {
    const msg = obj.errors || obj.message || obj.data || `HTTP ${res.status}`;
    throw new Error(typeof msg === 'string' ? msg : JSON.stringify(msg));
  }
  return obj.data;
}

async function pveLogin(user, realm, password, otp) {
  pve.user = user; pve.realm = realm; pve.password = password;
  const body = encodeForm({ username: `${user}@${realm}`, password, otp: otp || undefined });
  const res = await httpClient('POST', pveUrl('/api2/json/access/ticket').toString(), {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
    body,
  });
  let obj = {};
  try { obj = JSON.parse(res.body); } catch { throw new Error('응답 파싱 실패'); }
  if (res.status >= 400 || !obj.data || !obj.data.ticket) {
    const m = obj.errors || obj.message || '로그인 실패';
    throw new Error(typeof m === 'string' ? m : JSON.stringify(m));
  }
  pve.ticket = obj.data.ticket;
  pve.csrf = obj.data.CSRFPreventionToken;
  pve.user = obj.data.username;
  return { ok: true };
}

// ------- 터미널 (termproxy + vncwebsocket) -------
// 프로토콜: 첫 프레임 "user:ticket\n"→"OK", 사이즈 "1:cols:rows:", 입력 "0:len:...", keepalive "2"
const terms = new Map(); // id → { ws, keepalive }

async function termStart(id, { node, vmid, isVM, cols, rows }) {
  const path = vmid == null
    ? `/api2/json/nodes/${node}/termproxy`
    : `/api2/json/nodes/${node}/${isVM ? 'qemu' : 'lxc'}/${vmid}/termproxy`;
  const data = await pveRequest('POST', path, {});
  if (!data || !data.port || !data.ticket) throw new Error('termproxy 실패');

  const wsUrl = pveUrl(`/api2/json/nodes/${node}/vncwebsocket?port=${data.port}&vncticket=${encodeURIComponent(data.ticket)}`);
  const ws = new WebSocket(wsUrl, 'binary', {
    rejectUnauthorized: false,
    headers: { Cookie: `PVEAuthCookie=${encodeURIComponent(pve.ticket)}` },
  });

  return new Promise((resolve, reject) => {
    let wsReady = false;
    const timer = setTimeout(() => reject(new Error('웹소켓 연결 시간 초과')), 30000);
    ws.on('open', () => {
      ws.send(`${data.user}:${data.ticket}\n`, { binary: true });
    });
    ws.on('message', (buf) => {
      const s = buf.toString('utf8');
      if (s === 'OK') {
        clearTimeout(timer);
        wsReady = true;
        ws.send(`1:${cols}:${rows}:`, { binary: true });
        keepaliveLoop(id, ws);
        resolve({ started: true });
        return;
      }
      if (!wsReady) return;
      // 일반 터미널 출력 → 모든 창의 렌더러로 전달
      for (const t of BrowserWindow.getAllWindows()) {
        t.webContents.send(`pve-term-data-${id}`, buf.toString('base64'));
      }
    });
    ws.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
      for (const t of BrowserWindow.getAllWindows()) t.webContents.send(`pve-term-closed-${id}`, e.message);
    });
    ws.on('close', () => {
      clearInterval(terms.get(id)?.keepalive);
      terms.delete(id);
      for (const t of BrowserWindow.getAllWindows()) t.webContents.send(`pve-term-closed-${id}`, 'closed');
    });
    terms.set(id, { ws, keepalive: null });
  });
}

function keepaliveLoop(id, ws) {
  const iv = setInterval(() => {
    try { ws.send('2', { binary: true }); } catch { clearInterval(iv); }
  }, 30000);
  const t = terms.get(id);
  if (t) t.keepalive = iv;
}

function termInput(id, text) {
  const t = terms.get(id);
  if (!t) return;
  const data = Buffer.from(text, 'utf8');
  const frame = Buffer.concat([Buffer.from(`0:${data.length}:`, 'utf8'), data]);
  t.ws.send(frame, { binary: true });
}

function termResize(id, cols, rows) {
  const t = terms.get(id);
  if (t) t.ws.send(`1:${cols}:${rows}:`, { binary: true });
}

function termStop(id) {
  const t = terms.get(id);
  if (t) {
    clearInterval(t.keepalive);
    try { t.ws.close(); } catch {}
    terms.delete(id);
  }
}

// ------- VNC (noVNC 브릿지) -------
// 렌더러의 가짜 WebSocket은 메인이 보유한 실제 웹소켓만 통과시킨다.
// termproxy와 동일하게: open → "user:ticket\n" → "OK" 수신 후 릴레이 시작
const vncs = new Map(); // id → { ws, buffersReady }
let vncSeq = 0;

async function vncPrepare(node, vmid) {
  const id = `v${Date.now()}_${vncSeq++}`;
  try {
    const data = await pveRequest('POST', `/api2/json/nodes/${node}/qemu/${vmid}/vncproxy`, { websocket: '1' });
    if (!data || !data.port || !data.ticket) throw new Error('vncproxy 실패');
    const wsUrl = pveUrl(`/api2/json/nodes/${node}/qemu/${vmid}/vncwebsocket?port=${data.port}&vncticket=${encodeURIComponent(data.ticket)}`);
    const ws = new WebSocket(wsUrl, 'binary', {
      rejectUnauthorized: false,
      headers: { Cookie: `PVEAuthCookie=${encodeURIComponent(pve.ticket)}` },
    });
    return new Promise((resolve) => {
      const timer = setTimeout(() => resolve({ ok: false, error: '웹소켓 시간 초과', id }), 30000);
      ws.on('open', () => {
        ws.send(`${data.user}:${data.ticket}\n`, { binary: true });
      });
      ws.on('message', (buf) => {
        const entry = vncs.get(id);
        if (!entry) return;
        if (!entry.ready) {
          const s = buf.toString('utf8');
          if (s.trim().toUpperCase() === 'OK') {
            clearTimeout(timer);
            entry.ready = true;
            for (const w of BrowserWindow.getAllWindows()) w.webContents.send(`vnc-ready-${id}`, null);
          } else {
            clearTimeout(timer);
            resolve({ ok: false, error: `인증 실패: ${s}`, id });
          }
          return;
        }
        for (const w of BrowserWindow.getAllWindows()) w.webContents.send(`vnc-data-${id}`, buf.toString('base64'));
      });
      ws.on('error', (e) => {
        clearTimeout(timer);
        for (const w of BrowserWindow.getAllWindows()) w.webContents.send(`vnc-closed-${id}`, e.message);
      });
      ws.on('close', () => {
        for (const w of BrowserWindow.getAllWindows()) w.webContents.send(`vnc-closed-${id}`, 'closed');
      });
      vncs.set(id, { ws, ready: false });
      resolve({ ok: true, id });
    });
  } catch (err) {
    return { ok: false, error: err.message, id };
  }
}

// ------- 서버 프로필 (다중 PVE 인스턴스 전환 + 비밀번호 암호 저장) -------
// 목록은 userData/profiles.json, 비밀번호는 OS 보안 스토리지(Win: DPAPI / macOS: Keychain)로 암호화해 동일 파일에 보관.
const fs = require('fs');
const profilesPath = () => path.join(app.getPath('userData'), 'profiles.json');

function readProfiles() {
  try { return JSON.parse(fs.readFileSync(profilesPath(), 'utf8')); }
  catch { return []; }
}

function writeProfiles(list) {
  fs.writeFileSync(profilesPath(), JSON.stringify(list, null, 2));
}

function encryptedPw(pw) {
  if (!pw || !safeStorage.isEncryptionAvailable()) return undefined;
  return safeStorage.encryptString(pw).toString('base64');
}

function decryptedPw(entry) {
  if (!entry.passwordEnc || !safeStorage.isEncryptionAvailable()) return '';
  try { return safeStorage.decryptString(Buffer.from(entry.passwordEnc, 'base64')); }
  catch { return ''; }
}

ipcMain.handle('pve:profiles', () => {
  return readProfiles().map((p) => ({
    id: p.id, label: p.label, host: p.host, port: p.port, user: p.user,
    realm: p.realm, savePassword: !!p.passwordEnc, password: decryptedPw(p),
  }));
});

ipcMain.handle('pve:profile-save', (e, { profile, password, savePassword }) => {
  const list = readProfiles();
  const p = { id: profile.id, label: profile.label || profile.host, host: profile.host,
              port: profile.port || 8006, user: profile.user, realm: profile.realm || 'pam' };
  const i = list.findIndex((x) => x.id === p.id);
  if (savePassword && password) p.passwordEnc = encryptedPw(password);
  if (i >= 0) list[i] = { ...list[i], ...p };
  else list.push(p);
  writeProfiles(list);
  return { ok: true };
});

ipcMain.handle('pve:profile-delete', (e, id) => {
  writeProfiles(readProfiles().filter((x) => x.id !== id));
  return { ok: true };
});

// ------- IPC -------
ipcMain.handle('pve:login', async (e, { host, port, user, realm, password, otp }) => {
  pve.host = host; pve.port = port || 8006;
  try {
    await pveLogin(user, realm, password, otp);
    return { ok: true, user: pve.user };
  } catch (err) {
    return { ok: false, error: err.message };
  }
});

ipcMain.handle('pve:api', async (e, { method, path, form }) => {
  try {
    const m = (method || 'GET').toUpperCase();
    const data = await pveRequest(m, path, form);
    return { ok: true, data };
  } catch (err) {
    return { ok: false, error: err.message };
  }
});

ipcMain.on('vnc:ws-send', (e, { id, b64 }) => {
  const v = vncs.get(id);
  if (!v) return;
  const buf = Buffer.from(b64, 'base64');
  try { v.ws.send(buf, { binary: true }); } catch {}
});

ipcMain.on('vnc:ws-close', (e, { id }) => {
  const v = vncs.get(id);
  if (v) { try { v.ws.close(); } catch {} vncs.delete(id); }
});

let termSeq = 0;
ipcMain.handle('pve:term-start', async (e, opts = {}) => {
  const id = `t${Date.now()}_${termSeq++}`;
  try {
    await termStart(id, opts);
    return { ok: true, id };
  } catch (err) {
    termStop(id);
    return { ok: false, error: err.message };
  }
});

ipcMain.on('pve:term-input', (e, { id, text }) => termInput(id, text));
ipcMain.on('pve:term-resize', (e, { id, cols, rows }) => termResize(id, cols, rows));
ipcMain.on('pve:term-stop', (e, { id }) => termStop(id));

ipcMain.handle('vnc:open', async (e, { node, vmid }) => {
  const cur = BrowserWindow.fromWebContents(e.sender);
  const win = new BrowserWindow({
    width: 1024, height: 720,
    parent: cur, modal: false,
    title: `콘솔 · VM ${vmid} · ${node}`,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.loadFile(path.join(__dirname, 'vnc.html'), { query: { node, vmid: String(vmid) } });
  return { ok: true };
});

ipcMain.handle('vnc:prepare', async (e, { node, vmid }) => {
  return vncPrepare(node, vmid);
});

// 메인 창
function createWindow() {
  const win = new BrowserWindow({
    width: 1280, height: 820,
    minWidth: 1000, minHeight: 640,
    title: 'Bastion',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.removeMenu();
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
