import AppKit
import Carbon
import ServiceManagement

private let signature: OSType = 0x51534854
private let hotkeyCallback: EventHandlerUPP = { _, event, context in
    var id = EventHotKeyID()
    guard let event, let context,
          GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                            nil, MemoryLayout.size(ofValue: id), nil, &id) == noErr,
          id.signature == signature, [1, 2].contains(id.id) else { return OSStatus(eventNotHandledErr) }
    let app = Unmanaged<App>.fromOpaque(context).takeUnretainedValue()
    let key = id.id
    DispatchQueue.main.async { app.handleKey(key) }
    return noErr
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let file = NSMenu(title: "文件")
    let receiver = Receiver(frame: NSRect(x: 0, y: 0, width: 380, height: 176))
    let heading = NSTextField(labelWithString: "使用 iPhone 拍照")
    let message = NSTextField(wrappingLabelWithString: "")
    let statusLine = NSMenuItem(title: "准备就绪", action: nil, keyEquivalent: "")
    let login = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
    var bar: NSStatusItem!
    var panel: CaptureWindow!
    var previous: NSRunningApplication?
    var handler: EventHandlerRef?
    var hotkey: EventHotKeyRef?
    var chord: EventHotKeyRef?
    var pending: DispatchWorkItem?
    var draft = false
    let clientMenu = NSMenu()
    var discovering = false
    var showingMenu = false

    func handleKey(_ key: UInt32) {
        if key == 2 {
            guard pending != nil else { return }
            endChord()
            captureDraft()
            return
        }
        guard pending == nil, !busy, !showingMenu else { return }
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(optionKey),
            EventHotKeyID(signature: signature, id: 2), GetApplicationEventTarget(), 0, &chord)
        guard registered == noErr else { capture(); return }
        let job = DispatchWorkItem { [weak self] in
            self?.endChord()
            self?.capture()
        }
        pending = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: job)
    }

    func endChord() {
        pending?.cancel()
        pending = nil
        if let chord { UnregisterEventHotKey(chord) }
        chord = nil
    }
    var busy: Bool { panel.attachedSheet != nil || NSApp.modalWindow != nil }

    func applicationWillFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        menu.addItem(withTitle: "QuickShot", action: nil, keyEquivalent: "").submenu = NSMenu(title: "QuickShot")
        menu.addItem(withTitle: "文件", action: nil, keyEquivalent: "").submenu = file
        let camera = NSMenuItem(title: "从 iPhone 导入", action: nil, keyEquivalent: "")
        camera.identifier = NSMenuItem.importFromDeviceIdentifier
        file.addItem(camera)
        NSApp.mainMenu = menu
        NSApp.registerServicesMenuSendTypes([], returnTypes: NSImage.imageTypes.map(NSPasteboard.PasteboardType.init(rawValue:)))
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = CaptureWindow(contentRect: receiver.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "QuickShot"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isRestorable = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.styleMask.insert(.fullSizeContentView)
        panel.isMovable = false
        panel.level = .floating
        if #available(macOS 26.0, *) {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            let glass = NSGlassEffectView(frame: receiver.bounds)
            glass.cornerRadius = 24
            glass.contentView = receiver
            panel.contentView = glass
        } else {
            panel.contentView = receiver
        }
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.frame = NSRect(x: 24, y: 112, width: 332, height: 28)
        message.frame = NSRect(x: 24, y: 54, width: 332, height: 52)
        message.textColor = .secondaryLabelColor
        let choose = NSButton(title: "选择设备与拍照…", target: self, action: #selector(showDevices))
        choose.frame = NSRect(x: 18, y: 18, width: 160, height: 32)
        [heading, message, choose].forEach(receiver.addSubview)
        receiver.received = { [weak self] success in
            RunLoop.main.perform(inModes: [.common]) { self?.finished(success) }
        }
        bar = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        bar.button?.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "QuickShot 拍照")
        bar.button?.toolTip = "QuickShot · ⌥ S"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "使用 iPhone 拍照    ⌥ S", action: #selector(capture), keyEquivalent: "").target = self
        menu.addItem(withTitle: "拍照并放入 ChatGPT    ⌥ S+C", action: #selector(captureDraft), keyEquivalent: "").target = self
        for (name, id) in ChatDraft.installed {
            let item = clientMenu.addItem(withTitle: name, action: #selector(selectClient(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
        }
        if clientMenu.items.count > 1 {
            menu.addItem(withTitle: "接收照片的应用", action: nil, keyEquivalent: "").submenu = clientMenu
        }
        menu.addItem(statusLine)
        menu.addItem(.separator())
        login.target = self
        menu.addItem(login)
        menu.addItem(withTitle: "退出 QuickShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        bar.menu = menu
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback, 1, &spec,
                                            Unmanaged.passUnretained(self).toOpaque(), &handler)
        if installed != noErr || RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(optionKey),
            EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &hotkey) != noErr {
            statusLine.title = "⌥ S 注册失败，请从菜单拍照"
        }
        if Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications",
           !UserDefaults.standard.bool(forKey: "initialLoginConfigured") {
            do {
                if SMAppService.mainApp.status == .notRegistered { try SMAppService.mainApp.register() }
                UserDefaults.standard.set(true, forKey: "initialLoginConfigured")
            } catch { statusLine.title = "可从菜单开启登录时启动" }
        }
        if CommandLine.arguments.contains("--capture") {
            DispatchQueue.main.async { self.capture() }
        }
        if CommandLine.arguments.contains("--probe") {
            present()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.probe() }
        }
    }

    func anchorPanel(to screen: NSScreen?) {
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 12, y: frame.maxY - 12))
    }

    @objc func displaysChanged() {
        if panel.isVisible { anchorPanel(to: panel.screen ?? NSScreen.main) }
    }

    func present() {
        let pointer = NSEvent.mouseLocation
        anchorPanel(to: NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)
        if !panel.isVisible { previous = NSWorkspace.shared.frontmostApplication }
        NSApp.activate(ignoringOtherApps: true)
        panel.presentForCapture()
        panel.makeFirstResponder(receiver)
    }

    @objc func selectClient(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject, forKey: "chatClient")
    }

    @objc func captureDraft() { startCapture(forChat: true) }
    @objc func capture() { startCapture(forChat: false) }

    func startCapture(forChat: Bool) {
        guard !discovering, !showingMenu, !busy else { return }
        discovering = true
        draft = forChat
        heading.stringValue = forChat ? "拍照到 ChatGPT" : "拍照到剪贴板"
        present()
        message.stringValue = "正在查找附近的 iPhone…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.discovering = false
            guard self.panel.isVisible, !self.busy else { return }
            let commands = photoCommands(in: self.file)
            if commands.count == 1, let item = commands.first, let menu = item.menu {
                self.message.stringValue = "请在 iPhone 上拍照并选择「使用照片」。"
                NSLog("QuickShot dispatching the system photo command")
                menu.performActionForItem(at: menu.index(of: item))
            } else {
                self.showDevices()
            }
        }
    }

    @objc func showDevices() {
        guard !busy, !showingMenu else { return }
        panel.makeFirstResponder(receiver)
        message.stringValue = "请选择设备下的「拍照」。若设备未出现，请确认两端登录同一 Apple 账户，并打开 Wi-Fi 和蓝牙。"
        let point = NSPoint(x: 30, y: 50)
        file.update()
        if let choices = file.items.first(where: { $0.identifier == NSMenuItem.importFromDeviceIdentifier })?.submenu, !choices.items.isEmpty {
            showingMenu = true
            choices.popUp(positioning: nil, at: point, in: receiver)
            showingMenu = false
            return
        }
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        showingMenu = true
        let menu = NSMenu()
        menu.addItem(withTitle: "从附近设备导入", action: nil, keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: receiver)
        showingMenu = false
    }

    func finished(_ success: Bool) {
        let restoreFocus = NSApp.isActive
        let returnTo = previous
        previous = nil
        panel.close()
        guard success else {
            statusLine.title = "未能读取照片，请重新拍照"
            if restoreFocus { returnTo?.activate(options: []) }
            return
        }
        statusLine.title = "照片已复制 · " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        NSLog("QuickShot received and copied a photo")
        if draft {
            ChatDraft.attach(change: NSPasteboard.general.changeCount) { [weak self] issue in
                self?.statusLine.title = issue ?? "已向 ChatGPT 输入框请求粘贴照片"
                if let issue {
                    let alert = NSAlert()
                    alert.messageText = "ChatGPT 附件"
                    alert.informativeText = issue
                    alert.runModal()
                }
            }
        } else if restoreFocus { returnTo?.activate(options: []) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func menuWillOpen(_ menu: NSMenu) {
        for item in clientMenu.items { item.state = (item.representedObject as? String) == ChatDraft.target ? .on : .off }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.title = SMAppService.mainApp.status == .requiresApproval ? "在系统设置中允许登录启动…" : "登录时启动"
    }

    @objc func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.informativeText += "\n请将 QuickShot 移入「应用程序」后重新打开，再试一次。"
            alert.runModal()
        }
    }

    func probe() {
        if let frame = panel.screen?.visibleFrame {
            print("panelInset", frame.maxX - panel.frame.maxX, frame.maxY - panel.frame.maxY)
        }
        print("hotkeyRegistered", hotkey != nil, "photoCommands", photoCommands(in: file).count)
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = App()
application.delegate = delegate
application.run()
