import AppKit
import SwiftUI
import SwiftTerm

// MARK: - CmdNSScrollView: intercepts Cmd+scroll for window scrolling

class CmdNSScrollView: NSScrollView {
    private var eventMonitor: Any?
    private weak var preciseScrollTarget: LocalProcessTerminalView?
    private var preciseScrollRemainder: CGFloat = 0
    private let pointsPerTerminalLine: CGFloat = 12
    var commandScrollSpeed: CGFloat = PanelStore.defaultCommandScrollSpeed

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self = self,
                      let window = self.window,
                      window == event.window else {
                    return event
                }

                if event.modifierFlags.contains(.command) {
                    // Cmd+scroll: scroll the outer window
                    let clipView = self.contentView
                    var newOrigin = clipView.bounds.origin
                    newOrigin.y -= event.scrollingDeltaY * self.commandScrollSpeed
                    let maxY = max(0, (clipView.documentView?.frame.height ?? 0) - clipView.bounds.height)
                    newOrigin.y = min(max(0, newOrigin.y), maxY)
                    clipView.setBoundsOrigin(newOrigin)
                    self.reflectScrolledClipView(clipView)
                    return nil
                }

                // Panels drawn above the canvas (Agent Queue, help, find bar)
                // own their scrolling. The geometric lookup below cannot see
                // that stacking, so let hit-tested overlays consume first.
                if let hitView = window.contentView?.hitTest(event.locationInWindow),
                   !Self.isView(hitView, inside: self) {
                    return event
                }

                // Non-Cmd scroll: route to the terminal under the cursor.
                // SwiftUI overlays (focus borders, badges) can defeat AppKit
                // hit testing here, so resolve the terminal geometrically from
                // the registry instead of walking a hit-tested view chain.
                guard let termView = TerminalViewRegistry.shared.terminalView(
                    at: event.locationInWindow,
                    in: window
                ) else {
                    return event
                }
                if termView.terminal.mouseMode != .off {
                    // The pane application captures the mouse (opencode, Codex,
                    // vim, …): hand the wheel to it so it scrolls its own
                    // transcript, exactly like a native terminal. Hold Shift
                    // to bypass and select text locally.
                    termView.scrollWheel(with: event)
                } else {
                    self.scrollTerminal(termView, with: event)
                }
                TerminalViewRegistry.shared.refreshMouseRouting(for: termView)
                return nil
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        super.removeFromSuperview()
    }

    // All scroll handling is done via the event monitor above.
    // This override prevents NSScrollView from scrolling its content on any stray events.
    override func scrollWheel(with event: NSEvent) {
        // no-op — monitor handles everything
    }

    /// AppKit reports trackpad scrolling in precise point deltas. Accumulate
    /// those deltas before advancing SwiftTerm by a row so one gesture does
    /// not cause a redraw for every tiny hardware event.
    private func scrollTerminal(_ termView: LocalProcessTerminalView, with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }

        let lines: Int
        if event.hasPreciseScrollingDeltas {
            if preciseScrollTarget !== termView ||
                (preciseScrollRemainder > 0 && delta < 0) ||
                (preciseScrollRemainder < 0 && delta > 0) {
                preciseScrollRemainder = 0
            }
            preciseScrollTarget = termView
            preciseScrollRemainder += delta
            lines = Int(abs(preciseScrollRemainder) / pointsPerTerminalLine)
            guard lines > 0 else { return }
            preciseScrollRemainder -= CGFloat(lines) * (delta > 0 ? pointsPerTerminalLine : -pointsPerTerminalLine)
        } else {
            preciseScrollTarget = nil
            preciseScrollRemainder = 0
            lines = scrollWheelLines(for: delta)
        }

        if delta > 0 {
            termView.scrollUp(lines: lines)
        } else {
            termView.scrollDown(lines: lines)
        }
    }

    private static func isView(_ view: NSView, inside ancestor: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate === ancestor { return true }
            current = candidate.superview
        }
        return false
    }

    private func scrollWheelLines(for delta: CGFloat) -> Int {
        switch abs(delta) {
        case 10...:
            return 20
        case 6...:
            return 10
        case 2...:
            return 3
        default:
            return 1
        }
    }
}

// MARK: - CmdScrollView: SwiftUI wrapper

struct CmdScrollView<Content: View>: NSViewRepresentable {
    let commandScrollSpeed: CGFloat
    let content: Content

    init(
        commandScrollSpeed: CGFloat = PanelStore.defaultCommandScrollSpeed,
        @ViewBuilder content: () -> Content
    ) {
        self.commandScrollSpeed = commandScrollSpeed
        self.content = content()
    }

    func makeNSView(context: Context) -> CmdNSScrollView {
        let scrollView = CmdNSScrollView()
        scrollView.commandScrollSpeed = commandScrollSpeed
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.drawsBackground = false
        clipView.documentView = hostingView
        scrollView.contentView = clipView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: clipView.topAnchor),
        ])

        return scrollView
    }

    func updateNSView(_ nsView: CmdNSScrollView, context: Context) {
        nsView.commandScrollSpeed = commandScrollSpeed
        guard let hostingView = nsView.contentView.documentView as? NSHostingView<Content> else { return }
        hostingView.rootView = content
    }
}
