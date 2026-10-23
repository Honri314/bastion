const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pve', {
  login: (opts) => ipcRenderer.invoke('pve:login', opts),
  profiles: () => ipcRenderer.invoke('pve:profiles'),
  profileSave: (profile, password, savePassword) => ipcRenderer.invoke('pve:profile-save', { profile, password, savePassword }),
  profileDelete: (id) => ipcRenderer.invoke('pve:profile-delete', id),
  api: (method, path, form) => ipcRenderer.invoke('pve:api', { method, path, form }),
  openVNC: (node, vmid) => ipcRenderer.invoke('vnc:open', { node, vmid }),
  vncPrepare: (node, vmid) => ipcRenderer.invoke('vnc:prepare', { node, vmid }),
  vncSend: (id, b64) => ipcRenderer.send('vnc:ws-send', { id, b64 }),
  vncClose: (id) => ipcRenderer.send('vnc:ws-close', { id }),
  vncData: (id, cb) => ipcRenderer.on(`vnc-data-${id}`, (_e, b64) => cb(b64)),
  vncClosed: (id, cb) => ipcRenderer.on(`vnc-closed-${id}`, (_e, reason) => cb(reason)),
  vncReady: (id, cb) => ipcRenderer.on(`vnc-ready-${id}`, () => cb()),

  termStart: (opts) => ipcRenderer.invoke('pve:term-start', opts),
  termInput: (id, text) => ipcRenderer.send('pve:term-input', { id, text }),
  termResize: (id, cols, rows) => ipcRenderer.send('pve:term-resize', { id, cols, rows }),
  termStop: (id) => ipcRenderer.send('pve:term-stop', { id }),
  termData: (id, cb) => {
    const name = `pve-term-data-${id}`;
    ipcRenderer.on(name, (_e, data) => cb(data));
  },
  termClosed: (id, cb) => {
    const name = `pve-term-closed-${id}`;
    ipcRenderer.on(name, (_e, reason) => cb(reason));
  },
});
