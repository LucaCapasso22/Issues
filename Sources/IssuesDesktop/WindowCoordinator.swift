import AppKit
import WebKit
import Combine
import Carbon
import UniformTypeIdentifiers

struct FloatingPanelPlacement {
    let frame: NSRect
    let horizontal: String
    let vertical: String
}

enum FloatingPanelGeometry {
    static func previewPlacement(anchor: NSPoint, visibleFrame: NSRect) -> FloatingPanelPlacement {
        let margin: CGFloat = 8
        let orbSize: CGFloat = 64
        let previewSize = NSSize(width: 330, height: 240)
        let orbMinX = anchor.x - orbSize
        let orbMaxY = anchor.y + orbSize

        let fitsLeft = anchor.x - previewSize.width >= visibleFrame.minX + margin
        let fitsRight = orbMinX + previewSize.width <= visibleFrame.maxX - margin
        let horizontal: String
        if fitsLeft || !fitsRight {
            let roomLeft = anchor.x - visibleFrame.minX
            let roomRight = visibleFrame.maxX - orbMinX
            horizontal = fitsLeft || roomLeft >= roomRight ? "left" : "right"
        } else {
            horizontal = "right"
        }

        let fitsAbove = anchor.y + previewSize.height <= visibleFrame.maxY - margin
        let fitsBelow = orbMaxY - previewSize.height >= visibleFrame.minY + margin
        let vertical: String
        if fitsAbove || !fitsBelow {
            let roomAbove = visibleFrame.maxY - anchor.y
            let roomBelow = orbMaxY - visibleFrame.minY
            vertical = fitsAbove || roomAbove >= roomBelow ? "above" : "below"
        } else {
            vertical = "below"
        }

        let origin = NSPoint(
            x: horizontal == "left" ? anchor.x - previewSize.width : orbMinX,
            y: vertical == "above" ? anchor.y : orbMaxY - previewSize.height
        )
        return FloatingPanelPlacement(
            frame: NSRect(origin: origin, size: previewSize),
            horizontal: horizontal,
            vertical: vertical
        )
    }
}

// Pointer-driven transitions survive DOM replacement and window resizing.
struct FloatingHoverState {
    private var pendingPreview: Bool?
    private var deadline: TimeInterval = 0

    mutating func reset() { pendingPreview = nil }

    mutating func update(now: TimeInterval, overBadge: Bool, insidePreview: Bool, isPreview: Bool) -> String? {
        let wantsPreview = isPreview ? insidePreview : overBadge
        guard wantsPreview != isPreview else { reset(); return nil }
        if pendingPreview != wantsPreview {
            pendingPreview = wantsPreview
            deadline = now + (wantsPreview ? 0.18 : 0.25)
        }
        guard now >= deadline else { return nil }
        reset()
        return wantsPreview ? "preview" : "icon"
    }
}

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
    let store: AppStore
    private let mainWindow: NSWindow
    private let panel: FloatingPanel
    private var mainWeb: WebSurface!
    private var floatingWeb: WebSurface!
    private var statusItem: NSStatusItem!
    private var observation: AnyCancellable?
    private var focusObserver: NSObjectProtocol?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var localKeyMonitor: Any?
    private var shortcutMenuItem: NSMenuItem?
    private var globalShortcutFailure: OSStatus?
    private var floatingMode = "icon"
    private var collapsedMode = "icon"
    private var restoring = false
    private var hoverState = FloatingHoverState()
    private var hoverTimer: Timer?
    private var dragStart: NSPoint?
    private var dragOrigin: NSPoint?
    private var panelAnchor = NSPoint.zero
    private var isDragging = false
    private var refreshQueued = false

    init(store: AppStore) {
        self.store = store
        mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 590), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        mainWindow.title = "Issues"
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.backgroundColor = .windowBackgroundColor
        mainWindow.contentMinSize = NSSize(width: 380, height: 450)
        mainWindow.isReleasedWhenClosed = false
        mainWindow.delegate = self
        mainWindow.setFrameAutosaveName("IssuesMainWindow")
        if !mainWindow.setFrameUsingName("IssuesMainWindow") { mainWindow.center() }
        mainWeb = WebSurface(store: store, mode: "main") { [weak self] message in self?.handle(message) }
        mainWindow.contentView = mainWeb.webView

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        floatingWeb = WebSurface(store: store, mode: "icon") { [weak self] message in self?.handle(message) }
        panel.contentView = floatingWeb.webView
        restorePanelPosition()
        configureMenus()
        registerShortcut()
        focusObserver = NotificationCenter.default.addObserver(forName: .issuesShowFocus, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.showFloating(mode: "focus") }
        }
        observation = store.objectWillChange.sink { [weak self] _ in
            guard let self, !self.refreshQueued else { return }
            self.refreshQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshQueued = false
                self.pushState()
            }
        }
    }

    func start() {
        if UserDefaults.standard.string(forKey: "presentationMode") == "floating", store.isConfigured || store.isDemo {
            let saved = UserDefaults.standard.string(forKey: "floatingMode") ?? "icon"
            showFloating(mode: saved)
        } else { showMain() }
    }
    func showMain() {
        hoverState.reset()
        hoverTimer?.invalidate(); hoverTimer = nil
        panel.orderOut(nil)
        NSApp.setActivationPolicy(.regular)
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set("main", forKey: "presentationMode")
        pushState()
    }
    func showFloating(mode: String = "icon") {
        hoverState.reset()
        mainWindow.orderOut(nil)
        collapsedMode = mode == "focus" && store.pinnedIssue != nil ? "focus" : "icon"
        setPanelMode(collapsedMode)
        panel.orderFrontRegardless()
        if hoverTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.trackHover() }
            }
            hoverTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        UserDefaults.standard.set("floating", forKey: "presentationMode")
        UserDefaults.standard.set(collapsedMode, forKey: "floatingMode")
        pushState()
    }
    private func trackHover() {
        guard panel.isVisible, collapsedMode == "icon", !isDragging else { hoverState.reset(); return }
        let mouse = NSEvent.mouseLocation
        let iconFrame = NSRect(x: panelAnchor.x - 64, y: panelAnchor.y, width: 64, height: 64)
        let badgeWidth = max(23, CGFloat(String(store.inProgressIssues.count).count * 6 + 16))
        let badge = NSRect(x: iconFrame.maxX - badgeWidth, y: iconFrame.maxY - 23, width: badgeWidth, height: 23)
        let card = NSRect(x: panel.frame.minX + 7,
                          y: panel.frame.minY + (floatingWeb.previewVertical == "below" ? 7 : 52),
                          width: 316, height: 181)
        let isPreview = floatingMode == "preview"
        if let mode = hoverState.update(now: ProcessInfo.processInfo.systemUptime,
                                        overBadge: store.inProgressIssues.count > 0 && badge.contains(mouse),
                                        insidePreview: iconFrame.contains(mouse) || card.contains(mouse),
                                        isPreview: isPreview) {
            setPanelMode(mode)
        }
    }

    private func setPanelMode(_ mode: String) {
        floatingMode = mode
        panel.hasShadow = mode == "focus"
        let next: NSRect
        if mode == "preview" {
            let orbFrame = NSRect(x: panelAnchor.x - 64, y: panelAnchor.y, width: 64, height: 64)
            let visibleFrame = NSScreen.screens.first(where: { $0.visibleFrame.intersects(orbFrame) })?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1_000, height: 700)
            let placement = FloatingPanelGeometry.previewPlacement(anchor: panelAnchor, visibleFrame: visibleFrame)
            floatingWeb.previewHorizontal = placement.horizontal
            floatingWeb.previewVertical = placement.vertical
            next = placement.frame
        } else {
            let size = mode == "focus" ? NSSize(width: 330, height: 76) : NSSize(width: 64, height: 64)
            next = clamped(NSRect(x: panelAnchor.x - size.width, y: panelAnchor.y, width: size.width, height: size.height))
        }
        restoring = true
        panel.setFrame(next, display: true)
        restoring = false
        floatingWeb.mode = mode
        floatingWeb.pushState()
    }
    private func pushState() {
        mainWindow.level = store.alwaysOnTop ? .floating : .normal
        panel.level = store.alwaysOnTop ? .floating : .normal
        if collapsedMode == "focus", store.pinnedIssue == nil { collapsedMode = "icon"; setPanelMode("icon") }
        mainWeb.pushState(); floatingWeb.pushState()
        let shortcutStatus = globalShortcutFailure == nil ? "⌘⇧I" : "global shortcut unavailable"
        statusItem.button?.toolTip = "Issues · \(store.inProgressIssues.count) in progress · \(shortcutStatus)"
    }

    private func handle(_ message: [String: Any]) {
        guard let action = message["action"] as? String else { return }
        switch action {
        case "minimize": showFloating()
        case "open": showMain()
        case "showFocus": showFloating(mode: "focus")
        case "quit": NSApp.terminate(nil)
        case "refresh": store.startRefresh()
        case "openProject": store.openProject()
        case "select":
            store.selectedIssueID = (message["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let issue = store.snapshot?.issues.first(where: { $0.id == store.selectedIssueID }) {
                store.loadComposer(repository: issue.repository)
            }
        case "loadComposer":
            if let repository = message["repository"] as? String { store.loadComposer(repository: repository) }
        case "updateAssignees":
            guard let id = message["id"] as? String, let ids = message["assigneeIDs"] as? [String] else { return }
            store.updateAssignees(issueID: id, assigneeIDs: ids)
        case "openIssueComposerOnGitHub": store.openComposerOnGitHub(message)
        case "chooseAttachments":
            guard store.canChooseAttachments else { return }
            let picker = NSOpenPanel()
            picker.title = "Attach images or videos"
            picker.prompt = "Add attachments"
            picker.canChooseDirectories = false; picker.allowsMultipleSelection = true
            picker.allowedContentTypes = ["png", "jpg", "jpeg", "gif", "webp", "svg", "mp4", "mov", "webm"].compactMap { UTType(filenameExtension: $0) }
            picker.beginSheetModal(for: mainWindow) { [weak self] response in
                guard response == .OK else { return }
                Task { @MainActor [weak self] in self?.store.addAttachments(picker.urls) }
            }
        case "removeAttachment":
            if let id = message["id"] as? String { store.removeAttachment(id: id) }
        case "changeStatus":
            guard let id = message["id"] as? String, let option = message["optionID"] as? String else { return }
            store.changeStatus(issueID: id, optionID: option)
        case "createIssue": store.createComposedIssue(message)
        case "clearMutationFeedback": store.clearMutationFeedback()
        case "openCreatedIssue": store.openCreatedIssue()
        case "selectProject":
            guard let url = message["url"] as? String else { return }
            store.selectProject(url: url)
        case "statusVisibility":
            guard let name = message["name"] as? String, let visible = message["visible"] as? Bool else { return }
            store.setStatusVisibility(name: name, visible: visible)
        case "pin", "openIssue":
            guard let id = message["id"] as? String, let issue = store.snapshot?.issues.first(where: { $0.id == id }) else { return }
            if action == "pin" { store.pin(issue) } else if !store.isDemo { store.openOnGitHub(issue) }
        case "settings": store.showSettings = message["value"] as? Bool ?? true; if store.showSettings { showMain() }
        case "preference":
            guard let key = message["key"] as? String else { return }
            switch key {
            case "onlyMine": if let value = message["value"] as? Bool { store.onlyMine = value }
            case "alwaysOnTop": if let value = message["value"] as? Bool { store.alwaysOnTop = value }
            case "search": if let value = message["value"] as? String { store.search = String(value.prefix(1000)) }
            case "inProgressStatuses": if let value = message["value"] as? String { store.inProgressStatuses = String(value.prefix(2000)) }
            case "todoStatuses": if let value = message["value"] as? String { store.todoStatuses = String(value.prefix(2000)) }
            default: return
            }
            store.savePreferences()
        case "connect":
            guard let url = message["projectURL"] as? String, let cli = message["useCLI"] as? Bool else { return }
            store.startConnect(projectURL: String(url.prefix(2000)), useCLI: cli,
                               token: String((message["token"] as? String ?? "").prefix(2000)))
        case "disconnect": store.disconnect(); showMain()
        case "demo": store.enterDemo(); showMain()
        case "leaveDemo": store.leaveDemo(); showMain()
        case "hover": break // Native pointer tracking owns hover; ignore synthetic DOM exits.
        case "drag": drag(message["phase"] as? String ?? "")
        default: break
        }
    }
    private func drag(_ phase: String) {
        guard panel.isVisible else { return }
        switch phase {
        case "start":
            hoverState.reset(); isDragging = true
            if floatingMode == "preview" { setPanelMode(collapsedMode) }
            dragStart = NSEvent.mouseLocation; dragOrigin = panel.frame.origin
        case "move":
            guard let start = dragStart, let origin = dragOrigin else { return }
            let mouse = NSEvent.mouseLocation
            panel.setFrameOrigin(NSPoint(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y))
        case "end":
            isDragging = false; dragStart = nil; dragOrigin = nil
            snapPanel()
            panelAnchor = NSPoint(x: panel.frame.maxX, y: panel.frame.minY)
            savePanelPosition()
        default: break
        }
    }
    private func clamped(_ rect: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(rect) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return rect }
        var result = rect
        result.origin.x = max(area.minX + 8, min(rect.minX, area.maxX - rect.width - 8))
        result.origin.y = max(area.minY + 8, min(rect.minY, area.maxY - rect.height - 8))
        return result
    }
    private func snapPanel() {
        var frame = clamped(panel.frame)
        if let area = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) })?.visibleFrame {
            if abs(frame.minX - area.minX) < 40 { frame.origin.x = area.minX + 12 }
            if abs(area.maxX - frame.maxX) < 40 { frame.origin.x = area.maxX - frame.width - 12 }
            if abs(frame.minY - area.minY) < 40 { frame.origin.y = area.minY + 12 }
            if abs(area.maxY - frame.maxY) < 40 { frame.origin.y = area.maxY - frame.height - 12 }
        }
        panel.setFrame(frame, display: true)
    }
    private func savePanelPosition() {
        guard !restoring else { return }
        UserDefaults.standard.set(panelAnchor.x, forKey: "panelRight")
        UserDefaults.standard.set(panelAnchor.y, forKey: "panelBottom")
    }
    private func restorePanelPosition() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let right = UserDefaults.standard.object(forKey: "panelRight") as? Double ?? screen.maxX - 24
        let bottom = UserDefaults.standard.object(forKey: "panelBottom") as? Double ?? screen.midY
        let frame = clamped(NSRect(x: right - 64, y: bottom, width: 64, height: 64))
        panelAnchor = NSPoint(x: frame.maxX, y: frame.minY)
        panel.setFrame(frame, display: false)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === mainWindow { showFloating(); return false }
        return true
    }
    func windowWillMiniaturize(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow {
            DispatchQueue.main.async { [weak self] in self?.mainWindow.deminiaturize(nil); self?.showFloating() }
        }
    }

    private func configureMenus() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Show Issues", action: #selector(menuOpen), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Issues", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.inset.filled", accessibilityDescription: "Issues")
        let menu = NSMenu()
        shortcutMenuItem = menu.addItem(withTitle: "Open Issues    ⌘⇧I", action: #selector(menuOpen), keyEquivalent: "")
        shortcutMenuItem?.target = self
        menu.addItem(withTitle: "Minimize to Icon", action: #selector(menuMini), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Pinned Issue", action: #selector(menuFocus), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh", action: #selector(menuRefresh), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Issues", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }
    @objc private func menuOpen() { showMain() }
    @objc private func menuMini() { showFloating() }
    @objc private func menuFocus() { showFloating(mode: "focus") }
    @objc private func menuRefresh() { store.startRefresh() }
    @objc private func menuSettings() { store.showSettings = true; showMain() }
    private func togglePresentation() {
        if mainWindow.isVisible { showFloating() } else { showMain() }
    }
    private func registerShortcut() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let relevantModifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            guard event.keyCode == UInt16(kVK_ANSI_I), relevantModifiers == [.command, .shift] else { return event }
            self?.togglePresentation()
            return nil
        }

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let coordinator = Unmanaged<WindowCoordinator>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in coordinator.togglePresentation() }
            return noErr
        }, 1, &type, pointer, &hotKeyHandler)
        let id = EventHotKeyID(signature: 0x49535355, id: 1)
        let registrationStatus = handlerStatus == noErr
            ? RegisterEventHotKey(UInt32(kVK_ANSI_I), UInt32(cmdKey | shiftKey), id, GetApplicationEventTarget(), 0, &hotKey)
            : handlerStatus
        globalShortcutFailure = registrationStatus == noErr ? nil : registrationStatus
        if let failure = globalShortcutFailure {
            shortcutMenuItem?.title = "Open Issues"
            shortcutMenuItem?.toolTip = "Global shortcut ⌘⇧I is unavailable (error \(failure)). The shortcut still works while Issues is focused."
        }
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WebSurface: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    var mode: String
    var previewHorizontal = "left"
    var previewVertical = "above"
    private let store: AppStore
    private let onMessage: ([String: Any]) -> Void
    private var ready = false
    private let webRoot: URL

    init(store: AppStore, mode: String, onMessage: @escaping ([String: Any]) -> Void) {
        self.store = store; self.mode = mode; self.onMessage = onMessage
        webRoot = Bundle.module.url(forResource: "Web", withExtension: nil)!
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        config.userContentController.add(self, name: "issues")
        webView.loadFileURL(webRoot.appendingPathComponent("index.html"), allowingReadAccessTo: webRoot)
    }
    func pushState() {
        var state = store.webState(mode: mode)
        state["previewHorizontal"] = previewHorizontal
        state["previewVertical"] = previewVertical
        guard ready, let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.renderState(\(json));", completionHandler: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any] else { return }
        if body["action"] as? String == "ready" { ready = true; pushState() }
        else { onMessage(body) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; pushState() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.isFileURL,
              url.standardizedFileURL.path == webRoot.appendingPathComponent("index.html").standardizedFileURL.path else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        webView.loadFileURL(webRoot.appendingPathComponent("index.html"), allowingReadAccessTo: webRoot)
    }
}
