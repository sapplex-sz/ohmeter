import AppKit

/// Renders a compact SF Symbol usage icon for the menu bar status display.
struct BatteryIconRenderer {

    /// Create an NSImage for the usage SF Symbol.
    static func usageImage(pointSize: CGFloat = 13) -> NSImage? {
        guard let img = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        return img.withSymbolConfiguration(config)
    }

    /// Create an NSTextAttachment with the usage SF Symbol, vertically centered
    /// relative to the given font.
    static func usageAttachment(font: NSFont) -> NSAttributedString? {
        guard let icon = usageImage() else { return nil }
        icon.isTemplate = true

        let attachment = NSTextAttachment()
        attachment.image = icon
        let imgSize = icon.size
        let yOffset = (font.capHeight - imgSize.height) / 2
        attachment.bounds = NSRect(x: 0, y: yOffset, width: imgSize.width, height: imgSize.height)

        return NSAttributedString(attachment: attachment)
    }

    // MARK: - Attributed Title Builder

    /// Build the full attributed title for the status bar button.
    /// Items: [(label, percent, hasError)]
    static func buildAttributedTitle(items: [(label: String, percent: Int, hasError: Bool)]) -> NSAttributedString {
        let font = NSFont.menuBarFont(ofSize: 0)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let mas = NSMutableAttributedString()

        func appendText(_ s: String) {
            mas.append(NSAttributedString(string: s, attributes: textAttrs))
        }

        for (i, item) in items.enumerated() {
            let prefix = i > 0 ? "  " : ""
            if item.hasError {
                appendText("\(prefix)\(item.label) ⚠️")
            } else {
                appendText("\(prefix)\(item.label) \(item.percent)% ")
                if let attach = usageAttachment(font: font) {
                    mas.append(attach)
                }
            }
        }

        if mas.length == 0 {
            appendText("OhMeter ⚠️")
        }

        return mas
    }
}
