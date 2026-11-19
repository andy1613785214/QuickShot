import AppKit

final class Receiver: NSView, NSServicesMenuRequestor {
    var received: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let type = returnType, NSImage.imageTypes.contains(type.rawValue) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        let success = Self.copyPhoto(from: pasteboard, to: .general)
        received?(success)
        return success
    }

    static func copyPhoto(from source: NSPasteboard, to destination: NSPasteboard) -> Bool {
        // Keep valid PNG imports intact, including their original pixel density.
        if let png = source.data(forType: .png), NSBitmapImageRep(data: png) != nil {
            return writePNG(png, to: destination)
        }
        guard let image = NSImage(pasteboard: source), image.isValid,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return writePNG(png, to: destination)
    }

    private static func writePNG(_ png: Data, to destination: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png) else { return false }
        destination.clearContents()
        return destination.writeObjects([item])
    }
}

// Only search within AppKit's camera menu. Multiple matches require a device choice.
func photoCommands(in menu: NSMenu) -> [NSMenuItem] {
    let titles = ["take photo", "take picture", "拍照", "拍摄照片", "拍攝照片"]
    menu.update()
    return menu.items.flatMap { item -> [NSMenuItem] in
        guard !item.isHidden else { return [] }
        if let submenu = item.submenu { return photoCommands(in: submenu) }
        let name = item.title.trimmingCharacters(in: CharacterSet(charactersIn: ".… ")).lowercased()
        return item.isEnabled && item.action != nil && titles.contains(name) ? [item] : []
    }
}
