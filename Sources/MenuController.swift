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

        // ⌥⌘W は macOS 標準の「すべてのウインドウを閉じる」。
        // RegisterEventHotKey はシステム全域なので、既定で登録すると
        // 入れた瞬間から全アプリでその操作が効かなくなる。
        // 使う人はWi-Fiアプリのせいだと気づけないので、明示的に有効にしたときだけ登録する。
        applyHotKey()
        app.onHotKeyChange = { [weak self] in self?.applyHotKey() }
        monitor.notifier.enabled = app.notifyOn

        // 自動起動の指定があれば、ユーザー操作を待たずに登録する
        if Settings.store.bool(forKey: "autoStartRequested"), !LoginItem.isEnabled {
            _ = LoginItem.set(true)
            app.loginOn = LoginItem.isEnabled
            Settings.store.removeObject(forKey: "autoStartRequested")
        }

        render()

        if !Settings.store.bool(forKey: "didIntroduce") {
            Settings.store.set(true, forKey: "didIntroduce")
            // 権限の確認ダイアログと重なるので、少し待ってから出す
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.introduce()
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
        // 測定中は「切れている」ではない。起動直後に斜線を出すと、
        // 隣にスコアが並んでいるのに切断中に見える。
        if app.snap.measuring { return "wifi" }
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
        let compact = Settings.store.bool(forKey: "compactBar")
        b.attributedTitle = NSAttributedString(
            // 測定中はパネル側が「--」を出している。ここだけ数字を出すと、
            // 同じ瞬間に「91」と「--」が並ぶ。まだ分からないものは断定しない。
            string: compact ? ""
                : (monitor.link.associated && !app.snap.measuring ? " \(monitor.score)" : " --"),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: color])
        b.toolTip = app.hotKeyOn ? "\(app.snap.headline)\n⌥⌘W で今すぐ調べる" : app.snap.headline
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

    /// 初回だけ、何をするアプリなのかを伝える。
    /// 常時測ることと、記録がディスクに残ることは、黙って始めてよいことではない
    /// （README を読まない人にも届かせる）。
    private func introduce() {
        let a = NSAlert()
        a.messageText = "WiFiDoctor を始めます"
        a.informativeText =
            "メニューバーに常駐して、Wi-Fiの調子を数秒おきに測り続けます。\n"
            + "測った内容はこのMacの中に30日ぶん残ります（外へ送ることはありません）。\n"
            + "\(SampleLog.dir.path)\n\n"
            + "接続先の名前を読むために位置情報の許可を求めます。\n"
            + "断っても動きますが、場所ごとの比較はできません。"
        a.addButton(withTitle: "始める")
        a.addButton(withTitle: "終了する")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn {
            NSApp.terminate(nil)
            return
        }
        showPopover()
    }

    /// 設定に従ってホットキーを登録・解除する。
    func applyHotKey() {
        hotKey = nil
        guard app.hotKeyOn else { return }
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_W),
                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.hotKeyFired()
        }
    }

    private func showHistory() {
        if history == nil { history = HistoryWindowController(log: monitor.log) }
        NSApp.activate(ignoringOtherApps: true)
        history?.showWindow(nil)
        history?.reload()
        popover.performClose(nil)
    }
}
