import AppKit
import ApplicationServices

enum ChatDraft {
    // The current desktop app and the classic macOS client have different bundle IDs.
    static let clients = [("ChatGPT", "com.openai.codex"), ("ChatGPT Classic", "com.openai.chat")]
    static var installed: [(String, String)] {
        clients.filter { namedClient($0.1) != nil }
    }
    static func namedClient(_ id: String) -> URL? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        if id == "com.openai.codex" && !url.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains("ChatGPT") { return nil }
        return url
    }
    static var target: String? {
        let preferred = UserDefaults.standard.string(forKey: "chatClient")
        return installed.first(where: { $0.1 == preferred })?.1 ?? installed.first?.1
    }

    private static func attribute(_ node: AXUIElement, _ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, key, &value) == .success else { return nil }
        return value
    }

    // Limit automatic paste to a focused multiline editor in the chosen app.
    private static func hasEditorFocus(_ pid: pid_t) -> Bool {
        guard let focus = element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString) else { return false }
        let role = attribute(focus, kAXRoleAttribute as CFString) as? String
        return role == "AXTextArea" || (role == "AXTextField" && identifiesComposer(focus))
    }

    private static func identifiesComposer(_ node: AXUIElement) -> Bool {
        let labels = ["prompt-textarea", "ask anything", "message chatgpt", "send a message",
                      "输入消息", "发消息", "询问任何", "傳送訊息", "輸入訊息"]
        return [kAXIdentifierAttribute, kAXPlaceholderValueAttribute, kAXDescriptionAttribute].contains { key in
            guard let text = attribute(node, key as CFString) as? String else { return false }
            return labels.contains(where: text.lowercased().contains)
        }
    }

    private static func focusComposer(in app: AXUIElement) {
        guard let window = element(app, kAXFocusedWindowAttribute as CFString) else { return }
        var queue = [window]
        var index = 0
        while index < queue.count && index < 350 {
            let node = queue[index]
            index += 1
            let role = attribute(node, kAXRoleAttribute as CFString) as? String
            if ["AXTextArea", "AXTextField"].contains(role), identifiesComposer(node) {
                AXUIElementSetAttributeValue(node, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return
            }
            if !["AXStaticText", "AXButton", "AXImage", "AXMenu", "AXLink"].contains(role) {
                queue.append(contentsOf: children(node).prefix(350 - queue.count))
            }
        }
    }

    private static func element(_ node: AXUIElement, _ key: CFString) -> AXUIElement? {
        guard let value = attribute(node, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func children(_ node: AXUIElement) -> [AXUIElement] {
        attribute(node, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    // Match the actual Paste command, never Paste and Match Style, voice, or Send.
    static func pasteItem(in app: AXUIElement) -> AXUIElement? {
        guard let bar = element(app, kAXMenuBarAttribute as CFString) else { return nil }
        for top in children(bar) {
            guard let title = attribute(top, kAXTitleAttribute as CFString) as? String,
                  ["Edit", "编辑", "編輯"].contains(title) else { continue }
            for menu in children(top) {
                for item in children(menu) {
                    guard let name = attribute(item, kAXTitleAttribute as CFString) as? String,
                          ["Paste", "粘贴", "黏貼", "貼上", "粘貼"].contains(name),
                          attribute(item, kAXRoleAttribute as CFString) as? String == "AXMenuItem",
                          attribute(item, kAXEnabledAttribute as CFString) as? Bool == true else { continue }
                    return item
                }
            }
        }
        return nil
    }

    static func attach(change: Int, result: @escaping (String?) -> Void) {
        guard let id = target, let url = namedClient(id) else {
            result("请安装 ChatGPT 桌面应用，或在网页版用 ⌘V 粘贴照片。"); return
        }
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            if !running.isActive { running.activate(options: [.activateAllWindows]) }
            beginPaste(running, trusted: trusted, change: change, result: result)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { running, _ in
            DispatchQueue.main.async {
                guard let running, running.bundleIdentifier == id else { result("无法打开 ChatGPT，可手动粘贴照片。"); return }
                beginPaste(running, trusted: trusted, change: change, result: result)
            }
        }
    }

    private static func beginPaste(_ app: NSRunningApplication, trusted: Bool, change: Int, result: @escaping (String?) -> Void) {
        guard trusted else { result("照片已复制。请在系统设置的辅助功能中允许 QuickShot，本次可在 ChatGPT 中按 ⌘V。"); return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if app.bundleIdentifier == "com.openai.codex" {
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        awaitEditor(app, change: change, remaining: 30, result: result)
    }

    private static func awaitEditor(_ app: NSRunningApplication, change: Int, remaining: Int, result: @escaping (String?) -> Void) {
        guard NSPasteboard.general.changeCount == change else { result("剪贴板内容已更改，已停止粘贴。"); return }
        if remaining == 28, app.isActive, !hasEditorFocus(app.processIdentifier) {
            focusComposer(in: AXUIElementCreateApplication(app.processIdentifier))
        }
        if app.isActive && hasEditorFocus(app.processIdentifier) {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if let paste = pasteItem(in: root), app.isActive, hasEditorFocus(app.processIdentifier),
               NSPasteboard.general.changeCount == change {
                // An AX timeout can mean the paste was delivered. Never retry a dispatched command.
                let response = AXUIElementPerformAction(paste, kAXPressAction as CFString)
                result(response == .success ? nil : "无法确认粘贴结果，请查看草稿。照片仍可用 ⌘V 粘贴。")
                return
            }
        }
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                awaitEditor(app, change: change, remaining: remaining - 1, result: result)
            }
        } else { result("照片已复制。请点入 ChatGPT 的消息输入框，按 ⌘V。") }
    }
}
