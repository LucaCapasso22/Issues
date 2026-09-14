import * as electron from 'electron';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { GitHubClient } from './github.mjs';
import { AppStore } from './store.mjs';
import { Persistence } from './persistence.mjs';
import { WindowManager } from './windows.mjs';
import { validMessage, githubExternalURL } from './bridge.mjs';

const { app, ipcMain, BrowserWindow, dialog, shell, safeStorage, clipboard, session } = electron;
app.setName('Issues Electron');
app.setAppUserModelId('app.issues.electron');
app.setPath('userData', process.env.ISSUES_ELECTRON_USER_DATA || join(app.getPath('appData'), 'Issues Electron'));
const rendererPath = fileURLToPath(new URL('../renderer/index.html', import.meta.url));
const preloadPath = fileURLToPath(new URL('./preload.cjs', import.meta.url));
let store;
let windows;
let choosingAttachments = false;
const singleInstance = app.requestSingleInstanceLock();
if (!singleInstance) app.quit();
else {
  app.on('second-instance', () => windows?.handle({ action: 'open' }, windows.mainWindow));
  app.on('activate', () => windows?.handle({ action: 'open' }, windows.mainWindow));
  app.on('window-all-closed', () => {});
  app.on('before-quit', () => { store?.close(); windows?.close(); });
  app.whenReady().then(async () => {
    session.defaultSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
    session.defaultSession.setPermissionCheckHandler(() => false);
    const persistence = new Persistence({ dir: app.getPath('userData'), crypto: safeStorage });
    store = new AppStore({
      client: new GitHubClient(), persistence,
      onChange: () => windows?.broadcast(),
      openExternal: value => shell.openExternal(githubExternalURL(value)),
      copyText: value => clipboard.writeText(String(value))
    });
    windows = new WindowManager({
      electron, rendererPath, preloadPath,
      getState: (mode, placement) => store.state(mode, placement),
      onMessage: message => { void route(message); },
      loadBounds: key => persistence.loadBounds(key),
      saveBounds: (key, bounds) => persistence.saveBounds(key, bounds)
    });
    async function route(message, sourceWindow = windows.mainWindow) {
      if (!validMessage(message)) return;
      try {
        if (windows.handle(message, sourceWindow)) return;
        if (message.action === 'chooseAttachments') {
          const state = store.state();
          if (choosingAttachments || state.isMutating || state.composerLoading || !state.composerMetadata?.canWrite) return;
          choosingAttachments = true;
          const project = state.projectURL;
          const repository = state.composerRepository;
          try {
            const result = await dialog.showOpenDialog(windows.mainWindow, {
              title: 'Attach images or videos', buttonLabel: 'Add attachments',
              properties: ['openFile', 'multiSelections'],
              filters: [{ name: 'Images and videos', extensions: ['png','jpg','jpeg','gif','webp','svg','mp4','mov','webm'] }]
            });
            const current = store.state();
            if (!result.canceled && project === current.projectURL && repository === current.composerRepository) await store.addAttachments(result.filePaths);
          } finally { choosingAttachments = false; }
          return;
        }
        await store.dispatch(message);
        if (message.action === 'pin' && store.state().pinnedIssueID === message.id) windows.handle({ action: 'showFocus' }, sourceWindow);
      } catch (error) {
        // Never log action payloads: connection messages can contain credentials.
        dialog.showErrorBox('Issues Electron', 'The operation could not be completed. Please try again or reconnect in Settings.');
      }
    }
    ipcMain.on('issues:action', (event, message) => {
      if (!windows.isTrustedFrame(event)) return;
      void route(message, BrowserWindow.fromWebContents(event.sender));
    });
    windows.start();
    await store.initialize({ demo: process.argv.includes('--demo') });
    windows.broadcast();
  }).catch(() => {
    dialog.showErrorBox('Issues Electron', 'The app could not start. Check that its resources are present and its data folder is writable.');
    app.quit();
  });
}
