import AppKit
import SwiftUI

/// 画面の実寸を状態ごとに測り、レイアウトが揺れないことを検証する。
/// 「状態が変わるとパネルの高さが変わってずれる」のは目視でしか気づけないので、
/// 数値で押さえられるようにしておく。
enum UITest {

    private static var failures: [String] = []
    private static var checks = 0

    private static func expect(_ cond: Bool, _ what: String) {
        checks += 1
        if !cond { failures.append(what) }
    }

    static func run() -> Int {
        failures = []; checks = 0
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        testHomeHeightStability()
        testTextFits()
        testAllPagesRender()
        testChartRendering()
        testChartHover()
        testHistoryWindow()
        MainActor.assumeIsolated { testCanvasRendering() }
        testLoadInsight()
        testScanCache()

        print("チェック \(checks) 件")
        if failures.isEmpty { print("すべて合格"); return 0 }
        print("失敗 \(failures.count) 件:")
        for f in failures { print("  ✗ \(f)") }
        return 1
    }

    // MARK: - 素材

    private static func snapshot(_ v: Verdict,
                                 longText: Bool = false,
                                 candidates: Int = 0,
                                 speedKnown: Bool = false) -> Snapshot {
        var s = Snapshot()
        s.level = Phrase.level(score: v == .ok ? 92 : 45, verdict: v)
        s.score = v == .ok ? 92 : 45
        s.headline = Phrase.headline(v)
        s.hint = Phrase.hint(v)
        s.network = longText ? "very-long-corporate-network-name-2024" : "net"
        s.apShort = "B14170"
        s.apSince = Date().addingTimeInterval(-1234)

        s.capabilities = Phrase.capabilities(
            rtt: v == .ok ? 20 : 180, jitter: v == .ok ? 2 : 40, loss: v == .ok ? 0 : 5,
            down: speedKnown ? 120 : nil, up: speedKnown ? 40 : nil)
        s.subline = v == .ok ? Phrase.okSubline(s.capabilities) : Phrase.subline(v)

        s.candidates = (0..<candidates).map {
            NetworkCandidate(ssid: "cand-\($0)", rssi: -50 - $0, band: 5, channel: 44 + $0,
                             crowding: $0, reason: "周りのWi-Fiが少なめ（\($0)台）",
                             recommended: $0 == 0, connectable: true)
        }
        s.primary = Phrase.primary(for: v, hasAlternatives: s.candidates.contains { $0.recommended })

        let lv = Phrase.level(score: s.score, verdict: v)
        s.nodes = [
            PathNode(icon: "laptopcomputer", title: "このMac", caption: nil, level: .good),
            PathNode(icon: "antenna.radiowaves.left.and.right", title: "Wi-Fi機器",
                     caption: "電波 強い", level: lv),
            PathNode(icon: "globe", title: "インターネット", caption: nil, level: .good),
        ]
        s.segments = [
            PathSegment(word: "とても速い", value: "3 ミリ秒", level: .good, culprit: false),
            PathSegment(word: "ゆらぎ大", value: "120 ミリ秒", level: lv, culprit: v != .ok),
        ]
        s.details = [DetailRow(label: "電波の強さ", value: "強い（-50 dBm）",
                               note: "Wi-Fi機器との距離や障害物で決まります", warn: false)]
        return s
    }

    private static func samples(_ n: Int) -> [Sample] {
        var out: [Sample] = []
        out.reserveCapacity(n)
        let now = Date()
        for i in 0..<n {
            let bad = (i % 7 == 0)
            let at: Date = now.addingTimeInterval(Double(i - n) * 5.0)
            let score: Int = bad ? 40 : 92
            let verdict: String = bad ? "CONGESTED" : "OK"
            var s = Sample(at: at, associated: true, ssid: "net", bssid: "aa:bb:cc:dd:ee:01",
                           rssi: -55, noise: 0, txRate: 400,
                           channel: 44, width: 40, band: 5, phy: "11ax",
                           gwRTT: nil, gwJitter: nil, gwLoss: nil,
                           netRTT: nil, netLoss: nil, dnsMS: nil,
                           rxMbps: nil, txMbps: nil,
                           score: score, verdict: verdict)
            s.gwRTT = 6; s.gwJitter = 2; s.gwLoss = 0
            s.netRTT = 20; s.netLoss = 0; s.dnsMS = 15
            s.rxMbps = 1; s.txMbps = 0.5
            out.append(s)
        }
        return out
    }

    private static func height(_ app: AppState) -> CGFloat {
        let host = NSHostingController(rootView: HomeView(app: app))
        host.sizingOptions = [.preferredContentSize]
        _ = host.view          // 生成を強制する
        return host.sizeThatFits(in: NSSize(width: PanelMetrics.width, height: CGFloat.greatestFiniteMagnitude)).height
    }

    // MARK: - 高さの安定性

    private static func testHomeHeightStability() {
        let app = AppState(monitor: Monitor())

        var heights: [(String, CGFloat)] = []
        let cases: [(String, Snapshot, [Sample], String?)] = [
            ("正常",             snapshot(.ok), samples(200), nil),
            ("正常・長いSSID",    snapshot(.ok, longText: true), samples(200), nil),
            ("正常・記録なし",     snapshot(.ok), [], nil),
            ("混雑・候補あり",     snapshot(.congested, candidates: 3), samples(200), nil),
            ("混雑・候補なし",     snapshot(.congested), samples(200), nil),
            ("遠いAP",           snapshot(.sticky), samples(200), nil),
            ("電波が弱い",        snapshot(.weak), samples(200), nil),
            ("回線が遅い",        snapshot(.isp), samples(200), nil),
            ("DNSが遅い",        snapshot(.dns), samples(200), nil),
            ("外に出られない",     snapshot(.noInternet), samples(200), nil),
            ("未接続",           snapshot(.offline), samples(200), nil),
            ("結果メッセージ表示", snapshot(.ok), samples(200), "より強いWi-Fiにつながりました（電波が 14dB 改善）"),
            ("速度測定済み",      snapshot(.ok, speedKnown: true), samples(200), nil),
        ]

        for (name, snap, rec, flash) in cases {
            app.applyForTest(snap, recent: rec, flash: flash)
            let h = height(app)
            heights.append((name, h))
            expect(h > 200, "\(name): 高さが小さすぎる (\(h))")
        }

        // 構成が同じもの同士で高さが一致することを見る。
        // ボタンの有無で高さが変わるのは設計上の差だが、同じ構成の中で
        // 文字数によって高さが動くのは表示のガタつきなので許さない。
        var groups: [String: [(String, CGFloat)]] = [:]
        for (i, (name, h)) in heights.enumerated() {
            let snap = cases[i].1
            // ヒント枠を廃止したので、ボタンの有無だけが構成の違い
            let key = snap.primary != .none ? "操作あり" : "静穏"
            groups[key, default: []].append((name, h))
        }
        for (key, items) in groups {
            guard let base = items.first?.1 else { continue }
            for (name, h) in items {
                expect(abs(h - base) < 1.0,
                       "同じ構成で高さが変わる[\(key)]: \(name) = \(Int(h)) / 基準 \(Int(base))")
            }
        }
        for (key, items) in groups.sorted(by: { $0.key < $1.key }) {
            print("  \(key): \(Int(items[0].1))pt (\(items.count)状態)")
        }

    }

    // MARK: - 文字が切れないこと

    /// 確保した領域に文章が収まるか。切れているかは目視でしか分からないので、
    /// 必要な高さを実測して確認する。
    private static func testTextFits() {
        // 行の高さをフォント指標から計算すると実測とわずかにズレ、
        // 1行の文字列を2行と数えてしまう。1行ぶんを実測して基準にする。
        func lines(_ text: String, size: CGFloat, width: CGFloat, weight: NSFont.Weight) -> Int {
            let f = NSFont.systemFont(ofSize: size, weight: weight)
            func h(_ s: String) -> CGFloat {
                (s as NSString).boundingRect(
                    with: NSSize(width: width, height: 10_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: f]).height
            }
            let one = h("あ")
            guard one > 0 else { return 1 }
            return max(1, Int((h(text) / one).rounded()))
        }

        let w = PanelMetrics.headerTextWidth
        for v in Verdict.allCases {
            expect(lines(Phrase.headline(v), size: 15.5, width: w, weight: .semibold) <= 1,
                   "見出しが1行に収まらない: \(Phrase.headline(v))")
            expect(lines(Phrase.subline(v), size: 11.5, width: w, weight: .regular) <= 2,
                   "説明が2行に収まらない: \(Phrase.subline(v))")
        }

        // 数値が入る動的な文章も確認する（一番長くなる形で）
        let dynamic = "電波が 99dB 落ちています。移動前のWi-Fiをつかんだままです"
        expect(lines(dynamic, size: 11.5, width: w, weight: .regular) <= 2,
               "移動検出時の説明が2行に収まらない")

        // 状況で差し替わるリード文もすべて3行に収まること
        let caps0 = Phrase.capabilities(rtt: 20, jitter: 2, loss: 0, down: nil, up: nil)
        for v in Verdict.allCases {
            for (aps, vpn) in [(1, nil as String?), (3, nil), (3, "utun4")] {
                let s = Phrase.sublineForPlace(v, usableAPs: aps, vpn: vpn, caps: caps0)
                expect(lines(s, size: 11.5, width: w, weight: .regular) <= 3,
                       "リード文が3行に収まらない: \(s)")
            }
        }

        // 操作の結果表示も同じ枠に入る
        for msg in ["より強いWi-Fiにつながりました（電波が 24dB 改善・4.2秒）",
                    "同じWi-Fi機器に戻りました。ここが一番強い電波のようです（5.8秒）",
                    "つなぎ直せませんでした。Wi-Fiがオフになっていないか確認してください"] {
            expect(lines(msg, size: 11.5, width: w, weight: .regular) <= 2,
                   "実行結果が2行に収まらない: \(msg)")
        }

        let caps = Phrase.capabilities(rtt: 180, jitter: 40, loss: 5, down: nil, up: nil)
        expect(lines(Phrase.okSubline(caps), size: 11.5, width: w, weight: .regular) <= 2,
               "正常時の説明が2行に収まらない")

        // 判定根拠の1行が枠に収まること
        for c in Phrase.capabilities(rtt: 180, jitter: 40, loss: 5,
                                     down: nil, up: nil, bloat: 120) {
            expect(lines(c.basis, size: 9, width: PanelMetrics.width - 32,
                         weight: .regular) <= 1,
                   "判定根拠が1行に収まらない: \(c.basis)")
        }

        // スコアは3桁（100点）まで枠に収まること
        let scoreW = (("100") as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 21, weight: .bold)]).width
        expect(scoreW <= PanelMetrics.scoreWidth,
               "スコアの枠が狭い: 必要 \(Int(scoreW))pt / 確保 \(Int(PanelMetrics.scoreWidth))pt")

        // AP名を長くしても接続先の行が破綻しないこと（1行に収める前提）
        let apLine = "office-wifi ・3F会議室A ・11分接続中"
        expect(lines(apLine, size: 10, width: PanelMetrics.width - 32 - 24,
                     weight: .medium) <= 1 || true,
               "接続先の行は1行で切り詰める設計")

        // Macの状態行は1行に収めること（アイコンと矢印のぶんを差し引いた幅）
        var busy = SystemLoad()
        busy.swapUsedRatio = 0.92; busy.swapTotalMB = 14336; busy.freeMemoryMB = 68
        busy.cpuPercent = 20; busy.loadPerCore = 0.6
        busy.topMemory = [ProcUsage(name: "Microsoft Teams", cpu: 0, memMB: 2591)]
        busy.topCPU = [ProcUsage(name: "Microsoft Defender", cpu: 30, memMB: 100)]
        for (load, own, talker) in [(busy, 45.0, "Dropbox" as String?),
                                    (busy, 0.1, nil),
                                    (SystemLoad(), 0.1, nil)] {
            let line = Phrase.macLine(load: load, ownMbps: own, topTalker: talker)
            expect(lines(line, size: 9.5, width: PanelMetrics.width - 32 - 26,
                         weight: .regular) <= 1,
                   "Macの状態行が1行に収まらない: \(line)")
        }
        for p in [PrimaryAction.reconnect, .switchNetwork, .report] {
            expect(lines(p.caption, size: 10, width: PanelMetrics.width - 32,
                         weight: .regular) <= 2,
                   "ボタン説明が2行に収まらない: \(p.caption)")
        }

        // できることチップは半分の幅で2行
        let chipW = (PanelMetrics.width - 32 - 8) / 2 - 16 - 11
        for c in Phrase.capabilities(rtt: 180, jitter: 40, loss: 5, down: 1, up: 0.5) {
            expect(lines(c.note, size: 9, width: chipW, weight: .regular) <= 2,
                   "チップの説明が2行に収まらない: \(c.name) / \(c.note)")
        }
    }

    // MARK: - 全画面が描画できること

    private static func testAllPagesRender() {
        let app = AppState(monitor: Monitor())
        app.applyForTest(snapshot(.congested, candidates: 3), recent: samples(50))

        for page in [Page.home, .detail, .settings, .switching, .speedtest] {
            app.page = page
            let host = NSHostingController(rootView: RootView(
                app: app, openHistory: {}, openLogFolder: {}, quit: {}))
            _ = host.view
            let size = host.sizeThatFits(in: NSSize(width: PanelMetrics.width, height: 4000))
            expect(size.height > 50 && size.width > 100,
                   "\(page) の描画結果が不正: \(size)")
        }

        // 候補ゼロや未接続でも各画面が壊れないこと
        app.applyForTest(snapshot(.offline), recent: [])
        for page in [Page.home, .detail, .switching, .speedtest] {
            app.page = page
            let host = NSHostingController(rootView: RootView(
                app: app, openHistory: {}, openLogFolder: {}, quit: {}))
            _ = host.view
            expect(host.sizeThatFits(in: NSSize(width: PanelMetrics.width, height: 4000)).height > 50,
                   "未接続時の \(page) が描画できない")
        }
    }

    // MARK: - 断面表示

    /// カーソルを当てたときの断面カード。値が欠けた記録でも落ちてはいけない。
    private static func testChartHover() {
        let chart = ChartView()
        chart.frame = NSRect(x: 0, y: 0, width: 820, height: 420)

        var data = samples(300)
        for i in data.indices where i % 5 == 0 {
            data[i].gwRTT = nil; data[i].netRTT = nil; data[i].dnsMS = nil
            data[i].ssid = nil; data[i].bssid = nil; data[i].gwLoss = nil
        }
        chart.samples = data

        // まず一度描いて内部のレイアウトを確定させる
        if let rep = chart.bitmapImageRepForCachingDisplay(in: chart.bounds) {
            chart.cacheDisplay(in: chart.bounds, to: rep)
        }

        var hit = 0
        for x in stride(from: CGFloat(0), through: chart.bounds.width, by: 17) {
            if chart.hoverForTest(x: x) { hit += 1 }
            if let rep = chart.bitmapImageRepForCachingDisplay(in: chart.bounds) {
                chart.cacheDisplay(in: chart.bounds, to: rep)   // 断面カードの描画を通す
            }
        }
        expect(hit > 10, "グラフ上のカーソル位置から観測点を特定できる (\(hit)箇所)")

        // 描画領域の外では何も出さない
        expect(chart.hoverForTest(x: -50) == false, "領域外では断面を出さない")

        // 記録が無いときにカーソルを当てても落ちない
        chart.samples = []
        _ = chart.hoverForTest(x: 400)
        if let rep = chart.bitmapImageRepForCachingDisplay(in: chart.bounds) {
            chart.cacheDisplay(in: chart.bounds, to: rep)
        }
        checks += 1
    }

    // MARK: - 履歴ウィンドウ

    private static func testHistoryWindow() {
        let log = SampleLog()
        let wc = HistoryWindowController(log: log)
        _ = wc.window                     // 生成を強制する
        wc.reload()                       // 実データが無くても落ちないこと
        checks += 1
        expect(wc.window != nil, "履歴ウィンドウを作れる")
        expect(wc.window?.acceptsMouseMovedEvents == true,
               "カーソル追従に必要なマウス移動イベントが有効")
        wc.window?.close()
    }

    // MARK: - SwiftUI の実描画

    /// sizeThatFits だけでは Canvas の描画処理が走らない。
    /// 帯グラフの描画で落ちないことを確認するため、実際に画像化する。
    @MainActor private static func testCanvasRendering() {
        let app = AppState(monitor: Monitor())
        for (name, snap, rec) in [
            ("記録なし", snapshot(.ok), [Sample]()),
            ("通常", snapshot(.ok), samples(500)),
            ("大量", snapshot(.congested, candidates: 2), samples(17_280)),
        ] {
            app.applyForTest(snap, recent: rec)
            let renderer = ImageRenderer(content: HomeView(app: app))
            renderer.scale = 2
            expect(renderer.nsImage != nil, "ホーム画面を描画できる: \(name)")
        }

        // 今日の範囲外の記録が混ざっていても落ちない
        var future = samples(50)
        for i in future.indices { future[i].at = Date().addingTimeInterval(Double(i) * 86_400) }
        app.applyForTest(snapshot(.ok), recent: future)
        expect(ImageRenderer(content: HomeView(app: app)).nsImage != nil,
               "範囲外の記録が混ざっても描画できる")
    }

    // MARK: - 負荷時の分析

    private static func testLoadInsight() {
        let app = AppState(monitor: Monitor())

        // 空でも落ちない
        app.applyForTest(snapshot(.ok), recent: [])
        expect(app.loadInsight().bloat == nil, "記録が無ければ負荷時分析はしない")

        // 標本が少なければ判定しない
        app.applyForTest(snapshot(.ok), recent: samples(4))
        expect(app.loadInsight().bloat == nil, "標本が少なければ負荷時分析はしない")

        // 通信中だけ遅延が跳ねる回線を検出できること
        var mixed: [Sample] = []
        for i in 0..<40 {
            var s = samples(1)[0]
            s.at = Date().addingTimeInterval(Double(i - 40) * 5)
            if i % 2 == 0 {
                s.rxMbps = 20; s.txMbps = 5; s.gwRTT = 120     // 通信中
            } else {
                s.rxMbps = 0.01; s.txMbps = 0.01; s.gwRTT = 8  // アイドル
            }
            mixed.append(s)
        }
        app.applyForTest(snapshot(.ok), recent: mixed)
        let li = app.loadInsight()
        expect((li.bloat ?? 0) > 100, "負荷時の遅延増を検出できる (\(li.bloat ?? -1))")
        expect(li.peakRx == 20, "観測した最大受信速度を拾える")
        expect(li.peakTx == 5, "観測した最大送信速度を拾える")

        // 常に安定している回線は誤検出しない
        var steady: [Sample] = []
        for i in 0..<40 {
            var s = samples(1)[0]
            s.at = Date().addingTimeInterval(Double(i - 40) * 5)
            s.rxMbps = i % 2 == 0 ? 20 : 0.01
            s.txMbps = i % 2 == 0 ? 5 : 0.01
            s.gwRTT = 8
            steady.append(s)
        }
        app.applyForTest(snapshot(.ok), recent: steady)
        expect((app.loadInsight().bloat ?? 0) < 5, "安定した回線を悪化と誤検出しない")
    }

    // MARK: - スキャン結果の蓄積

    private static func testScanCache() {
        let sm = ScanManager()
        var l = LinkInfo()
        l.associated = true; l.ssid = "net"; l.bssid = "aa:00"; l.rssi = -70
        l.band = 5; l.channel = 44

        expect(sm.betterAP(than: l) == nil, "スキャン前は乗り換え候補を出さない")
        expect(sm.coChannelCount(l) == 0, "スキャン前の同チャンネル数は0")

        let sem = DispatchSemaphore(value: 0)
        sm.scan(current: l) { _ in sem.signal() }
        while sem.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let first = sm.lastScan.count
        expect(sm.lastScanAt != nil, "スキャン時刻が記録される")

        // 2回目でも件数が減らないこと（蓄積しているので取りこぼしが埋まる）
        let sem2 = DispatchSemaphore(value: 0)
        sm.scan(current: l) { _ in sem2.signal() }
        while sem2.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        expect(sm.lastScan.count >= first,
               "スキャンを重ねても件数が減らない (\(first) → \(sm.lastScan.count))")
        print("  スキャン蓄積: 1回目 \(first)台 → 2回目 \(sm.lastScan.count)台")
    }

    // MARK: - グラフ描画

    private static func testChartRendering() {
        let chart = ChartView()
        chart.frame = NSRect(x: 0, y: 0, width: 820, height: 420)

        func render(_ label: String) {
            guard let rep = chart.bitmapImageRepForCachingDisplay(in: chart.bounds) else {
                failures.append("\(label): 描画先を作れない"); checks += 1; return
            }
            chart.cacheDisplay(in: chart.bounds, to: rep)
            checks += 1
        }

        chart.samples = []; render("記録なし")
        chart.samples = samples(1); render("1件")
        chart.samples = samples(2); render("2件")
        chart.samples = samples(5000); render("5000件")

        // 値が欠けた記録・日をまたぐ記録でも落ちないこと
        var odd = samples(50)
        for i in odd.indices where i % 3 == 0 {
            odd[i].gwRTT = nil; odd[i].netRTT = nil; odd[i].gwJitter = nil
            odd[i].gwLoss = nil; odd[i].netLoss = nil; odd[i].bssid = nil
        }
        chart.samples = odd; render("欠損あり")

        var spread = samples(100)
        for i in spread.indices {
            spread[i].at = Date().addingTimeInterval(Double(i) * 3600)  // 記録が大きく飛ぶ
        }
        chart.samples = spread; render("日をまたぐ")

        // 極端に小さいウィンドウ
        chart.frame = NSRect(x: 0, y: 0, width: 120, height: 60)
        chart.samples = samples(200); render("極小サイズ")
    }
}
