import AppKit

// Snippets in a menu (#268, Jason: "we should add a divider or something for the shortcuts and the expansion
// text"): told apart the Mac way, by colour, no punctuation. The name in the label colour, its description in
// grey, and what you type for it (";candid", ";p") grey and right-aligned in the shortcut column. SwiftUI menus
// show plain titles only, so each snippet item's title is written as "name, en space, description, tab,
// trigger", and those items get the styled title here the moment SwiftUI adds or changes one (#270: styled only
// when a menu opened, a menu rebuilt after Edit snippets showed raw titles first), and again as a menu opens.
@MainActor
enum SnippetMenuStyle {
    static let gap = "\u{2002}"  // en space between the name and the description

    // The plain title SwiftUI is given; style() knows it by its tab.
    static func title(name: String, summary: String, trigger: String) -> String {
        name + (summary.isEmpty ? "" : gap + summary) + "\t" + trigger
    }

    static func start() {
        // queue nil: handled as it's posted, before the menu draws. Menus are built on the main thread.
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                nonisolated(unsafe) let menu = note.object as? NSMenu
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { if let menu, !styling { styleItems(menu) } }
            }
        }
        // The top menu bar's menus are built before this starts listening; styled once now, the rest as they change.
        NSApp.mainMenu.map { style($0) }
    }
    private static var styling = false  // setting a styled title posts a change of its own

    static func isStyled(_ item: NSMenuItem) -> Bool {
        guard let a = item.attributedTitle, a.length > 0 else { return false }
        return a.attribute(.paragraphStyle, at: 0, effectiveRange: nil) != nil && a.string == item.title
    }

    // This menu's snippet items (not its submenus'), when any of them isn't styled yet.
    static func styleItems(_ menu: NSMenu) {
        let items = menu.items.filter { $0.title.contains("\t") && !$0.isSeparatorItem }
        guard items.contains(where: { !isStyled($0) }) else { return }
        styling = true
        defer { styling = false }
        let font = menu.font ?? NSFont.menuFont(ofSize: 0)
        let parts = items.map { styledParts($0.title) }
        let left = parts.map { ($0.left as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let right = parts.map { ($0.trigger as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let tab = NSMutableParagraphStyle()
        tab.tabStops = [NSTextTab(textAlignment: .right, location: ceil(left + 28 + right))]
        for (item, p) in zip(items, parts) { item.attributedTitle = attributed(p, font: font, tab: tab) }
    }

    // Every snippet item in this menu and its submenus, styled; the trigger column sits past the widest one.
    static func style(_ menu: NSMenu) {
        styleItems(menu)
        for item in menu.items { if let sub = item.submenu { style(sub) } }
    }

    static func styledParts(_ title: String) -> (name: String, summary: String, trigger: String, left: String) {
        let halves = title.components(separatedBy: "\t")
        let left = halves[0], trigger = halves.count > 1 ? halves[1] : ""
        let words = left.components(separatedBy: gap)
        return (words[0], words.dropFirst().joined(separator: gap), trigger, left)
    }

    static func attributed(_ p: (name: String, summary: String, trigger: String, left: String), font: NSFont, tab: NSParagraphStyle) -> NSAttributedString {
        let s = NSMutableAttributedString(string: p.name, attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: tab])
        let grey: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: tab]
        if !p.summary.isEmpty { s.append(NSAttributedString(string: gap + p.summary, attributes: grey)) }
        s.append(NSAttributedString(string: "\t" + p.trigger, attributes: grey))
        return s
    }

    // --menu-render: the top bar's Snippets menu as it's styled, drawn in a light and a dark menu, to a PNG.
    static func render(to out: String) {
        guard let main = NSApp.mainMenu, let menu = main.items.first(where: { $0.title == "Snippets" })?.submenu else { print("no Snippets menu"); return }
        style(main)
        let font = NSFont.menuFont(ofSize: 0)
        var lines: [NSAttributedString] = []
        for item in menu.items where !item.isSeparatorItem {
            if let a = item.attributedTitle, a.length > 0, item.title.contains("\t") { lines.append(a); continue }
            let plain: String = (item.state == .on ? "✓ " : "") + item.title
            lines.append(NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        var width: CGFloat = 0
        for l in lines { width = max(width, l.size().width) }
        let rowH: CGFloat = 22, pad: CGFloat = 14
        let panelSize = NSSize(width: ceil(width) + pad * 2, height: CGFloat(lines.count) * rowH + 12)
        let total = NSSize(width: panelSize.width * 2 + 60, height: panelSize.height + 40)
        let image = NSImage(size: total)
        image.lockFocus()
        NSColor(white: 0.55, alpha: 1).setFill(); NSRect(origin: .zero, size: total).fill()
        for (n, look) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            NSAppearance(named: look)!.performAsCurrentDrawingAppearance {
                let origin = NSPoint(x: 20 + CGFloat(n) * (panelSize.width + 20), y: 20)
                let panel = NSRect(origin: origin, size: panelSize)
                (look == .aqua ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.17, alpha: 1)).setFill()
                NSBezierPath(roundedRect: panel, xRadius: 10, yRadius: 10).fill()
                for (k, l) in lines.enumerated() {
                    let y = panel.maxY - 6 - CGFloat(k + 1) * rowH + 3
                    l.draw(in: NSRect(x: panel.minX + pad, y: y, width: panelSize.width - pad * 2, height: rowH))
                }
            }
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) {
            try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
    }
}
