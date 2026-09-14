const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('issuesDesktop', Object.freeze({
  platform: process.platform,
  post: message => {
    if (message && typeof message === 'object' && typeof message.action === 'string') ipcRenderer.send('issues:action', message);
  },
  onState: callback => {
    if (typeof callback !== 'function') return;
    const listener = (_event, state) => callback(state);
    ipcRenderer.on('issues:state', listener);
    return () => ipcRenderer.removeListener('issues:state', listener);
  }
}));
