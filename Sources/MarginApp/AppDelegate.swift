import AppKit
import Combine
import MarginCore
import MarginUI
import SwiftUI

/// Receives tracking-area callbacks on behalf of the status item button.
private final class HoverSentinel: NSResponder {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let activityStore = ActivityStore()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    private var watch: Severity = .normal

    private let hoverSentinel = HoverSentinel()
    private var showTask: Task<Void, Never>?
    private var proximityTimer: Timer?
    private var awayRounds = 0
    private var lastShownAt: Date?
    private var isHoverShown = false

    private let hoverIntent: TimeInterval = 0.18
    private let reentryWindow: TimeInterval = 1.0
    private let pollInterval: TimeInterval = 0.12
    private let bridge: CGFloat = 14

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configurePopover()
        observeStore()
        store.start()
        activityStore.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Setup

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = StatusItemGlyph.image(for: [], style: .levels)
            button.imagePosition = .imageOnly
            button.toolTip = "Margin"
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            button.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: hoverSentinel,
                userInfo: nil
            ))
            hoverSentinel.onEnter = { [weak self] in
                Task { @MainActor in self?.iconEntered() }
            }
            hoverSentinel.onExit = { [weak self] in
                Task { @MainActor in self?.iconExited() }
            }
        }
        statusItem = item
    }

    private func configurePopover() {
        let popover = NSPopover()
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverView()
                .environmentObject(store)
                .environmentObject(activityStore)
        )
        self.popover = popover

        NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.popoverDidClose() }
        }
    }

    private func observeStore() {
        store.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshots in
                self?.updateGlyph(snapshots)
            }
            .store(in: &cancellables)

        activityStore.$alerts
            .receive(on: RunLoop.main)
            .sink { [weak self] alerts in
                self?.watch = SentinelRules.watchSeverity(alerts)
                self?.updateGlyph(self?.store.snapshots ?? [])
            }
            .store(in: &cancellables)
    }

    private func updateGlyph(_ snapshots: [ProviderSnapshot]) {
        statusItem?.button?.image = StatusItemGlyph.image(for: snapshots, style: .levels, watch: watch)
    }

    // MARK: - Hover

    private func iconEntered() {
        showTask?.cancel()
        guard !(popover?.isShown ?? false) else { return }

        let delay = (lastShownAt.map { Date().timeIntervalSince($0) < reentryWindow } ?? false) ? 0 : hoverIntent
        showTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self.showPopover(hover: true)
        }
    }

    private func iconExited() {
        showTask?.cancel()
    }

    private func startProximity() {
        awayRounds = 0
        proximityTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkProximity() }
        }
        RunLoop.main.add(timer, forMode: .common)
        proximityTimer = timer
    }

    private func stopProximity() {
        proximityTimer?.invalidate()
        proximityTimer = nil
        awayRounds = 0
    }

    private func checkProximity() {
        guard isHoverShown, popover?.isShown == true else { return }
        if pointerNearStatusSurface() {
            awayRounds = 0
        } else {
            awayRounds += 1
            if awayRounds >= 3 { hidePopover() }
        }
    }

    private func pointerNearStatusSurface() -> Bool {
        let pointer = NSEvent.mouseLocation

        if let window = popover?.contentViewController?.view.window {
            if window.frame.insetBy(dx: -bridge, dy: -bridge).contains(pointer) { return true }
        }
        if let button = statusItem?.button, let window = button.window {
            let screen = window.convertToScreen(button.convert(button.bounds, to: nil))
            if screen.insetBy(dx: -bridge, dy: -bridge).contains(pointer) { return true }
        }
        return false
    }

    // MARK: - Presentation

    private func showPopover(hover: Bool) {
        guard let popover, let button = statusItem?.button, !popover.isShown else { return }
        popover.behavior = hover ? .applicationDefined : .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        isHoverShown = hover
        lastShownAt = Date()
        // Hover re-reads, but respects the live cache TTL so it can't hammer
        // the endpoints; the explicit Refresh button forces.
        Task { await store.refresh() }
        if hover {
            startProximity()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func hidePopover() {
        showTask?.cancel()
        stopProximity()
        popover?.performClose(nil)
    }

    private func popoverDidClose() {
        stopProximity()
        isHoverShown = false
    }

    // MARK: - Interaction

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover?.isShown == true {
            hidePopover()
        } else {
            showPopover(hover: false)
        }
    }

    private func showMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Margin", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        Task { await store.refresh(forceLive: true) }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
