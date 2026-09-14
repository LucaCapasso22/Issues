import { pathToFileURL } from "node:url";
import {
  FOCUS_SIZE,
  HoverState,
  ICON_SIZE,
  PREVIEW_SIZE,
  anchorFromIconBounds,
  badgeBounds,
  clampBounds,
  containsPoint,
  iconBoundsFromAnchor,
  previewCardBounds,
  previewPlacement,
  snapBounds,
} from "./geometry.mjs";

export const STATE_CHANNEL = "issues:state";

const APP_NAME = "Issues Electron";
const APP_ID = "app.issues.electron";
const HOVER_POLL_MS = 50;

function integerBounds(bounds) {
  return Object.fromEntries(Object.entries(bounds).map(([key, value]) => [key, Math.round(value)]));
}

function isAlive(window) {
  return Boolean(window && !window.isDestroyed?.() && window.webContents && !window.webContents.isDestroyed?.());
}

function inProgressCount(state) {
  return Array.isArray(state?.issues) ? state.issues.filter((issue) => issue?.group === "inProgress").length : 0;
}

function hasPinnedIssue(state) {
  return typeof state?.pinnedIssueID === "string" && state.pinnedIssueID.length > 0;
}

function trayImage(nativeImage) {
  // NativeImage decodes PNG consistently on both target platforms. Its green
  // pixels stay visible in the Windows tray; macOS uses the alpha as a template.
  const png = "iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAAWElEQVR4nGPI7/djoCamqmHEGPgfBybZQFwGETSYkGHEWIjXQIJeIqSepgbiMoxQuKGIEzKQmMgYNZCGkTL40yE2LxIyiGDWIxQZZBUOpMYySQaSjKluIAD6A3prxQRXhAAAAABJRU5ErkJggg==";
  const image = nativeImage.createFromBuffer(Buffer.from(png, "base64"), { scaleFactor: 1 });
  if (process.platform === "darwin") image.setTemplateImage?.(true);
  return image;
}

export class WindowManager {
  constructor({ electron, rendererPath, preloadPath, getState, onMessage, loadBounds, saveBounds }) {
    if (!electron?.BrowserWindow || !electron?.screen) throw new TypeError("WindowManager requires Electron BrowserWindow and screen modules.");
    if (typeof rendererPath !== "string" || typeof preloadPath !== "string") throw new TypeError("WindowManager requires renderer and preload paths.");
    if (typeof getState !== "function") throw new TypeError("WindowManager requires getState(mode, placement).");

    this.electron = electron;
    this.rendererPath = rendererPath;
    this.preloadPath = preloadPath;
    this.getState = getState;
    this.onMessage = typeof onMessage === "function" ? onMessage : () => {};
    this.loadBounds = typeof loadBounds === "function" ? loadBounds : () => null;
    this.saveBounds = typeof saveBounds === "function" ? saveBounds : () => {};

    this.mainWindow = null;
    this.floatingWindow = null;
    this.tray = null;
    this.floatingMode = "icon";
    this.collapsedMode = "icon";
    this.previewHorizontal = "left";
    this.previewVertical = "above";
    this.floatingAnchor = null;
    this.hover = new HoverState();
    this.hoverTimer = null;
    this.drag = null;
    this.mainBoundsTimer = null;
    this.closing = false;
    this.started = false;
    this.shortcut = process.platform === "darwin" ? "Command+Alt+I" : "Control+Shift+I";
    this.rendererURL = pathToFileURL(rendererPath).href;
  }

  start() {
    if (this.started) return this;
    this.started = true;
    this.electron.app?.setName?.(APP_NAME);
    this.electron.app?.setAppUserModelId?.(APP_ID);
    this.#createWindows();
    this.#configureMenus();
    this.#registerShortcut();
    this.#showMain();
    return this;
  }

  broadcast() {
    if (!this.started) return;
    const mainState = this.getState("main", {});
    if (this.collapsedMode === "focus" && !hasPinnedIssue(mainState)) {
      this.collapsedMode = "icon";
      if (this.floatingMode === "focus") this.#setFloatingMode("icon");
    }
    const alwaysOnTop = Boolean(mainState?.alwaysOnTop);
    this.mainWindow?.setAlwaysOnTop?.(alwaysOnTop);
    this.floatingWindow?.setAlwaysOnTop?.(alwaysOnTop);
    this.#sendState(this.mainWindow, mainState);
    this.#sendState(this.floatingWindow, this.getState(this.floatingMode, {
      previewHorizontal: this.previewHorizontal,
      previewVertical: this.previewVertical,
    }));
    if (this.tray) {
      const shortcut = this.shortcut.replace("Command", "Cmd").replace("Control", "Ctrl");
      this.tray.setToolTip?.(`${APP_NAME} · ${inProgressCount(mainState)} in progress · ${shortcut}`);
    }
  }

  handle(message, sourceWindow) {
    const action = typeof message?.action === "string" ? message.action : "";
    switch (action) {
      case "ready": {
        const window = this.#resolveWindow(sourceWindow);
        if (!window) return true;
        window.__issuesReady = true;
        this.#sendState(window, window === this.mainWindow
          ? this.getState("main", {})
          : this.getState(this.floatingMode, {
            previewHorizontal: this.previewHorizontal,
            previewVertical: this.previewVertical,
          }));
        return true;
      }
      case "open":
        this.#showMain();
        return true;
      case "minimize":
        this.#showFloating("icon");
        return true;
      case "showFocus":
        this.#showFloating("focus");
        return true;
      case "drag":
        this.#handleDrag(message.phase);
        return true;
      case "hover":
        return true;
      case "quit":
        this.close();
        this.electron.app?.quit?.();
        return true;
      default:
        return false;
    }
  }

  ownsWebContents(sender) {
    return isAlive(this.mainWindow) && this.mainWindow.webContents === sender
      || isAlive(this.floatingWindow) && this.floatingWindow.webContents === sender;
  }

  isTrustedFrame(event) {
    if (!event || !this.ownsWebContents(event.sender)) return false;
    const frame = event.senderFrame;
    if (!frame || frame !== event.sender?.mainFrame) return false;
    try {
      const url = new URL(frame.url);
      return url.protocol === "file:" && url.pathname === new URL(this.rendererURL).pathname;
    } catch {
      return false;
    }
  }

  close() {
    if (this.closing) return;
    this.closing = true;
    if (this.hoverTimer) clearInterval(this.hoverTimer);
    if (this.mainBoundsTimer) clearTimeout(this.mainBoundsTimer);
    this.hoverTimer = null;
    this.mainBoundsTimer = null;
    this.electron.globalShortcut?.unregister?.(this.shortcut);
    this.tray?.destroy?.();
    this.tray = null;
    for (const window of [this.floatingWindow, this.mainWindow]) {
      if (isAlive(window)) window.destroy();
    }
    this.floatingWindow = null;
    this.mainWindow = null;
    this.started = false;
  }

  #createWindows() {
    const { BrowserWindow } = this.electron;
    const mainFallback = this.#defaultMainBounds();
    const loadedMain = this.#readBounds("main");
    const mainBounds = this.#clampToDisplay({
      ...mainFallback,
      ...(loadedMain ?? {}),
      width: Math.max(380, loadedMain?.width ?? mainFallback.width),
      height: Math.max(450, loadedMain?.height ?? mainFallback.height),
    });
    this.mainWindow = new BrowserWindow({
      ...integerBounds(mainBounds),
      minWidth: 380,
      minHeight: 450,
      show: false,
      title: APP_NAME,
      backgroundColor: "#fcfcfb",
      webPreferences: this.#webPreferences(),
    });

    const floatingBounds = this.#initialFloatingBounds();
    this.floatingAnchor = anchorFromIconBounds(floatingBounds);
    this.floatingWindow = new BrowserWindow({
      ...integerBounds(floatingBounds),
      show: false,
      frame: false,
      transparent: true,
      backgroundColor: "#00000000",
      resizable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      skipTaskbar: true,
      hasShadow: false,
      title: APP_NAME,
      webPreferences: this.#webPreferences(),
    });
    this.floatingWindow.setVisibleOnAllWorkspaces?.(true, { visibleOnFullScreen: true });

    this.#secureWebContents(this.mainWindow);
    this.#secureWebContents(this.floatingWindow);
    this.mainWindow.loadFile(this.rendererPath, { query: { mode: "main" } });
    this.floatingWindow.loadFile(this.rendererPath, { query: { mode: "icon" } });

    this.mainWindow.on("close", (event) => {
      if (this.closing) return;
      event.preventDefault();
      this.#showFloating("icon");
    });
    this.mainWindow.on("minimize", (event) => {
      if (this.closing) return;
      event.preventDefault();
      this.mainWindow.restore?.();
      this.#showFloating("icon");
    });
    this.mainWindow.on("move", () => this.#scheduleMainBoundsSave());
    this.mainWindow.on("resize", () => this.#scheduleMainBoundsSave());
  }

  #webPreferences() {
    return {
      preload: this.preloadPath,
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webviewTag: false,
    };
  }

  #secureWebContents(window) {
    const contents = window.webContents;
    contents.setWindowOpenHandler?.(({ url }) => {
      if (this.#isAllowedExternalURL(url)) void this.electron.shell?.openExternal?.(url);
      return { action: "deny" };
    });
    contents.on?.("will-navigate", (event, url) => {
      if (url === contents.getURL?.() || url.startsWith(`${this.rendererURL}?`)) return;
      event.preventDefault();
      if (this.#isAllowedExternalURL(url)) void this.electron.shell?.openExternal?.(url);
    });
    contents.on?.("will-attach-webview", (event) => event.preventDefault());
  }

  #isAllowedExternalURL(value) {
    try {
      const url = new URL(value);
      return url.protocol === "https:" && url.hostname === "github.com" && !url.username && !url.password && !url.port;
    } catch {
      return false;
    }
  }

  #configureMenus() {
    const { Menu, Tray, nativeImage } = this.electron;
    if (!Menu) return;
    const open = () => this.#showMain();
    const minimize = () => this.#showFloating("icon");
    const focus = () => this.#showFloating("focus");
    const refresh = () => this.onMessage({ action: "refresh" }, this.mainWindow);
    const settings = () => {
      this.onMessage({ action: "settings", value: true }, this.mainWindow);
      this.#showMain();
    };
    const quit = () => {
      this.close();
      this.electron.app?.quit?.();
    };
    const shared = [
      { label: "Show Issues", click: open },
      { label: "Minimize to Icon", click: minimize },
      { label: "Pinned Issue", click: focus },
      { label: "Refresh", click: refresh },
      { type: "separator" },
      { label: "Settings…", click: settings },
      { label: `Quit ${APP_NAME}`, click: quit },
    ];
    const applicationMenu = process.platform === "darwin"
      ? [{ label: APP_NAME, submenu: [
        { label: `About ${APP_NAME}`, role: "about" },
        { type: "separator" },
        { label: "Settings…", accelerator: "CmdOrCtrl+,", click: settings },
        { type: "separator" },
        { label: `Quit ${APP_NAME}`, accelerator: "Cmd+Q", click: quit },
      ] }, { role: "editMenu" }, { role: "windowMenu" }]
      : [{ label: "File", submenu: [{ label: "Settings…", accelerator: "Ctrl+,", click: settings }, { type: "separator" }, { label: "Quit", accelerator: "Alt+F4", click: quit }] }, { role: "editMenu" }];
    Menu.setApplicationMenu?.(Menu.buildFromTemplate(applicationMenu));

    if (Tray && nativeImage) {
      this.tray = new Tray(trayImage(nativeImage));
      this.tray.setToolTip?.(APP_NAME);
      this.tray.setContextMenu?.(Menu.buildFromTemplate(shared));
      this.tray.on?.("click", () => this.mainWindow?.isVisible?.() ? minimize() : open());
    }
  }

  #registerShortcut() {
    const shortcut = this.electron.globalShortcut;
    if (!shortcut?.register) return;
    try {
      shortcut.register(this.shortcut, () => {
        if (this.mainWindow?.isVisible?.()) this.#showFloating("icon");
        else this.#showMain();
      });
    } catch {
      // A failed global shortcut must not prevent the desktop shell from starting.
    }
  }

  #showMain() {
    if (!isAlive(this.mainWindow)) return;
    this.hover.reset();
    if (this.hoverTimer) clearInterval(this.hoverTimer);
    this.hoverTimer = null;
    this.floatingWindow?.hide?.();
    this.mainWindow.show?.();
    this.mainWindow.focus?.();
    this.broadcast();
  }

  #showFloating(requestedMode = "icon") {
    if (!isAlive(this.floatingWindow)) return;
    const state = this.getState("main", {});
    this.collapsedMode = requestedMode === "focus" && hasPinnedIssue(state) ? "focus" : "icon";
    this.hover.reset();
    this.drag = null;
    this.mainWindow?.hide?.();
    this.#setFloatingMode(this.collapsedMode);
    this.floatingWindow.showInactive?.();
    if (!this.floatingWindow.isVisible?.()) this.floatingWindow.show?.();
    if (!this.hoverTimer) this.hoverTimer = setInterval(() => this.#pollPointer(), HOVER_POLL_MS);
    this.broadcast();
  }

  #setFloatingMode(mode) {
    if (!isAlive(this.floatingWindow) || !this.floatingAnchor) return;
    this.floatingMode = mode;
    let bounds;
    if (mode === "preview") {
      const icon = iconBoundsFromAnchor(this.floatingAnchor);
      const area = this.#workAreaForBounds(icon);
      const placement = previewPlacement(this.floatingAnchor, area);
      bounds = placement.bounds;
      this.previewHorizontal = placement.horizontal;
      this.previewVertical = placement.vertical;
    } else {
      const size = mode === "focus" ? FOCUS_SIZE : { width: ICON_SIZE, height: ICON_SIZE };
      const raw = {
        x: this.floatingAnchor.x - size.width,
        y: this.floatingAnchor.y - size.height,
        width: size.width,
        height: size.height,
      };
      bounds = clampBounds(raw, this.#workAreaForBounds(raw));
      if (mode === "icon") this.floatingAnchor = anchorFromIconBounds(bounds);
    }
    this.floatingWindow.setHasShadow?.(mode !== "icon");
    this.floatingWindow.setBounds(integerBounds(bounds), false);
    this.#sendState(this.floatingWindow, this.getState(mode, {
      previewHorizontal: this.previewHorizontal,
      previewVertical: this.previewVertical,
    }));
  }

  #pollPointer() {
    if (!isAlive(this.floatingWindow) || !this.floatingWindow.isVisible?.() || this.collapsedMode !== "icon" || this.drag) {
      this.hover.reset();
      return;
    }
    const point = this.electron.screen.getCursorScreenPoint();
    const icon = iconBoundsFromAnchor(this.floatingAnchor);
    const state = this.getState("icon", {});
    const count = inProgressCount(state);
    const preview = this.floatingWindow.getBounds();
    const transition = this.hover.update({
      now: Date.now(),
      overBadge: count > 0 && containsPoint(badgeBounds(icon, count), point),
      insidePreview: containsPoint(icon, point)
        || containsPoint(previewCardBounds(preview, this.previewVertical), point),
      isPreview: this.floatingMode === "preview",
    });
    if (transition) this.#setFloatingMode(transition);
  }

  #handleDrag(phase) {
    if (!isAlive(this.floatingWindow) || !this.floatingWindow.isVisible?.()) return;
    if (phase === "start") {
      this.hover.reset();
      if (this.floatingMode === "preview") this.#setFloatingMode(this.collapsedMode);
      this.drag = {
        pointer: this.electron.screen.getCursorScreenPoint(),
        origin: this.floatingWindow.getBounds(),
      };
      return;
    }
    if (phase === "move" && this.drag) {
      const pointer = this.electron.screen.getCursorScreenPoint();
      const bounds = {
        ...this.drag.origin,
        x: this.drag.origin.x + pointer.x - this.drag.pointer.x,
        y: this.drag.origin.y + pointer.y - this.drag.pointer.y,
      };
      this.floatingWindow.setBounds(integerBounds(bounds), false);
      return;
    }
    if (phase === "end" && this.drag) {
      const current = this.floatingWindow.getBounds();
      const snapped = snapBounds(current, this.#workAreaForBounds(current));
      this.floatingWindow.setBounds(integerBounds(snapped), false);
      this.floatingAnchor = anchorFromIconBounds(snapped);
      this.#writeBounds("floating", iconBoundsFromAnchor(this.floatingAnchor));
      this.drag = null;
    }
  }

  #sendState(window, state) {
    if (!isAlive(window) || !window.__issuesReady) return;
    window.webContents.send(STATE_CHANNEL, state);
  }

  #resolveWindow(source) {
    if (source === this.mainWindow || source === this.floatingWindow) return source;
    if (source === this.mainWindow?.webContents) return this.mainWindow;
    if (source === this.floatingWindow?.webContents) return this.floatingWindow;
    return null;
  }

  #workAreaForBounds(bounds) {
    const display = this.electron.screen.getDisplayMatching?.(integerBounds(bounds))
      ?? this.electron.screen.getDisplayNearestPoint?.({ x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 })
      ?? this.electron.screen.getPrimaryDisplay?.();
    return display?.workArea ?? display?.bounds ?? { x: 0, y: 0, width: 1_000, height: 700 };
  }

  #clampToDisplay(bounds) {
    return clampBounds(bounds, this.#workAreaForBounds(bounds));
  }

  #defaultMainBounds() {
    const area = this.electron.screen.getPrimaryDisplay?.()?.workArea ?? { x: 0, y: 0, width: 1_000, height: 700 };
    return {
      x: area.x + Math.round((area.width - 440) / 2),
      y: area.y + Math.round((area.height - 590) / 2),
      width: 440,
      height: 590,
    };
  }

  #initialFloatingBounds() {
    const loaded = this.#readBounds("floating");
    const area = this.electron.screen.getPrimaryDisplay?.()?.workArea ?? { x: 0, y: 0, width: 1_000, height: 700 };
    const fallback = {
      x: area.x + area.width - ICON_SIZE - 24,
      y: area.y + Math.round((area.height - ICON_SIZE) / 2),
      width: ICON_SIZE,
      height: ICON_SIZE,
    };
    return this.#clampToDisplay({
      x: loaded?.x ?? fallback.x,
      y: loaded?.y ?? fallback.y,
      width: ICON_SIZE,
      height: ICON_SIZE,
    });
  }

  #scheduleMainBoundsSave() {
    if (this.closing || !isAlive(this.mainWindow)) return;
    if (this.mainBoundsTimer) clearTimeout(this.mainBoundsTimer);
    this.mainBoundsTimer = setTimeout(() => {
      this.mainBoundsTimer = null;
      if (isAlive(this.mainWindow) && !this.mainWindow.isMinimized?.()) this.#writeBounds("main", this.mainWindow.getBounds());
    }, 180);
  }

  #readBounds(key) {
    try {
      const value = this.loadBounds(key);
      return value && typeof value === "object" ? value : null;
    } catch {
      return null;
    }
  }

  #writeBounds(key, bounds) {
    try {
      this.saveBounds(key, integerBounds(bounds));
    } catch {
      // Window persistence failure is non-fatal.
    }
  }
}
