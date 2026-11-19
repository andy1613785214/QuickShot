import AppKit
import ApplicationServices
import Carbon

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
        let app = AXUIElementCreateApplication(pid)
        guard let focus = attribute(app, kAXFocusedUIElementAttribute as CFString),
              CFGetTypeID(focus) == AXUIElementGetTypeID() else { return false }
        let node = focus as! AXUIElement
        return attribute(node, kAXRoleAttribute as CFString) as? String == kAXTextAreaRole as String
    }

    static func attach(change: Int, result: @escaping (String?) -> Void) {
        guard let id = target, let url = namedClient(id) else {
            result("请安装 ChatGPT 桌面应用，或在网页版用 ⌘V 粘贴照片。"); return
        }
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { running, _ in
            DispatchQueue.main.async {
                guard let running, running.bundleIdentifier == id else { result("无法打开 ChatGPT，可手动粘贴照片。"); return }
                guard trusted else { result("照片已复制。请允许 QuickShot 使用辅助功能，本次可在 ChatGPT 中按 ⌘V。"); return }
                awaitEditor(running, change: change, remaining: 30, result: result)
            }
        }
    }

    private static func awaitEditor(_ app: NSRunningApplication, change: Int, remaining: Int, result: @escaping (String?) -> Void) {
        guard NSPasteboard.general.changeCount == change else { result("剪贴板内容已更改，已停止粘贴。"); return }
        if app.isActive && hasEditorFocus(app.processIdentifier) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
                result("请在 ChatGPT 输入框按 ⌘V 粘贴照片。"); return
            }
            for event in [down, up] {
                event.flags = .maskCommand
                event.postToPid(app.processIdentifier)
            }
            result(nil)
        } else if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                awaitEditor(app, change: change, remaining: remaining - 1, result: result)
            }
        } else { result("照片已复制。请点入 ChatGPT 的消息输入框，按 ⌘V。") }
    }
}
