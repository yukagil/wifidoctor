import AppKit
import SwiftUI
import Carbon.HIToolbox

/// メニューバー常駐の入口。表示は SwiftUI（NSPopover）に任せ、ここは配線に徹する。
final class MenuController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = Monitor()
    private lazy var app = AppState(monitor: monitor)
    private let popover = NSPopover()
    private var history: HistoryWindowController?
    private var hotKey: HotKey?
    private var refreshTimer: Timer?
    private var hosting: NSHostingController<RootView>?
    private var lastSymbol = ""

    func start() {
        buildPopover()

        item.isVisible = true
        item.autosaveName = "WiFiDoctorStatusItem"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        app.onCompactChange = { [weak self] in self?.render() }
        app.openHistory = { [weak self] in self?.showHistory() }
        monitor.onUpdate = { [weak self] in
            guard let self else { return }
            self.app.refresh()
            self.render()
        }
        monitor.start()
        app.refreshKnownNetworks()
        app.refresh()
        app.reloadRecent()

        // ポップオーバーを開いている間だけ、折れ線を定期的に読み直す
        refreshTimer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.app.reloadRecent()
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_W),
                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.hotKeyFired()
        }

        // 自動起動の指定があれば、ユーザー操作を待たずに登録する
        if UserDefaults.standard.bool(forKey: "autoStartRequested"), !LoginItem.isEnabled {
            _ = LoginItem.set(true)
            app.loginOn = LoginItem.isEnabled
            UserDefaults.standard.removeObject(forKey: "autoStartRequested")
        }

        render()

        if !UserDefaults.standard.bool(forKey: "didIntroduce") {
            UserDefaults.standard.set(true, forKey: "didIntroduce")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showPopover()
            }
        }
    }

    private func buildPopover() {
        let root = RootView(
            app: app,
            openHistory: { [weak self] in self?.showHistory() },
            openLogFolder: { NSWorkspace.shared.open(SampleLog.dir) },
            quit: { NSApp.terminate(nil) })
        let host = NSHostingController(rootView: root)
        // SwiftUI の実寸をポップオーバーに伝える。これが無いと初期サイズのまま固定され、
        // 内容が伸びたときに上端が切れる（画面が上で見切れるバグの原因）。
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        hosting = host
    }

    // MARK: - メニューバー表示

    private func symbolName() -> String {
        guard monitor.link.associated else { return "wifi.slash" }
        switch app.snap.level {
        case .good: return "wifi"
        case .fair: return "wifi.exclamationmark"
        case .bad:  return "wifi.exclamationmark"
        case .offline: return "wifi.slash"
        }
    }

    private func render() {
        guard let b = item.button else { return }
        let level = app.snap.level
        let color: NSColor = {
            switch level {
            case .good: return .systemGreen
            case .fair: return .systemOrange
            case .bad:  return .systemRed
            case .offline: return .systemGray
            }
        }()

        // 2秒ごとに呼ばれるので、同じ絵柄なら作り直さない
        let sym = symbolName()
        if sym != lastSymbol {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            let img = NSImage(systemSymbolName: sym, accessibilityDescription: "WiFiDoctor")?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = true
            b.image = img
            b.imagePosition = .imageLeading
            lastSymbol = sym
        }

        // メニューバーが混むと溢れて消えるので、既定でも幅は数値2桁ぶんに抑える
        let compact = UserDefaults.standard.bool(forKey: "compactBar")
        b.attributedTitle = NSAttributedString(
            string: compact ? "" : (monitor.link.associated ? " \(monitor.score)" : " --"),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: color])
        b.toolTip = "\(app.snap.headline)\n⌥⌘W で今すぐ調べる"
    }

    // MARK: - 操作

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let b = item.button else { return }
        app.refreshKnownNetworks()
        monitor.scanIfNeeded()
        monitor.refreshLoadNow()
        app.refresh()
        app.reloadRecent()
        // 表示直前にも実寸を反映させる（ページ切替で高さが変わるため）
        if let h = hosting {
            let fit = h.sizeThatFits(in: NSSize(width: PanelMetrics.width, height: CGFloat.greatestFiniteMagnitude))
            if fit.height > 1 { popover.contentSize = fit }
        }
        NSApp.activate(ignoringOtherApps: true)
        monitor.fastMode = true          // 見ている間は細かく測る
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        // ポップオーバー内のボタン/トグルを1クリックで操作できるようにする
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.fastMode = false
        app.page = .home
        app.clearFlash()
    }

    /// ホットキー: 開くと同時に測り直す。「遅い」と感じた瞬間の状態をその場で出す。
    private func hotKeyFired() {
        showPopover()
        app.quickScan()
    }

    private func showHistory() {
        if history == nil { history = HistoryWindowController(log: monitor.log) }
        NSApp.activate(ignoringOtherApps: true)
        history?.showWindow(nil)
        history?.reload()
        popover.performClose(nil)
    }
}
