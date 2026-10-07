import AppKit
import SwiftUI

// Two floating panels (#262, Jason: "lets make the floating icon this"): the app's icon, always
// there above other apps, Penpal's own windows too; and the dock, which a click on the icon opens beside it and
// closes again. Neither takes focus, so a click leaves your cursor in Claude's message box. Drag the icon (or the
// open dock's header) to move both; the icon's place is kept. Settings › General › Floating icon turns it off:
// the macOS Dock icon and the menu bar still open the dock.
@MainActor
final class Overlay: ObservableObject {
    static let tabSize = NSSize(width: 36, height: 44)
    // Collapsed, it's the app's own icon at the macOS Dock's icon size (#255, Jason: "make our icons EXACTLY
    // like our dock versions? same size, same rounded edges"), following a change in System Settings.
    @Published var iconSize = DockTile.size

    @Published var expanded = UserDefaults.standard.object(forKey: "dock.expanded") as? Bool ?? true {  // open on a first launch
        didSet { UserDefaults.standard.set(expanded, forKey: "dock.expanded") }
    }
    // Where Search, New and Window sit (#301, Jason: "can you add a settings option? where i can view with the 3 small
    // icons above 'highlight'?"): under the header like a toolbar, or under Highlight. Above is the default (#303, Jason:
    // "ok that looks pretty good, lets save it"); only an unset key gets it, so a Below someone picked stays Below.
    @Published var rowAbove = UserDefaults.standard.object(forKey: "dock.rowAbove") as? Bool ?? true {
        didSet { UserDefaults.standard.set(rowAbove, forKey: "dock.rowAbove") }
    }
    @Published var gridHeight: CGFloat = 600   // the open dock's full height, measured; it scrolls past the screen's
    @Published var visible = true { didSet { showOrHide() } }
    @Published var iconOn = UserDefaults.standard.object(forKey: "overlay.icon") as? Bool ?? true {
        didSet { UserDefaults.standard.set(iconOn, forKey: "overlay.icon"); showOrHide(); relayout() }
    }
    // Pinned: the dock rides on the right edge of Claude's window, like a game overlay; it stays
    // shown when Claude goes behind (#282). A drag while pinned moves it relative
    // to that edge. Off: the dock floats where you left it.
    @Published var pinned = UserDefaults.standard.bool(forKey: "overlay.pin") {
        didSet {
            UserDefaults.standard.set(pinned, forKey: "overlay.pin")
            if pinned { adoptCurrentHeight() }
            pinned ? startPin() : stopPin()
        }
    }
    static let claudeBundle = "com.anthropic.claudefordesktop"
    private var pinTimer: Timer?
    private var claudeFrame: NSRect?   // Claude's front window, Cocoa coordinates
    // Make room (a trial, Settings → Features): Claude's width before Kite narrowed it, and the
    // frame Kite set. A different frame later means you resized it yourself: yours wins.
    private var madeRoom: (width: CGFloat, set: NSRect)?
    private static let roomGap: CGFloat = 8
    private static let minClaudeWidth: CGFloat = 900  // its sidebar plus a usable chat
    private var pinOffset: NSPoint = UserDefaults.standard.string(forKey: "overlay.pinOffset").map(NSPointFromString)
        ?? NSPoint(x: Overlay.tabSize.width + 6, y: -72)  // the tab's top-right, from the window's top-right corner

    let lenses: LensStore
    private var panel: NSPanel?      // the dock
    private var iconPanel: NSPanel?  // the floating icon

    // The icon's top-right corner in screen coordinates (kept as overlayAnchor, the corner the old one-panel
    // dock hung from, so the icon starts where it was).
    private(set) var iconAnchor: NSPoint
    // The open dock's top-right corner: its own place, or on Claude's edge while pinned.
    private(set) var anchor: NSPoint
    // The dock's own place (#269, Jason: "the floating icon and the window be detached"), kept as dock.anchor.
    // None until it first opens: then it opens beside the icon, and stays where you drag it from there.
    private var dockPlace: NSPoint? = UserDefaults.standard.string(forKey: "dock.anchor").map(NSPointFromString)
    // The app that had focus before Penpal took it with a click on the dock, for focus back when the dock hides.
    private var focusBefore: NSRunningApplication?
    // Where the current drag began, and whether it moves the icon (else the pinned dock). One at a time.
    var dragStart: (mouse: NSPoint, anchor: NSPoint, icon: Bool)?

    // Built on the next run loop turn: making a hosting view while SwiftUI is still
    // building the app's scenes crashes AttributeGraph.
    static private(set) weak var current: Overlay?

    // live: false is a picture of the dock (--render dock): no panel, no link to Claude's window.
    init(lenses: LensStore, live: Bool = true) {
        self.lenses = lenses
        let saved = UserDefaults.standard.string(forKey: "overlayAnchor").map(NSPointFromString)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        iconAnchor = saved ?? NSPoint(x: screen.maxX - 8, y: screen.midY + Self.tabSize.height / 2 + Flavor.dockNudge)
        anchor = iconAnchor
        guard live else { return }
        Overlay.current = self
        // Which is on top among Penpal's own (#283): the dock, the icon, or a window of its own (Enhance, Settings,
        // History…), whichever you touched last. A click or the start of a drag counts, and so does a window opening.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.settleLevel() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let w = note.object as? NSWindow
            MainActor.assumeIsolated { if let w { self.became(key: w) } }
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
            nonisolated(unsafe) let w = e.window
            MainActor.assumeIsolated { if let w { self.touched(w) } }
            return e
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in  // the Dock's size changed in System Settings
            MainActor.assumeIsolated {
                let s = DockTile.size
                guard abs(s - self.iconSize) > 0.5 else { return }
                self.iconSize = s
                self.iconPanel?.contentView?.layoutSubtreeIfNeeded(); self.relayout()
            }
        }
        DispatchQueue.main.async {
            self.makePanel()
            if self.pinned { self.startPin() }
            // A feature switched on or off: the dock re-lays out (tiles come and go).
            NotificationCenter.default.addObserver(forName: Features.changedNote, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    self.panel?.contentView?.layoutSubtreeIfNeeded()
                    self.relayout()
                    DispatchQueue.main.async { self.relayout() }
                }
            }
        }
    }

    // The dock's frame on screen while it's showing (with the icon's), so other windows can stop at its edge.
    var shownFrame: NSRect? {
        let shown = [panel, iconPanel].compactMap { $0 }.filter(\.isVisible).map(\.frame)
        return shown.isEmpty ? nil : shown.dropFirst().reduce(shown[0]) { $0.union($1) }
    }

    private var iconShows: Bool { visible && iconOn }
    // Shown or hidden only by you (#282, Jason: "it only shows and hides every now and then like when i open settings,
    // it hides can we remove this hide and show thing"): not by Penpal going in or out of front, not by its own windows,
    // not by Claude's going behind while pinned (pinned, it rides Claude's edge and stays).
    private var dockShows: Bool { visible && expanded }
    private func showOrHide() {
        if let iconPanel { if iconShows { iconPanel.orderFrontRegardless() } else { iconPanel.orderOut(nil) } }
        if let panel { if dockShows { panel.orderFrontRegardless() } else { panel.orderOut(nil) } }
    }

    // Open or closed, for the menu bar and Settings (the icon has its own switch).
    var dockOpen: Bool {
        get { visible && expanded }
        set { if newValue { visible = true }; if newValue != expanded { toggle() } }
    }

    // MARK: pinned to Claude

    private func startPin() {
        stopPin()
        pinTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in MainActor.assumeIsolated { self.pinTick() } }
        pinTick()
        Log.line("dock pinned to Claude")
    }

    private func stopPin() {
        pinTimer?.invalidate()
        pinTimer = nil
        giveRoomBack()
        claudeFrame = nil
        showOrHide()
        relayout()
    }

    // Reads Claude's front window and hangs the dock off its right edge. It stays shown either way (#282).
    private func pinTick() {
        let claude = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundle).first
        let frame = claude.flatMap { Self.frontWindowFrame($0.processIdentifier) }
        if Features.on(.pin), let frame {
            let room = Features.on(.makeRoom)
            if room, let pid = claude?.processIdentifier { makeRoom(frame, pid: pid) } else if !room { giveRoomBack() }
            // Open with Make room on, the dock sits beside Claude's edge instead of over it.
            let a = Self.pinnedAnchor(claude: frame, offset: pinOffset, panel: panelSize, room: room && expanded)
            if frame != claudeFrame || a != anchor {
                claudeFrame = frame
                anchor = a
                relayout()
            }
        }
    }

    private var panelWidth: CGFloat { panel?.contentView?.fittingSize.width ?? 0 }
    private var panelSize: CGSize { panel?.contentView?.fittingSize ?? .zero }

    // Where the pinned dock's top-right corner goes: on Claude's right edge (beside it with Make room),
    // at its own height along that edge (offset from Claude's top), kept within Claude's height.
    // The screen clamp comes after, in relayout.
    static func pinnedAnchor(claude f: NSRect, offset: NSPoint, panel: CGSize, room: Bool) -> NSPoint {
        let x = room ? f.maxX + roomGap + panel.width : f.maxX + offset.x
        let top = f.maxY, lowest = min(top, f.minY + panel.height)  // its bottom no lower than Claude's
        return NSPoint(x: x, y: min(max(top + offset.y, lowest), top))
    }

    // Pinning keeps the dock where it is up and down: the offset is measured from Claude's top now.
    private func adoptCurrentHeight() {
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundle).first,
              let f = Self.frontWindowFrame(claude.processIdentifier) else { return }
        pinOffset.y = min(0, max(anchor.y - f.maxY, f.minY + panelSize.height - f.maxY))
        UserDefaults.standard.set(NSStringFromPoint(pinOffset), forKey: "overlay.pinOffset")
    }

    // With the dock open and no space left beside Claude on the screen, narrow Claude by just
    // enough (never below minClaudeWidth). Closed again, Claude gets its width back, unless you
    // resized it in the meantime.
    private func makeRoom(_ frame: NSRect, pid: pid_t) {
        if let r = madeRoom, abs(frame.width - r.set.width) > 2 || abs(frame.minX - r.set.minX) > 2 {
            madeRoom = nil  // you changed it: that's the size now
            return
        }
        // Folded, the room stays: giving it back on every fold and taking it again on every open shoved Claude's
        // window back and forth (#258, Jason: "a bit of friction"; 208 pt each way seen). It goes back on unpin.
        guard expanded else { return }
        guard madeRoom == nil else { return }
        let screen = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let over = frame.maxX + Self.roomGap + panelWidth - screen.maxX
        guard over > 1 else { return }
        let width = frame.width - over
        guard width >= Self.minClaudeWidth else { return }  // too narrow: the dock stays over it, as before
        if Self.setWindowWidth(pid, width) {
            madeRoom = (frame.width, NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height))
            Log.line("make room: Claude \(Int(frame.width)) → \(Int(width)) pt")
        }
    }

    private func giveRoomBack() {
        guard let r = madeRoom else { return }
        madeRoom = nil
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeBundle).first,
              let now = Self.frontWindowFrame(claude.processIdentifier), abs(now.width - r.set.width) <= 2 else { return }
        _ = Self.setWindowWidth(claude.processIdentifier, r.width)
        Log.line("make room: Claude back to \(Int(r.width)) pt")
    }

    private static func mainWindow(_ pid: pid_t) -> AXUIElement? {
        var v: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        if AXUIElementCopyAttributeValue(app, "AXMainWindow" as CFString, &v) != .success || v == nil {
            AXUIElementCopyAttributeValue(app, "AXFocusedWindow" as CFString, &v)
        }
        return v.map { $0 as! AXUIElement }
    }

    // Claude's window width through Accessibility, the way window managers do it; the left edge stays put.
    private static func setWindowWidth(_ pid: pid_t, _ width: CGFloat) -> Bool {
        guard let win = mainWindow(pid) else { return false }
        var sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, "AXSize" as CFString, &sv) == .success, let sv else { return false }
        var size = CGSize.zero
        guard AXValueGetValue(sv as! AXValue, .cgSize, &size) else { return false }
        size.width = width.rounded()
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(win, "AXSize" as CFString, value) == .success
    }

    // The app's main window, in Cocoa screen coordinates (origin bottom-left of the main screen).
    private static func frontWindowFrame(_ pid: pid_t) -> NSRect? {
        func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(e, n as CFString, &v)
            return v
        }
        let app = AXUIElementCreateApplication(pid)
        guard let w = (attr(app, "AXMainWindow") ?? attr(app, "AXFocusedWindow")) else { return nil }
        let win = w as! AXUIElement
        if (attr(win, "AXMinimized") as? Bool) == true { return nil }
        guard let pv = attr(win, "AXPosition"), let sv = attr(win, "AXSize") else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s), s.width > 0 else { return nil }
        let screenH = NSScreen.screens.first?.frame.height ?? 0  // AX is top-left based; Cocoa bottom-left
        return NSRect(x: p.x, y: screenH - p.y - s.height, width: s.width, height: s.height)
    }

    // The dock and the icon float above other apps and never hide on their own (#282). While Penpal is in front, its
    // ordinary windows (Settings, History) float at their level too, so the one you touched last is on top (#283, Jason:
    // "make the enhance OR the penpal dock be the top level window? depending on which one is active or focused?"); with
    // another app in front they're ordinary windows again, under the dock. Enhance floats always (#244) and stays so.
    private var touchedLast: NSWindow?
    private var dockTouch: (at: Date, open: Set<ObjectIdentifier>)?  // a dock or icon click, and the windows open then
    private var raised = Set<ObjectIdentifier>()  // ordinary windows lifted to floating while Penpal is in front
    fileprivate var activeForCheck: Bool?  // --order-check: the activation a real click brings, which a test can't
    private func ours(_ w: NSWindow) -> Bool { !(w is NSPanel) && w.styleMask.contains(.titled) && w.isVisible }
    private func settleLevel() {
        let active = activeForCheck ?? NSApp.isActive
        for w in NSApp.windows where !(w is NSPanel) && w.styleMask.contains(.titled) {
            let id = ObjectIdentifier(w)
            if active, w.isVisible, w.level == .normal { w.level = .floating; raised.insert(id) }
            else if !active, raised.contains(id) { w.level = .normal; raised.remove(id) }
        }
        for p in [panel, iconPanel].compactMap({ $0 }) where p.level != .floating { p.level = .floating }
        if active, let t = touchedLast, t.isVisible { t.orderFrontRegardless() }
    }
    // A click or a drag's start on the dock, the icon or a window of Penpal's: that one on top, now and again once the
    // activation the click brings has settled.
    private func touched(_ w: NSWindow) {
        guard w === panel || w === iconPanel || ours(w) else { return }  // a menu, a ring, an alert: not ours to order
        if w === panel || w === iconPanel { dockTouch = (.now, Set(NSApp.windows.filter(ours).map(ObjectIdentifier.init))) }
        touchedLast = w
        settleLevel()
        w.orderFrontRegardless()
        DispatchQueue.main.async { if self.touchedLast === w { w.orderFrontRegardless() } }
    }
    // A window of Penpal's taking focus counts as touching it (Settings opening from the gear), except the focus macOS
    // hands back to a window already open when a click on the dock brings Penpal in front.
    private func became(key w: NSWindow) {
        guard ours(w) else { return }
        if let t = dockTouch, Date.now.timeIntervalSince(t.at) < 0.5, t.open.contains(ObjectIdentifier(w)) { return settleLevel() }
        touchedLast = w
        settleLevel()
    }

    private func makePanel() {
        Shortcuts.install()  // after launch, with the first panel
        Appearance.shared.apply()
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.hidesOnDeactivate = false  // a panel hides when its app leaves the front, by default (#282: since a dock click
                                         // makes Penpal active, switching back to Claude hid the dock and the icon)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let host = ClickThroughHostingView(rootView: OverlayView(overlay: self, highlighter: .shared, agents: .shared, voiceAgent: .shared))
        host.onMouseDown = { [weak self] in self?.dockClicked() }  // the dock's clicks bring Penpal in front; the icon's don't
        // Kite sizes and places the panel itself, in one step. Left to SwiftUI, the panel first
        // grew rightward from its old corner, then jumped back to the anchor a moment later.
        host.sizingOptions = [.intrinsicContentSize]  // measured, but no min/max size pushed onto the window
        host.onResize = { [weak self] in Task { @MainActor in self?.relayout() } }
        panel.contentView = host  // OverlayView(overlay:highlighter:agents:voiceAgent:) below
        self.panel = panel
        // The icon: no shadow (the macOS Dock adds none; the artwork has its own), always floating.
        let icon = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        icon.level = .floating
        icon.hidesOnDeactivate = false
        icon.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        icon.backgroundColor = .clear
        icon.hasShadow = false
        let iconHost = ClickThroughHostingView(rootView: FloatingIconView(overlay: self, agents: .shared, voiceAgent: .shared))
        iconHost.sizingOptions = [.intrinsicContentSize]
        iconHost.onResize = { [weak self] in Task { @MainActor in self?.relayout() } }
        icon.contentView = iconHost
        iconPanel = icon
        relayout()
        showOrHide()
    }

    func toggle() {
        // Hidden while Penpal has focus (it took it with a click on the dock): focus back to the app that had it.
        if expanded, NSApp.isActive, let back = focusBefore ?? OtherApp.last, !back.isTerminated {
            back.activate()
            focusBefore = nil
        }
        expanded.toggle()
        if expanded && !visible { visible = true }
        panel?.contentView?.layoutSubtreeIfNeeded()  // let SwiftUI apply the change, so the new size is known
        if pinned { pinTick() }  // make room (or give it back) at once, not on the next tick
        relayout()
        showOrHide()
        DispatchQueue.main.async { self.relayout() }  // no-op unless the size settled late
    }

    // A drag starts: the icon by the icon, the dock by its header. Each moves alone (#269).
    func beginDrag(icon: Bool) {
        dragStart = (NSEvent.mouseLocation, icon ? iconAnchor : anchor, icon)
    }

    // Pinned and pulled sideways off Claude's edge: unpinned where it is, and the rest of the drag moves it.
    func unpinByDrag() {
        if let f = panel?.frame { dockPlace = NSPoint(x: f.maxX, y: f.maxY) }
        pinned = false
        dragStart = (NSEvent.mouseLocation, dockPlace ?? anchor, false)
        Log.line("dock unpinned by a drag")
    }

    // A click on the dock (its header, background or any tile) brings Penpal in front, with its menus in the menu
    // bar (#269: "im not able to see penpal selected in the menu bar"). What the tile does for Claude brings
    // Claude forward again as it runs (pasting, Claude's menu commands).
    func dockClicked() {
        guard !NSApp.isActive else { return }
        focusBefore = NSWorkspace.shared.frontmostApplication.flatMap { $0 == NSRunningApplication.current ? nil : $0 }
        NSApp.activate()
    }

    func moveIcon(to point: NSPoint) {
        iconAnchor = point
        relayout()
    }

    func move(to point: NSPoint) {
        anchor = point
        if !pinned { dockPlace = point }
        // Pinned: it slides up and down Claude's edge (its side stays put).
        if pinned, let f = claudeFrame {
            pinOffset.y = point.y - f.maxY
            anchor = Self.pinnedAnchor(claude: f, offset: pinOffset, panel: panelSize, room: Features.on(.makeRoom) && expanded)
            pinOffset.y = anchor.y - f.maxY  // kept within Claude's height, so it doesn't drift past it
        }
        relayout()
    }

    func saveAnchor() {
        if pinned { UserDefaults.standard.set(NSStringFromPoint(pinOffset), forKey: "overlay.pinOffset") }
        else { saveDockPlace() }
    }
    private func saveDockPlace() {
        if let p = dockPlace { UserDefaults.standard.set(NSStringFromPoint(p), forKey: "dock.anchor") }
    }
    func saveIconAnchor() { UserDefaults.standard.set(NSStringFromPoint(iconAnchor), forKey: "overlayAnchor") }

    // The see-through border around an app icon's tile (macOS's icon grid: 100 of 1024), and the gap the
    // dock keeps from the tile.
    static func iconInset(_ size: CGFloat) -> CGFloat { (size * 100 / 1024).rounded() }
    static let gap: CGFloat = 6

    // The icon at its anchor, then the dock beside it (or on Claude's edge while pinned), each kept on screen.
    private func relayout() {
        var iconFrame: NSRect?
        if let iconPanel, let view = iconPanel.contentView {
            let size = view.fittingSize
            let f = Self.onScreen(NSRect(x: iconAnchor.x - size.width, y: iconAnchor.y - size.height, width: size.width, height: size.height), near: iconAnchor)
            // A place saved off this screen (a bigger display, the old dock's corner) is brought in and saved where it
            // is now, so the icon doesn't stay stuck to the wall. No extra margin: the icon's
            // own see-through border keeps the tile off the edge.
            if dragStart == nil, NSPoint(x: f.maxX, y: f.maxY) != iconAnchor {
                iconAnchor = NSPoint(x: f.maxX, y: f.maxY); saveIconAnchor()
            }
            if f != iconPanel.frame { iconPanel.setFrame(f, display: true) }
            iconFrame = f
        }
        guard let panel, let view = panel.contentView else { return }
        let size = view.fittingSize
        if !pinned {
            if let p = dockPlace { anchor = p }
            else if expanded, size.width > 20 {
                // Its first time open: beside the icon, its top level with the icon's tile, on the left, or on the right
                // where the left has no room. From then on it keeps its own place.
                let icon = iconFrame ?? NSRect(x: iconAnchor.x - iconSize, y: iconAnchor.y - iconSize, width: iconSize, height: iconSize)
                let inset = Self.iconInset(icon.width)
                let screen = Self.screen(at: iconAnchor)
                let left = icon.minX + inset - Self.gap
                anchor = NSPoint(x: left - size.width >= screen.minX ? left : icon.maxX - inset + Self.gap + size.width, y: icon.maxY - inset)
                dockPlace = anchor; saveDockPlace()
            }
        }
        let frame = Self.onScreen(NSRect(x: anchor.x - size.width, y: anchor.y - size.height, width: size.width, height: size.height), near: anchor)
        // Its place off this screen (a bigger display): brought in and saved where it is now, as the icon's is.
        if !pinned, expanded, dragStart == nil, size.width > 20, dockPlace != nil, NSPoint(x: frame.maxX, y: frame.maxY) != dockPlace {
            dockPlace = NSPoint(x: frame.maxX, y: frame.maxY); anchor = dockPlace!; saveDockPlace()
        }
        if frame != panel.frame { panel.setFrame(frame, display: true); panel.invalidateShadow() }
    }

    // The screen a top-right corner is on. The corner sits on the screen's own right or top edge when the icon is
    // flush with it, which a frame doesn't count as inside, so the point a hair inside is looked up; without that
    // it fell back to the main screen, another display when one is plugged in (#269).
    static func screen(at corner: NSPoint) -> NSRect {
        let p = NSPoint(x: corner.x - 1, y: corner.y - 1)
        return (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    private static func onScreen(_ f: NSRect, near p: NSPoint) -> NSRect {
        let screen = Self.screen(at: p)
        var f = f
        f.origin.x = min(max(f.minX, screen.minX), screen.maxX - f.width)
        f.origin.y = min(max(f.minY, screen.minY), screen.maxY - f.height)
        return f
    }
}

// Drag to move the panel; a click without movement runs onTap. Uses screen coordinates,
// because the view's own coordinates shift as the window moves under the mouse.
private struct DragHandle<Label: View>: View {
    let overlay: Overlay
    var icon = false  // the floating icon (else the open dock's header)
    var onTap: () -> Void = {}
    @ViewBuilder let label: Label

    var body: some View {
        label
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { _ in
                    let mouse = NSEvent.mouseLocation
                    if overlay.dragStart == nil { overlay.beginDrag(icon: icon) }
                    guard var start = overlay.dragStart else { return }
                    // Dragged clearly away from Claude's edge (sideways) while pinned: unpinned, and it stays
                    // where you put it. Up and down keeps it pinned, sliding along the edge.
                    if !start.icon, overlay.pinned, abs(mouse.x - start.mouse.x) > 40 {
                        overlay.unpinByDrag()
                        guard let s = overlay.dragStart else { return }
                        start = s
                    }
                    let to = NSPoint(x: start.anchor.x + mouse.x - start.mouse.x, y: start.anchor.y + mouse.y - start.mouse.y)
                    if start.icon { overlay.moveIcon(to: to) } else { overlay.move(to: to) }
                }
                .onEnded { _ in
                    defer { overlay.dragStart = nil }
                    guard let start = overlay.dragStart else { return }
                    let mouse = NSEvent.mouseLocation
                    if hypot(mouse.x - start.mouse.x, mouse.y - start.mouse.y) < 3 {
                        if start.icon { overlay.moveIcon(to: start.anchor) } else { overlay.move(to: start.anchor) }  // a click, not a drag
                        onTap()
                    } else if start.icon {
                        overlay.saveIconAnchor()
                    } else {
                        overlay.saveAnchor()
                    }
                })
    }
}

// Buttons work on the first click, even though the panel is never the active window.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    var onResize: (() -> Void)?
    var onMouseDown: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        super.mouseDown(with: event)
    }
    // The contents changed size (a tile, the unread row, the Board button): the panel follows at once.
    // Without this it kept its old size until the next open or drag, and cut off the top and bottom.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onResize?()
    }
}

private struct GridHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// The floating icon, at the macOS Dock's size: drag it anywhere (the place is kept); a click opens or closes the
// dock beside it, as the macOS Dock icon does too.
private struct FloatingIconView: View {
    @ObservedObject var overlay: Overlay
    @ObservedObject var agents: AgentStore
    @ObservedObject var voiceAgent: VoiceAgent

    var body: some View {
        DragHandle(overlay: overlay, icon: true, onTap: overlay.toggle) {
            DockIcon(size: overlay.iconSize, phase: voiceAgent.phase,
                     unread: Flavor.current.has(.chat) ? agents.unreadTotal : 0,  // a badge only in the app that lists them
                     working: Flavor.current.has(.chat) && agents.anyWorking)
        }
        .help(tip)
        .fixedSize()
    }
    private var tip: String {
        let base = (overlay.expanded ? "Close" : "Open") + " the dock. Drag to move"
        return base
    }
}

private struct OverlayView: View {
    @ObservedObject var overlay: Overlay
    @ObservedObject var highlighter: Highlighter
    @ObservedObject var agents: AgentStore
    @ObservedObject var voiceAgent: VoiceAgent
    @ObservedObject var features = Features.shared

    var body: some View {
        Group {
            // The icon is its own panel now (FloatingIconView); this is the open dock only.
            if overlay.expanded { grid.background(DockBackground()) }
        }
        .fixedSize()
    }

    // The chevron sits in a tab-sized box in the top-right corner, where the tab was.
    // Taller than the screen (many tiles on a small display): it scrolls instead of being cut off.
    private var grid: some View {
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) - 16
        return ScrollView(.vertical, showsIndicators: overlay.gridHeight > maxH) {
            gridContent.background(GeometryReader { g in Color.clear.preference(key: GridHeight.self, value: g.size.height) })
        }
        .frame(height: min(max(overlay.gridHeight, 60), maxH))
        .onPreferenceChange(GridHeight.self) { h in
            MainActor.assumeIsolated { if abs(overlay.gridHeight - h) > 0.5 { overlay.gridHeight = h } }
        }
    }

    // Claude's own session commands, one click each (the same menu items as ⌘N, ⇧⌘T, ⇧⌘K).
    private var sessionsRow: some View {
        HStack(spacing: 8) {
            SessionButton(icon: "magnifyingglass", label: "Search", menu: "Search…", keys: "⇧⌘K")
            SessionButton(icon: "plus.bubble", label: "New", menu: "New Session", keys: "⌘N", tint: .green)
            SessionButton(icon: "macwindow.badge.plus", label: "Window", menu: "New Session in New Window", keys: "no shortcut in Claude", tint: .teal)
                .contextMenu {
                    ForEach(overlay.lenses.names(), id: \.self) { name in
                        Button("New window with \(name)") { overlay.lenses.openInNewWindow(name) }
                    }
                }
        }
    }

    // The 176-point column of cards sits in the middle of the panel (the header row makes the panel
    // wider than the column; it used to sit at the left with all the spare room on the right).
    private var gridContent: some View {
        VStack(alignment: .center, spacing: 0) {
            // The header holds only what's used while it's open (#258, Jason: "feels a bit crowded here, could we
            // move some of it to the menu bar?"): the app's icon, which folds it back into the floating icon (the
            // one toggle, both ways), the name to drag it by, and Pin. Commands, History, Usage and Settings are in
            // the menu bar icon's menu and the app menu.
            HStack(spacing: 0) {
                DragHandle(overlay: overlay, onTap: overlay.toggle) {
                    DockIcon(size: 24).padding(.leading, 12).padding(.trailing, 6)
                        .frame(height: Overlay.tabSize.height)
                }
                .help("Close the dock. Drag to move")
                // A click on the name brings Penpal in front, with its own menus in the top menu bar (#268); a drag
                // moves the dock. The tiles never take focus from Claude.
                DragHandle(overlay: overlay, onTap: { NSApp.activate() }) {
                    Text("\(AppName.shown)").font(.headline)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                // Settings (Jason: "i think settings is a core part, can you add it to the left of the pin on the dock?"):
                // opens Settings, Penpal in front.
                HeaderButton(id: "settings", help: "Settings") { SettingsWindow.open() } label: {
                    Image(systemName: "gearshape").font(.system(size: 13))
                }
                .padding(.trailing, Features.on(.pin) ? 0 : 6)
                // Pin: the dock rides on Claude's window. Click to unpin (or drag the dock away); again to re-pin.
                if Features.on(.pin) {
                    HeaderButton(id: "pin", help: overlay.pinned ? "Pinned to Claude's window. Click, or drag the dock away, to unpin" : "Pin to Claude's window: it follows Claude and makes room beside it") {
                        overlay.pinned.toggle()
                    } label: {
                        Image(systemName: overlay.pinned ? "pin.fill" : "pin").font(.system(size: 13))
                            .rotationEffect(.degrees(overlay.pinned ? 0 : 45))
                    }
                    .padding(.trailing, 6)
                }
            }
            .frame(height: Overlay.tabSize.height)
            // Above Highlight (#301): right under the header, a toolbar, the tiles' own 8-point gap below it.
            if Features.on(.sessions), overlay.rowAbove { sessionsRow.padding(.horizontal, 12).padding(.bottom, 8) }
            if Features.on(.capture) {
                ScreenshotButton(highlighter: highlighter)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            // Under Highlight, as it always was.
            if Features.on(.sessions), !overlay.rowAbove { sessionsRow.padding([.horizontal, .bottom], 12) }
            // Lenses, one row: what your agents talk like now, and a menu of what each lens can do.
            if Features.on(.lenses) {
                LensRow(overlay: overlay, agents: agents)
                    .padding([.horizontal, .bottom], 12)
            }
            // Below this line, Kite runs Claude for you (your own claude): the guide, Talk to Kite, agents.
            // Above it, nothing does: those tools only help you use the Claude app.
            if Features.on(.guide) || Enhance.available || Features.on(.voice) || (!agents.agents.isEmpty && Features.on(.chat)) {
                // Penpal has no agents (#247); its section is "Magic", honest in its tooltip (#258, Jason: "maybe here we call it magic").
                Text(Flavor.current == .penpal ? "Magic" : "Agents").font(.caption).foregroundStyle(.secondary).padding(.leading, 2)
                    .help(Flavor.current == .penpal ? "These use your Claude plan" : "")
                    .frame(width: 176, alignment: .leading).padding(.bottom, 4)
            }
            // Screen guide: Kite points at each step in the app you're in; you click.
            if Features.on(.guide) { Button { Guide.start() } label: {
                DockRow(icon: "hand.point.up.left.fill", color: .pink, title: "Guide me")
            }
            .buttonStyle(TilePress())
            .help("Guide me: step by step, in any app. Ask how to do something; \(AppName.shown) rings each thing to click")
            .padding(.horizontal, 12).padding(.bottom, 8) }
            // Enhance, the full width under Guide me and the same shape (#257, Jason: "enhance is pretty good, have it
            // take the full long lower tile"). Live status left the dock (#257: "get rid of live status"); its code stays.
            if Enhance.available { Button { Enhance.open() } label: {
                DockRow(icon: "wand.and.stars", color: Palette.enhance, title: "Enhance")
            }
            .buttonStyle(TilePress())
            .help("Enhance: turn a rough ask into a clear prompt. Write it rough, with pictures; your Claude rewrites it")
            .padding(.horizontal, 12).padding(.bottom, 8) }
            // Talk to Kite: hold the tile and speak; let go to send. Breathes while it thinks and talks.
            // Workbench (lite) or Workshop (full): the same app, with or without what runs Claude.
            // For trying both while building; a release build is one or the other.
            if !Features.isRelease, Flavor.isWorkshop {
                Picker("", selection: Binding(get: { Features.shared.jetpackPreview }, set: { Features.shared.jetpackPreview = $0 })) {
                    Text("Workbench").tag(true); Text("Workshop").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(width: 176)
                .help("Workbench: the lite version, nothing that runs Claude. Workshop: everything")
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }
}

// ◐ while an agent works; a red badge with the count when results are waiting to be read.
// The macOS Dock's icon size, in points (com.apple.dock tilesize; 64 when it was never changed).
enum DockTile {
    static var size: CGFloat {
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let n = (CFPreferencesCopyAppValue("tilesize" as CFString, "com.apple.dock" as CFString) as? NSNumber)?.doubleValue ?? 64
        return CGFloat(min(max(n, 16), 128))
    }
}

// The collapsed dock: the app's icon as the macOS Dock draws it (the icon file at the Dock's size, its own
// rounded shape, nothing around it), breathing while the voice agent listens, thinks or talks (with a glow
// in that colour; not in Penpal), and the Dock's red badge for unread results.
struct DockIcon: View {
    let size: CGFloat
    var phase: VoiceAgent.Phase = .idle
    var unread = 0
    var working = false
    var body: some View {
        Breathing(phase: phase) {
            Group {
                if let icon = NSApp.applicationIconImage { Image(nsImage: icon).resizable().interpolation(.high) }
                else { RoundedRectangle(cornerRadius: size * 0.22).fill(Color.gray) }
            }
            .frame(width: size, height: size)
            .shadow(color: phase == .idle ? .clear : Self.glow(phase).opacity(0.9), radius: size * 0.12)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: size * 0.2, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, size * 0.07)
                    .frame(minWidth: size * 0.32, minHeight: size * 0.32)
                    .background(Capsule().fill(Color(red: 1, green: 0.23, blue: 0.19)))
                    .offset(x: size * 0.02, y: size * 0.02)
                    .help("New results")
            } else if working {
                AgentDot(working: true, unread: 0).padding(size * 0.1)
            }
        }
    }
}

private struct AgentDot: View {
    let working: Bool
    let unread: Int
    var body: some View {
        if unread > 0 {
            UnreadBadge()
        } else if working {
            Circle().trim(from: 0, to: 0.5).fill(Color.accentColor).rotationEffect(.degrees(90))
                .background(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                .frame(width: 9, height: 9)
        }
    }
}


// A gentle breath (scale) while the voice agent works; still otherwise. Driven by the clock, so
// it stops the moment the phase goes idle (a repeat-forever animation never did).
extension DockIcon {
    static func glow(_ p: VoiceAgent.Phase) -> Color { .clear }
}

#if PENPAL_ONLY
// Penpal doesn't talk (#315): the dock's views take this in the voice agent's place, always idle.
@MainActor final class VoiceAgent: ObservableObject {
    static let shared = VoiceAgent()
    enum Phase { case idle, listening, thinking, speaking }
    let phase = Phase.idle
}
#endif

// Hover, for views on a toolchain without @State (#315: Penpal uses it too).
final class HoverState: ObservableObject { @Published var on = false }

struct Breathing<Content: View>: View {
    let phase: VoiceAgent.Phase
    @ViewBuilder let content: Content
    var body: some View {
        TimelineView(.animation(paused: phase == .idle)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let period = phase == .listening ? 1.2 : phase == .thinking ? 2.4 : 1.8
            let s = phase == .idle ? 1.0 : 1.0 + 0.06 * (0.5 + 0.5 * sin(t * 2 * .pi / period))
            content.scaleEffect(s)
        }
    }
}


// One of Claude's session menu items. Brings Claude forward and runs it; no typing.
// Said on the button for a moment when Claude has nothing to do for it (nothing to reopen).
final class SessionButtonState: ObservableObject {
    @Published var note: String?
}

private struct SessionButton: View {
    let icon, label, menu, keys: String
    var tint: Color? = nil  // nil: the plain glyph, no tile
    var idle = "Nothing to do"  // shown when Claude has the item greyed out
    @StateObject private var state = SessionButtonState()
    var body: some View {
        Button {
            if !CommandsModel.run(title: menu) {
                NSSound.beep()
                state.note = idle
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { state.note = nil }
            }
        } label: {
            VStack(spacing: 3) {
                if let tint, state.note == nil { IconTile(symbol: icon, color: tint, size: 22) }
                else { Image(systemName: state.note == nil ? icon : "nosign").font(.system(size: 16, weight: .medium)).frame(height: 22) }
                Text(state.note ?? label).font(.caption2).lineLimit(2).minimumScaleFactor(0.7).multilineTextAlignment(.center)
            }
            .frame(width: 53, height: 44)  // three fit the 176-point dock
            .dockTile(radius: 10, tint: tint)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(TilePress())
        .help("\(menu) in Claude (\(keys))")
    }
}

// A wide tile, one line (#258, Jason: "lets get rid of the subtitles here"): icon and name, the same size as
// Snippets, so the dock's wide tiles all look alike. What a subtitle said is in the tooltip.
private struct DockRow: View {
    let icon: String
    let color: Color
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            IconTile(symbol: icon, color: color, size: 26)
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12).padding(.trailing, 10)
        .frame(width: 176, height: 44)
        .dockTile(tint: color)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

// The camera: starts a screenshot in the mode picked in the menu bar.
private struct ScreenshotButton: View {
    @ObservedObject var highlighter: Highlighter
    @ObservedObject private var permissions = Permissions.shared
    private var hint: String? {
        let need = !permissions.screen ? "Highlight needs Screen Recording" : !permissions.accessibility ? "\(highlighter.keysLabel) and paste need \(Permissions.controlName)" : nil
        guard let need else { return nil }
        return need + (permissions.sentToSettings ? " · Turned on? Reopen" : " · Turn on")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
        Button { if permissions.screen { highlighter.startFromButton() } else { permissions.fix(.screen) } } label: {
            // "Highlight" (#258, Jason: "what to call this here if we remove the subtitle?"): what ⌃⌥ does, and not
            // a macOS screenshot. Its icon is the mode's; the mode's name is in the tooltip.
            DockRow(icon: highlighter.mode.icon, color: .blue, title: "Highlight")
        }
        .buttonStyle(TilePress())
        .help("Highlight into Claude: \(highlighter.mode.label.lowercased()) (or hold \(highlighter.keysLabel)). Change the mode in the menu bar")
        // What's not on yet, as a calm line (the button works anyway; only the keys and pasting need it).
        if let hint = hint {
            Button { permissions.sentToSettings ? Permissions.reopen() : permissions.fix(permissions.screen ? .accessibility : .screen) } label: {
                Text(hint).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain).frame(width: 176, alignment: .leading)
            .help(permissions.sentToSettings ? "Turned it on in System Settings? Click to reopen \(AppName.shown) so it counts" : "Opens System Settings")
        }
        }
    }
}

// One row instead of eight tiles. The menu shows every lens with three things to do with it:
// start a new Claude session that opens with it, paste it into the current session, or set it
// as how Kite's agents talk. A new session is opened through Claude's own File menu, and the
// lens is pasted; you still press Enter.
private struct LensRow: View {
    @ObservedObject var overlay: Overlay
    @ObservedObject var agents: AgentStore

    // The whole row opens the menu (#261, Jason: "can you make clicking the snippets button open the drop down
    // menu instead of the arrow icon?"). Just the icon and the name, like the other wide tiles ("lets remove
    // concise there and also remove the arrow"); how your Claude talks is the checkmark inside.
    var body: some View {
        Menu { items } label: {
            HStack(spacing: 8) {
                IconTile(symbol: "text.quote", color: Palette.snippets, size: 26)
                Text("Snippets").font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12).padding(.trailing, 10)
            .frame(width: 176, height: 44)
            .dockTile(tint: Palette.snippets)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            // One element, the whole row, as a Button is: for VoiceOver and for Guide me's rings.
            .accessibilityElement(children: .combine)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Paste a snippet into Claude")
    }

    // Just the snippets, each pasting into Claude, and the editor (#270, Jason: "I think this is a bit too
    // complicated"). How your Claude talks is in Settings › Snippets.
    @ViewBuilder private var items: some View {
        ForEach(overlay.lenses.names(), id: \.self) { name in
            Button { paste(name) } label: {
                Label(SnippetMenuStyle.title(name: name, summary: overlay.lenses.summary(name), trigger: overlay.lenses.abbreviation(name)),
                      systemImage: LensRow.icons[name] ?? "sparkles")
            }
        }
        Divider()
        Button("Edit snippets…") { LensWindow.open(overlay.lenses) }
    }

    static let icons = ["concise": "text.alignleft", "explain": "lightbulb", "learn": "graduationcap", "formal": "building.columns",
                        "plain": "text.bubble", "technical": "terminal", "friendly": "face.smiling", "candid": "exclamationmark.bubble",
                        "cat": "cat", "chill": "leaf", "home": "house", "romance": "heart",
                        "chinese": "character.book.closed.zh", "jason": "person", "work": "briefcase"]

    private func paste(_ name: String) {
        if let text = overlay.lenses.expansion(name) { Paster.pasteIntoClaude(text) }
    }
}


extension Overlay {
    // For checking the dock's layout with fewer tiles (KITE_TILES=3 with --render dock).
    static var tileLimit: Int { ProcessInfo.processInfo.environment["KITE_TILES"].flatMap(Int.init) ?? .max }
    // The open dock as a view, for --render dock.
    static func picture() -> AnyView {
        let o = Overlay(lenses: .locate(), live: false)
        o.expanded = true
        return AnyView(OverlayView(overlay: o, highlighter: .shared, agents: .shared, voiceAgent: .shared).fixedSize())
    }
}

// --time-dock: how long the dock takes to lay itself out when it opens and when it folds, offscreen with the
// real view (#258: "a bit of friction"), 10 times each, and whether its panel takes the first click.
@MainActor
func timeDock() {
    _ = NSApplication.shared
    AgentStore.shared.refresh()
    let o = Overlay(lenses: .locate(), live: false)
    o.expanded = false
    let host = NSHostingView(rootView: OverlayView(overlay: o, highlighter: .shared, agents: .shared, voiceAgent: .shared))
    let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 300, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = host
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    var open: [Double] = [], close: [Double] = []
    for _ in 0..<10 {
        for expand in [true, false] {
            let t0 = Date.now
            o.expanded = expand
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            (expand ? { open.append($0) } : { close.append($0) })(Date.now.timeIntervalSince(t0) * 1000)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
    func line(_ v: [Double]) -> String { let s = v.sorted(); return String(format: "median %.1f ms, worst %.1f ms (first %.1f ms)", s[s.count / 2], s.last!, v.first!) }
    print("open:  " + line(open))
    print("close: " + line(close))
    print("first click taken while another app is in front: \(ClickThroughHostingView(rootView: EmptyView()).acceptsFirstMouse(for: nil))")
}

// --float-check (#262, #269): the floating icon and the dock on the live panels, through the same calls a click and a
// drag make (toggle, moveIcon, move, the dock's click), with the settings they touch put back after, and which app
// the menu bar shows, read from macOS. Prints a line per check.
extension Overlay {
    func floatCheck() {
        let keys = ["overlayAnchor", "dock.anchor", "dock.expanded", "overlay.icon", "overlay.pin", "overlay.pinOffset"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  (\(detail))")); if !ok { failed += 1 }
        }
        func r(_ f: NSRect?) -> String { f.map { "x \(Int($0.minX))…\(Int($0.maxX)), y \(Int($0.minY))…\(Int($0.maxY))" } ?? "none" }
        func settle(_ s: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        guard let icon = iconPanel, let dock = panel else { print("FAIL no panels"); return }
        let screen = Self.screen(at: iconAnchor)
        let wasPinned = pinned, iconBefore = iconAnchor
        if pinned { pinned = false }  // the free dock; pinned, it rides Claude's edge as before
        if expanded { toggle() }
        dockPlace = nil; UserDefaults.standard.removeObject(forKey: "dock.anchor")  // as on a first open
        check("closed: icon shown, dock hidden", icon.isVisible && !dock.isVisible, "icon " + r(icon.frame))
        toggle()  // the icon's click
        let inset = Self.iconInset(icon.frame.width)
        check("first open: beside the icon", dock.isVisible && abs(dock.frame.maxX - (icon.frame.minX + inset - Self.gap)) < 1, "icon " + r(icon.frame) + ", dock " + r(dock.frame))
        check("its place is kept from then on", UserDefaults.standard.string(forKey: "dock.anchor") != nil)
        // Detached: the icon moves alone.
        let dockFrame = dock.frame
        moveIcon(to: NSPoint(x: screen.minX + 200, y: screen.midY)); saveIconAnchor()
        check("dragging the icon leaves the dock where it is", dock.frame == dockFrame, "icon " + r(icon.frame) + ", dock " + r(dock.frame))
        // The dock moves alone, by its header.
        let iconFrame = icon.frame
        beginDrag(icon: false); move(to: NSPoint(x: screen.midX + 150, y: screen.maxY - 40)); dragStart = nil; saveAnchor()
        let kept = UserDefaults.standard.string(forKey: "dock.anchor").map(NSPointFromString)
        check("dragging the dock leaves the icon where it is", icon.frame == iconFrame && abs(dock.frame.maxX - (screen.midX + 150)) < 1, "dock " + r(dock.frame))
        check("the dock's place is saved", kept == NSPoint(x: dock.frame.maxX, y: dock.frame.maxY), kept.map { NSStringFromPoint($0) } ?? "nil")
        toggle(); toggle()  // the icon's click: closed, then open again
        check("the icon opens it at its own place, not beside the icon", dock.isVisible && kept == NSPoint(x: dock.frame.maxX, y: dock.frame.maxY), "dock " + r(dock.frame))
        // A place off this screen: brought in and saved.
        move(to: NSPoint(x: screen.maxX + 400, y: screen.maxY + 400)); relayout()
        let fixed = UserDefaults.standard.string(forKey: "dock.anchor").map(NSPointFromString) ?? .zero
        check("an off-screen dock place is brought in and saved", dock.frame.maxX <= screen.maxX && dock.frame.maxY <= screen.maxY && fixed == NSPoint(x: dock.frame.maxX, y: dock.frame.maxY),
              "saved \(NSStringFromPoint(fixed)), dock " + r(dock.frame))
        // Focus, as the menu bar shows it.
        let before = NSWorkspace.shared.frontmostApplication
        if NSApp.isActive, let other = OtherApp.last { other.activate(); settle(0.6) }
        let owner0 = NSWorkspace.shared.menuBarOwningApplication
        dockClicked()  // a click anywhere on the dock
        settle(0.8)
        let owner1 = NSWorkspace.shared.menuBarOwningApplication
        // macOS (14+) lets an app take focus only from a real user event: this one counts only when the check runs from a click.
        if owner1 == NSRunningApplication.current { check("a click on the dock: Penpal's menus in the menu bar", true) }
        else { print("NOTE a click on the dock asked for focus; macOS gives it only for a real click, so it's checked live (menu bar: \(owner1?.localizedName ?? "nobody"))") }
        toggle()  // the icon's click hides it
        settle(0.8)
        let owner2 = NSWorkspace.shared.menuBarOwningApplication
        check("hidden by the icon: the menu bar is the app's that had it", !dock.isVisible && owner2 != nil && owner2 == owner0,
              "before \(owner0?.localizedName ?? "?"), after \(owner2?.localizedName ?? "?")")
        check("the icon's own click doesn't take focus", { toggle(); settle(0.6); let o = NSWorkspace.shared.menuBarOwningApplication; toggle(); return o == owner0 }())
        check("icon floats, above our windows", icon.level == .floating)
        // Settings › General › Floating icon off: the menu bar (dockOpen) still opens the dock.
        iconOn = false
        dockOpen = true
        check("icon off: hidden, the menu bar opens the dock", !icon.isVisible && dock.isVisible)
        dockOpen = false
        iconOn = true
        moveIcon(to: iconBefore)
        if wasPinned { pinned = true }
        for (k, v) in zip(keys, saved) { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } }
        before?.activate()
        print(failed == 0 ? "all passed" : "\(failed) failed")
    }
}

// The last app in front that isn't Penpal (#269): where focus goes back to, and where a paste "into the app in front"
// goes while Penpal itself is in front from a click on its dock.
@MainActor
enum OtherApp {
    private(set) static var last: NSRunningApplication?
    static func start() {
        last = NSWorkspace.shared.frontmostApplication.flatMap { $0 == NSRunningApplication.current ? nil : $0 } ?? topWindowApp()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            nonisolated(unsafe) let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app, app != NSRunningApplication.current { last = app } }
        }
    }
    // The app whose window is on top (a normal window, not ours): what was in front when Penpal came up first.
    static func topWindowApp() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            return app
        }
        return nil
    }
}

// How the dock looks (#273, Jason: "the buttons seem sunken in. i rather the buttons feel like they want to pop out ... can
// you add different dock bg color and button color? same for dark mode, ill go through them and select the one that
// feels right"): a background for light and one for dark, and one tile style. Settings › Dock › Appearance; live.
enum DockLook {
    static let lightKey = "dock.bg.light", darkKey = "dock.bg.dark", tilesKey = "dock.tiles"
    static let lights: [(key: String, label: String)] = [("glass", "Glass"), ("white", "White"), ("lightGrey", "Light grey"), ("paper", "Warm paper")]
    static let darks: [(key: String, label: String)] = [("glass", "Glass"), ("graphite", "Graphite"), ("black", "Black"), ("warmDark", "Warm dark")]
    static let tileStyles: [(key: String, label: String)] = [("raised", "Raised"), ("flat", "Flat"), ("tinted", "Tinted")]
    // A solid background's colour; Glass (the system material, as it always was) has none.
    static func color(_ key: String) -> NSColor? {
        switch key {
        case "white": NSColor(white: 1, alpha: 1)
        case "lightGrey": NSColor(white: 0.93, alpha: 1)
        case "paper": NSColor(red: 0.965, green: 0.945, blue: 0.90, alpha: 1)
        case "graphite": NSColor(white: 0.17, alpha: 1)
        case "black": NSColor(white: 0.06, alpha: 1)
        case "warmDark": NSColor(red: 0.165, green: 0.148, blue: 0.13, alpha: 1)
        default: nil
        }
    }
}

// The open dock's panel: Glass, or a solid colour with a hairline edge.
struct DockBackground: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(DockLook.lightKey) private var light = "glass"
    @AppStorage(DockLook.darkKey) private var dark = "glass"
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        if let c = DockLook.color(scheme == .dark ? dark : light) {
            shape.fill(Color(nsColor: c)).overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        } else {
            shape.fill(.regularMaterial)
        }
    }
}

// A tile's look. Raised (the default): lighter than the panel, a soft drop shadow and a faint light top edge, so it sits
// up off the panel instead of in it. Flat: the old recessed fill. Tinted: a faint wash of its icon's colour.
struct DockTileLook: ViewModifier {
    var radius: CGFloat = 12
    var tint: Color?
    @Environment(\.colorScheme) private var scheme
    @AppStorage(DockLook.tilesKey) private var style = "raised"
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        let dark = scheme == .dark
        switch style {
        case "flat":
            content.background(.quaternary, in: shape)
        case "tinted":
            content.background(shape.fill((tint ?? .gray).opacity(dark ? 0.24 : 0.14)))
                .overlay(shape.strokeBorder((tint ?? .gray).opacity(dark ? 0.35 : 0.25), lineWidth: 0.5))
        default:
            content.background(
                shape.fill(dark ? Color.white.opacity(0.12) : Color.white.opacity(0.92))
                    .shadow(color: .black.opacity(dark ? 0.45 : 0.12), radius: dark ? 3 : 2.5, y: 1.5)
                    .shadow(color: .black.opacity(dark ? 0.3 : 0.06), radius: 0.5, y: 0.5)
            )
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(dark ? 0.22 : 0.9), Color.white.opacity(0)],
                                                       startPoint: .top, endPoint: .center), lineWidth: 0.75))
        }
    }
}
extension View {
    func dockTile(radius: CGFloat = 12, tint: Color? = nil) -> some View { modifier(DockTileLook(radius: radius, tint: tint)) }
}

// Pressed, a tile gives a little: smaller and a touch darker.
struct TilePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// A plain icon in the dock's header (Settings, Pin): no button around it, a soft rounded highlight under the mouse,
// as the copy icon in Guide me. --render with -render.hover <id> draws one as if the mouse were on it.
struct HeaderButton<Label: View>: View {
    let id: String
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Label
    @StateObject private var hovering = HoverState()  // this toolchain has no @State
    private var over: Bool { hovering.on || UserDefaults.standard.string(forKey: "render.hover") == id }
    var body: some View {
        Button(action: action) {
            label
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(over ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6))
                .frame(width: 30, height: Overlay.tabSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering.on)
        .help(help)
    }
}

// --order-check (#283): which of Penpal's is on top after each kind of touch, read from the live window list front to
// back, through the same calls a click makes (touched, became key). Prints a line per check; then quits.
extension Overlay {
    func orderCheck() {
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) { print((ok ? "PASS " : "FAIL ") + name + "  (" + detail + ")"); if !ok { failed += 1 } }
        func settle(_ s: Double = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func order() -> [Int] {  // window numbers on screen, front to back
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? Int }
        }
        func above(_ a: NSWindow?, _ b: NSWindow?) -> Bool {
            guard let a, let b, let i = order().firstIndex(of: a.windowNumber), let j = order().firstIndex(of: b.windowNumber) else { return false }
            return i < j
        }
        guard let dock = panel, let icon = iconPanel else { print("FAIL no panels"); exit(1) }
        let wasExpanded = expanded
        if !expanded { toggle() }
        Enhance.open(); settle(1.0)
        guard let enhance = NSApp.windows.first(where: { ours($0) && $0.title == "Enhance" }) else { print("FAIL no Enhance window"); exit(1) }
        check("Enhance opens above the dock", above(enhance, dock), "Enhance level \(enhance.level.rawValue), dock \(dock.level.rawValue)")
        touched(dock); settle()
        check("a click on the dock: the dock above Enhance", above(dock, enhance), "")
        touched(enhance); settle()
        check("a click or drag on Enhance: Enhance above the dock", above(enhance, dock), "")
        touched(dock); settle(0.1); became(key: enhance); settle()  // the key change a click brings comes within ms
        check("Enhance getting focus back right after a dock click doesn't jump it over the dock", above(dock, enhance), "")
        // An ordinary window (Settings) while Penpal is in front: lifted, so a click on it puts it over the dock.
        SettingsWindow.open(); settle(1.0)
        let settings = NSApp.windows.first { ours($0) && $0 !== enhance }
        if let settings {
            activeForCheck = true  // a click on a window always brings Penpal in front; macOS won't for a test
            touched(settings); settle()
            check("a click on Settings (Penpal in front): Settings above the dock", above(settings, dock), "Settings level \(settings.level.rawValue)")
            touched(dock); settle()
            check("then a click on the dock: the dock above Settings", above(dock, settings), "")
            activeForCheck = nil
        } else { check("Settings opens", false, "") }
        // Another app in front: Settings an ordinary window again, under the dock; Enhance, the dock and the icon float.
        // The activation notices come on the main queue, so the rest runs in a later turn of it, as it would for real.
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: Overlay.claudeBundle).first else {
            print("SKIP Claude isn't running"); enhance.close(); settings?.close()
            print(failed == 0 ? "all passed" : "\(failed) failed"); exit(failed == 0 ? 0 : 1)
        }
        NSApp.yieldActivation(to: claude); claude.activate(); settleLevel()  // the resign notice, if macOS sends one, settles it again
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated {
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            check("Claude in front: Enhance, the dock and the icon still floating and shown",
                  enhance.level == .floating && dock.level == .floating && icon.level == .floating && dock.isVisible && icon.isVisible,
                  "front \(front), Enhance level \(enhance.level.rawValue)")
            check("Claude in front: Settings an ordinary window again", settings?.level == .normal, "front \(front), Settings level \(settings?.level.rawValue ?? -1)")
            let claudeWin = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .first { ($0[kCGWindowOwnerPID as String] as? pid_t) == claude.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? Int
            let o = order()
            check("the dock above Claude's window", claudeWin.map { c in (o.firstIndex(of: dock.windowNumber) ?? .max) < (o.firstIndex(of: c) ?? -1) } ?? false, "")
            enhance.close(); settings?.close()
            if !wasExpanded { UserDefaults.standard.set(false, forKey: "dock.expanded") }  // as it was before the check
            print(failed == 0 ? "all passed" : "\(failed) failed"); exit(failed == 0 ? 0 : 1)
        } }
    }
}
