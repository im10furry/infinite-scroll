import AppKit
import SwiftTerm

class TerminalViewRegistry {
    static let shared = TerminalViewRegistry()
    private var views: [UUID: LocalProcessTerminalView] = [:]
    private var tmuxSessions: [UUID: String] = [:]
    private var mouseRoutingCheckedAt: [UUID: Date] = [:]
    private var mouseRoutingApplied: [UUID: Bool] = [:]
    private let lock = NSLock()

    private init() {}

    func register(id: UUID, view: LocalProcessTerminalView, tmuxSession: String? = nil) {
        lock.lock()
        views[id] = view
        if let session = tmuxSession {
            tmuxSessions[id] = session
        }
        lock.unlock()
    }

    func unregister(id: UUID) {
        lock.lock()
        views.removeValue(forKey: id)
        tmuxSessions.removeValue(forKey: id)
        mouseRoutingCheckedAt.removeValue(forKey: id)
        mouseRoutingApplied.removeValue(forKey: id)
        lock.unlock()
    }

    /// Look up the tmux session name for a terminal view (nil if not tmux-backed).
    func tmuxSession(for view: LocalProcessTerminalView) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = views.first(where: { $0.value === view })?.key else { return nil }
        return tmuxSessions[id]
    }

    func view(for id: UUID) -> LocalProcessTerminalView? {
        lock.lock()
        defer { lock.unlock() }
        return views[id]
    }

    /// Keep each session's tmux mouse forwarding in sync with what the pane
    /// application wants. tmux only enables mouse reporting on the outer
    /// terminal while the session has `mouse on`, so plain shells stay on the
    /// local scrollback path and full-screen TUIs get the wheel and clicks.
    /// Throttled because tmux has no push notification for this flag.
    func refreshMouseRouting(for view: LocalProcessTerminalView, force: Bool = false) {
        lock.lock()
        guard let id = views.first(where: { $0.value === view })?.key,
              let session = tmuxSessions[id] else {
            lock.unlock()
            return
        }
        let now = Date()
        let applied = mouseRoutingApplied[id]
        // While forwarding is (or may be) on, stale state costs the next wheel
        // event to tmux copy-mode, so re-check sooner than for plain shells.
        let interval = applied == false
            ? Self.shellMouseRoutingCheckInterval
            : Self.tuiMouseRoutingCheckInterval
        if !force, let checkedAt = mouseRoutingCheckedAt[id],
           now.timeIntervalSince(checkedAt) < interval {
            lock.unlock()
            return
        }
        mouseRoutingCheckedAt[id] = now
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            guard let wants = TmuxManager.paneWantsMouse(session: session) else { return }
            if wants != applied, !TmuxManager.setMouse(session, enabled: wants) {
                // Never cache a state tmux did not apply: the next probe retries.
                return
            }
            self.lock.lock()
            // Do not resurrect cache entries for cells that were unregistered
            // while this probe was in flight.
            if self.views[id] != nil {
                self.mouseRoutingApplied[id] = wants
            }
            self.lock.unlock()
        }
    }

    /// Plain shells have nothing to forward, so a slow cadence is enough.
    private static let shellMouseRoutingCheckInterval: TimeInterval = 2
    /// Mouse-aware panes: a TUI can exit at any moment, and until the probe
    /// notices, tmux would keep the wheel in copy-mode. Keep that window short.
    private static let tuiMouseRoutingCheckInterval: TimeInterval = 0.5

    /// Returns the visible terminal under a point given in window coordinates.
    /// SwiftUI overlays drawn above a representable can defeat AppKit hit
    /// testing, which used to make wheel events fall through to the outer
    /// canvas. Resolving geometrically keeps scrolling routed to the terminal.
    func terminalView(at windowPoint: NSPoint, in window: NSWindow) -> LocalProcessTerminalView? {
        lock.lock()
        let candidates = Array(views.values)
        lock.unlock()
        for view in candidates {
            guard view.window === window,
                  !view.isHiddenOrHasHiddenAncestor,
                  view.alphaValue > 0 else { continue }
            let localPoint = view.convert(windowPoint, from: nil)
            if view.visibleRect.contains(localPoint) {
                return view
            }
        }
        return nil
    }

    func focus(id: UUID) {
        if let view = view(for: id) {
            refreshMouseRouting(for: view, force: true)
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                scrollRowToVisible(view)
            }
        }
    }
}

/// Scroll the entire row (including header) into the viewport
private func scrollRowToVisible(_ view: NSView) {
    var current: NSView? = view.superview
    while let parent = current {
        if let scrollView = parent as? CmdNSScrollView {
            guard let docView = scrollView.contentView.documentView else { return }
            // Find the row-level ancestor: walk up from the cell view
            // to find the view whose parent is the VStack hosting view
            var rowView: NSView = view
            while let sv = rowView.superview, sv !== docView {
                rowView = sv
            }
            // Convert the row's full frame (including header) to document coordinates
            let rect = rowView.convert(rowView.bounds, to: docView)
            // Add padding above so the header is visible
            let paddedRect = NSRect(
                x: rect.origin.x,
                y: rect.origin.y - Theme.panelSpacingValue,
                width: rect.width,
                height: rect.height + Theme.panelSpacingValue
            )
            docView.scrollToVisible(paddedRect)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }
        current = parent.superview
    }
}

class NotesViewRegistry {
    static let shared = NotesViewRegistry()
    private var views: [UUID: NSTextView] = [:]
    private let lock = NSLock()

    private init() {}

    func register(id: UUID, view: NSTextView) {
        lock.lock()
        views[id] = view
        lock.unlock()
    }

    func unregister(id: UUID) {
        lock.lock()
        views.removeValue(forKey: id)
        lock.unlock()
    }

    func view(for id: UUID) -> NSTextView? {
        lock.lock()
        defer { lock.unlock() }
        return views[id]
    }

    func focus(id: UUID) {
        lock.lock()
        let view = views[id]
        lock.unlock()
        if let view = view {
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
                scrollRowToVisible(view)
            }
        }
    }
}
