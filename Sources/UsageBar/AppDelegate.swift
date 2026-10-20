import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = UsageStore()
    private let menuLabel = MenuBarLabel()
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            menuLabel.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(menuLabel)
            NSLayoutConstraint.activate([
                menuLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                menuLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                menuLabel.topAnchor.constraint(equalTo: button.topAnchor),
                menuLabel.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }
        updateStatusTitle()

        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: ContentView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusTitle()
                self?.reconcileTimer()
            }
            .store(in: &cancellables)

        store.refresh(force: true)
        reconcileTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    /// Recreates the auto-refresh timer when the chosen interval changes.
    private func reconcileTimer() {
        let interval = TimeInterval(store.refreshInterval.rawValue)
        if timer?.timeInterval == interval { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
    }

    /// A minimal main menu — without an Edit menu, cmd+C/V/X don't reach
    /// text fields in the login window (the app has no menu bar otherwise).
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "AI Usage 종료",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Clicks

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isContext = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isContext { showContextMenu() } else { togglePopover() }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        store.refresh()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu() {
        if popover.isShown { popover.performClose(nil) }
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: "사용량 보기", action: #selector(openPopover), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "지금 새로고침", action: #selector(refreshNow), keyEquivalent: "r")
            .target = self
        menu.addItem(withTitle: "Claude.ai 로그인", action: #selector(loginClaude), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: store.codexLoginInProgress ? "Codex 로그인 취소" : "Codex 로그인",
                     action: store.codexLoginInProgress ? #selector(cancelCodexLogin) : #selector(loginCodex),
                     keyEquivalent: "")
            .target = self

        menu.addItem(.separator())

        let windowItem = NSMenuItem(title: "메뉴 막대 표시", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu()
        for kind in [WindowKind.fiveHour, .weekly] {
            let item = NSMenuItem(title: "\(kind.label) 사용률",
                                  action: #selector(selectMenuWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = (store.menuWindow == kind) ? .on : .off
            windowMenu.addItem(item)
        }
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)

        let toolItem = NSMenuItem(title: "표시할 도구", action: nil, keyEquivalent: "")
        let toolMenu = NSMenu()
        for filter in ToolFilter.allCases {
            let item = NSMenuItem(title: filter.label,
                                  action: #selector(selectToolFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = filter.rawValue
            item.state = (store.toolFilter == filter) ? .on : .off
            toolMenu.addItem(item)
        }
        toolItem.submenu = toolMenu
        menu.addItem(toolItem)

        let intervalItem = NSMenuItem(title: "갱신 주기", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for iv in RefreshInterval.allCases {
            let item = NSMenuItem(title: iv.label,
                                  action: #selector(selectInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = iv.rawValue
            item.state = (store.refreshInterval == iv) ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let launch = NSMenuItem(title: "로그인 시 자동 실행",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = store.launchAtLogin ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        menu.addItem(withTitle: "AI Usage 정보", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        let quit = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    // MARK: - Menu actions

    @objc private func openPopover() { if !popover.isShown { togglePopover() } }
    @objc private func refreshNow() { store.refresh(force: true) }
    @objc private func loginClaude() { store.showClaudeLogin() }
    @objc private func loginCodex() { store.showCodexLogin() }
    @objc private func cancelCodexLogin() { store.cancelCodexLogin() }
    @objc private func toggleLaunchAtLogin() { store.launchAtLogin.toggle() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func selectMenuWindow(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let kind = WindowKind(rawValue: raw) {
            store.menuWindow = kind
        }
    }

    @objc private func selectToolFilter(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let filter = ToolFilter(rawValue: raw) {
            store.toolFilter = filter
            store.refresh()
        }
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? Int, let iv = RefreshInterval(rawValue: raw) {
            store.refreshInterval = iv
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AI Usage"
        alert.informativeText = """
        Claude · Codex 사용량을 메뉴 막대에 표시합니다.
        두 도구 모두 계정의 실제 한도를 실시간으로 보여줍니다.

        버전 2.8
        """
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    // MARK: - Menu-bar title (two stacked lines: C / X)

    private func updateStatusTitle() {
        let snap = store.snapshot
        let kind = store.menuWindow
        var lines: [MenuBarLabel.Line] = []
        if store.toolFilter.showsClaude {
            lines.append(menuLine("C", snap.percent(.claude, kind)))
        }
        if store.toolFilter.showsCodex {
            lines.append(menuLine("X", snap.percent(.codex, kind)))
        }
        menuLabel.lines = lines
        statusItem.length = menuLabel.contentWidth
    }

    private func menuLine(_ tag: String, _ percent: Double?) -> MenuBarLabel.Line {
        let text = percent.map { "\(tag) \(Int($0.rounded()))%" } ?? "\(tag)  —"
        var color = NSColor.labelColor
        if let p = percent {
            if p >= 100 { color = .systemRed }
            else if p >= 80 { color = .systemOrange }
        }
        return MenuBarLabel.Line(text: text, color: color)
    }
}
