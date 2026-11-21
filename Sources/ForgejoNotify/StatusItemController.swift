import AppKit
import Combine
import SwiftUI

/// Draws the menu bar icon. Sits on top of the status button and lets clicks through.
final class StatusIconView: NSView {
    var model = MenuBarModel() {
        didSet { if model != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MenuBarRenderer.draw(model, in: ctx, bounds: bounds, appearance: effectiveAppearance)
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let store: NotificationStore
    private let actions: AppActions
    private let statusItem: NSStatusItem
    private let iconView = StatusIconView()
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?

    init(store: NotificationStore, actions: AppActions) {
        self.store = store
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: MenuBarRenderer.width(for: MenuBarModel()))
        super.init()

        statusItem.autosaveName = "ForgejoNotifyStatusItem"
        if let button = statusItem.button {
            iconView.frame = button.bounds
            iconView.autoresizingMask = [.width, .height]
            button.addSubview(iconView)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        var popoverActions = actions
        popoverActions.openSettings = { [weak self] in
            self?.popover.performClose(nil)
            actions.openSettings()
        }
        popoverActions.closePopover = { [weak self] in self?.popover.performClose(nil) }
        let host = NSHostingController(rootView: PopoverView(store: store, actions: popoverActions))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        cancellable = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        update()
    }

    func update() {
        let model = MenuBarModel.make(store: store)
        iconView.model = model
        let width = MenuBarRenderer.width(for: model)
        if abs(statusItem.length - width) > 0.5 { statusItem.length = width }

        let summary: String
        if let error = store.error {
            summary = "Forgejo: \(error.title)"
        } else if store.lastFetched == nil {
            summary = "Forgejo: loading…"
        } else {
            let count = store.badgeCount
            summary = count == 0 ? "Forgejo: no unread notifications"
                : "Forgejo: \(count) unread notification\(count == 1 ? "" : "s")"
        }
        statusItem.button?.toolTip = summary
        statusItem.button?.setAccessibilityLabel(summary)
    }

    // MARK: - Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if store.shouldRefreshOnOpen {
            Task { await store.refresh() }
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(item("Refresh Now", #selector(menuRefresh), key: "r"))
        let readAll = item("Mark All as Read", #selector(menuReadAll))
        readAll.isEnabled = store.badgeCount > 0 || (Prefs.readAllScope == .everything && !store.hidden.isEmpty)
        menu.addItem(readAll)
        menu.addItem(item("Open Notifications in Browser", #selector(menuOpenWeb)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(menuSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Forgejo Notifications", #selector(menuQuit), key: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuRefresh() { actions.refresh() }
    @objc private func menuReadAll() { actions.readAll() }
    @objc private func menuOpenWeb() { actions.openWeb() }
    @objc private func menuSettings() { actions.openSettings() }
    @objc private func menuQuit() { actions.quit() }
}
