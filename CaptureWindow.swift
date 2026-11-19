import AppKit

/// A services request may return key focus to its original window after delivery.
/// Only a new capture is allowed to present this window again.
final class CaptureWindow: NSWindow {
    private var acceptingPresentation = false

    func presentForCapture() {
        acceptingPresentation = true
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        acceptingPresentation = false
        super.close()
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard acceptingPresentation || place == .out else { return }
        super.order(place, relativeTo: otherWin)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        guard acceptingPresentation else { return }
        super.makeKeyAndOrderFront(sender)
    }
}
