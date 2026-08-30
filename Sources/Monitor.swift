import Foundation
import AppKit
import CoreLocation

/// 計測の司令塔。3つの周期で回す:
///   link  2秒  … 無害なので高頻度。メニューバーの表示はこれで動く
///   probe 5秒  … ping。ここで1レコード記録する
///   wan  30秒  … 外部RTT/DNS。頻繁に測る必要は無い
///   scan 180秒 … 電波が悪いときだけ。通信を乱すので普段は走らせない
final class Monitor: NSObject, CLLocationManagerDelegate {

    private(set) var link = LinkInfo()
    private(set) var gw: PingResult?
    private(set) var wan: PingResult?
    private(set) var dnsMS: Double?
    private(set) var gatewayIP: String?
    private(set) var score = 0
    private(set) var verdict: Verdict = .offline
    private(set) var better: (ap: SeenAP, certain: Bool)?
    private(set) var recentScores: [Int] = []
    private(set) var lastRoamAt: Date?
    /// 直近の観測スループット（受動）。
    /// 今のAPに繋いでから観測した最大RSSI。距離は測れないが、
    /// 「同じAPのまま電波が落ちた」＝そのAPから離れた、という変化は捉えられる。
    /// 今のAPを掴んだ時刻。「掴みっぱなし」を判断する材料になる。
    private(set) var apSince: Date?
    private(set) var peakRSSIOnAP: Int?
    /// ピークから何dB落ちたか。移動の証拠として使う。
    var rssiDrop: Int { max(0, (peakRSSIOnAP ?? link.rssi) - link.rssi) }
    /// より良いAPが連続して見えている回数。1回だけの検出は電波の揺らぎでも起きる。
    private(set) var betterStreak = 0

    private(set) var rxMbps: Double?
    private(set) var txMbps: Double?
    /// VPN経由かどうか。遅延の読み方が変わるので画面にも出す。
    private(set) var vpnInterface: String?
    /// このMac自身の負荷。回線が正常でも体感が悪い原因になりうる。
    private(set) var load = SystemLoad()
    /// 回線を埋めているプロセス。名指しできると対処が具体的になる。
    private(set) var topTalkers: [TopTalkers.Entry] = []
    private var talkersAt: Date?
    private var talkersRunning = false

    /// このMac自身が流している量の合計。
    var ownMbps: Double { (rxMbps ?? 0) + (txMbps ?? 0) }
    private var lastCounters: NetProbe.IfCounters?

    let scanner = ScanManager()
    let log = SampleLog()
    let notifier = Notifier()
    private let loc = CLLocationManager()

    var onUpdate: (() -> Void)?
    /// この状態が「利用者の操作で改善できるか」を外から判定してもらう。
    /// 切替候補の有無は既知ネットワーク一覧に依存するので Monitor 単独では決められない。
    var actionableCheck: ((Verdict) -> Bool)?

    private var masterTimer: Timer?
    private var pruneTimer: Timer?
    private var nextLink = Date.distantPast
    private var nextProbe = Date.distantPast
    private var nextWAN = Date.distantPast
    private var nextScan = Date.distantPast

    /// 状態が良いまま続いた回数。落ち着いていれば計測を控える判断に使う。
    private var stableRuns = 0
    /// パネルを開いている間は利用者が数値を見ているので、常に細かく測る。
    var fastMode = false

    /// 計測間隔は固定にしない。
    /// ping自体が電波時間を食うため、常時5秒間隔で撃つと自分で回線を悪化させる
    /// （実測で第一ホップが17〜49ms→4〜6msに改善した）。落ち着いているときは控える。
    private var battery: Bool { PowerState.onBattery() }

    var linkInterval: TimeInterval {
        if fastMode { return 2 }
        return battery ? 4 : 2
    }
    var probeInterval: TimeInterval {
        if fastMode { return 5 }
        let base: TimeInterval = (verdict == .ok && stableRuns >= 12) ? 12 : 5
        return battery ? base * 1.5 : base
    }
    var wanInterval: TimeInterval {
        if fastMode { return 30 }
        let base: TimeInterval = (verdict == .ok && stableRuns >= 12) ? 60 : 30
        return battery ? base * 1.5 : base
    }
    private var probing = false
    private var wanProbing = false
    private var lastBSSID: String?
    /// 一度でも経路の有無を調べたか。起動直後の未確定を「経路なし」と誤解しないため。
    private var routeChecked = false
    private var displayWasAsleep = false

    /// 単発の測定値は素で暴れる(txRateは172〜458Mbpsを行き来する)。
    /// 判定に使う値だけ平滑化し、表示と記録は生値も残す。
    private var gwHistory: [PingResult] = []
    /// 外部計測は30秒に1回しか走らないため、単発の悪化がそのまま30秒間表示され続ける。
    /// 中央値を取って一時的なブレで「回線が遅い」と断定しないようにする。
    private var wanHistory: [PingResult] = []
    private var smoothedWAN: PingResult? {
        guard !wanHistory.isEmpty else { return nil }
        return PingResult(avg: Monitor.median(wanHistory.compactMap { $0.avg }),
                          stddev: nil,
                          loss: Monitor.median(wanHistory.map { $0.loss }) ?? 0)
    }
    private var txHistory: [Double] = []
    /// 直近のRSSI。単発のスパイクでピークが跳ね上がらないよう中央値で更新する。
    private var rssiHistory: [Int] = []

    /// ICMPを返さないゲートウェイ向けの代替計測。
    /// 何度も全損したらTCPに切り替える（切り替え後は元に戻さない）。
    private var icmpFailStreak = 0
    private var gwTCPPort: UInt16?
    /// 計測方式。詳細画面に出して、利用者が値の意味を誤解しないようにする。
    private(set) var gwMethod = "ping"

    private static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted(); return s[s.count / 2]
    }

    /// 判定に使っているのと同じ値。画面もこれを表示しないと、
    /// 「混雑と判定しているのに区間は緑で速い」という矛盾が起きる。
    var gwForDisplay: PingResult? { smoothedGW }
    var wanForDisplay: PingResult? { smoothedWAN }

    /// 直近3回のping結果の中央値。1回の外れ値で判定が跳ねないようにする。
    private var smoothedGW: PingResult? {
        guard !gwHistory.isEmpty else { return nil }
        return PingResult(avg: Monitor.median(gwHistory.compactMap { $0.avg }),
                          stddev: Monitor.median(gwHistory.compactMap { $0.stddev }),
                          loss: Monitor.median(gwHistory.map { $0.loss }) ?? 0)
    }

    /// リンクレートは無通信時に下がるだけなので、直近のピークが「その場の実力」に近い。
    private var smoothedTx: Double { txHistory.max() ?? link.txRate }

    /// スコア/判定に使う、平滑化済みのリンク情報。
    var linkForDisplay: LinkInfo {
        var l = link; l.txRate = smoothedTx; return l
    }

    var locationAuthorized: Bool {
        let s = loc.authorizationStatus
        return s == .authorizedAlways || s == .authorized
    }

    func start() {
        loc.delegate = self
        requestLocationIfNeeded()
        notifier.requestAuthorization()

        // 古い記録の掃除は起動時と1日1回。ディスクを無限に食わせない。
        DispatchQueue.global().async { self.log.pruneOldLogs() }
        pruneTimer = Timer(timeInterval: 86_400, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.global().async { self.log.pruneOldLogs() }
        }
        RunLoop.main.add(pruneTimer!, forMode: .common)

        // スリープから戻ると、古い測定値が一瞬そのまま出てしまう。
        // 復帰時は捨てて測り直す。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.clearMeasurements()
                self.stableRuns = 0
                let now = Date()
                self.nextLink = now; self.nextProbe = now
                self.nextWAN = now; self.nextScan = now.addingTimeInterval(30)
                self.recompute(); self.onUpdate?()
            }

        gatewayIP = NetProbe.defaultGateway()
        tickLink()
        // 起動時に一度だけスキャンしておく。最初にパネルを開いた時点で
        // 乗り換え候補を出せるようにするため。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.rescan() }
        tickProbe()
        tickWAN()

        // .common モードで登録する。既定モードだとメニューを開いている間タイマーが止まり、
        // 一番見たいタイミング(パネルを開いている最中)に数値が更新されなくなる。
        // 間隔が状況で変わるので、1秒ごとに「そろそろ測る時刻か」を見る形にする。
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        masterTimer = t
    }

    private func tick() {
        // 画面が消えている間は測らない。利用者が使っていない時間の値は
        // 診断の役に立たないばかりか、平均とグラフを汚す。
        if PowerState.displayAsleep() {
            if !displayWasAsleep { displayWasAsleep = true }
            return
        }
        if displayWasAsleep {
            // 復帰直後は古い値を持ち越さない
            displayWasAsleep = false
            clearMeasurements()
            stableRuns = 0
            let n = Date()
            nextLink = n; nextProbe = n; nextWAN = n; nextScan = n.addingTimeInterval(20)
        }

        let now = Date()
        if now >= nextLink  { nextLink  = now.addingTimeInterval(linkInterval);  tickLink() }
        if now >= nextProbe { nextProbe = now.addingTimeInterval(probeInterval); tickProbe() }
        if now >= nextWAN   { nextWAN   = now.addingTimeInterval(wanInterval);   tickWAN() }
        if now >= nextScan  { nextScan  = now.addingTimeInterval(180);           autoScan() }
    }

    /// 悪化を検知したら細かい計測へ戻す。
    /// ただし状態が揺れているときに連射すると、自分で回線を圧迫してしまう。
    /// 最短でも3秒は空ける。
    private func updateStability() {
        if verdict == .ok {
            stableRuns += 1
        } else {
            stableRuns = 0
            nextProbe = min(nextProbe, Date().addingTimeInterval(3))
        }
    }

    /// SSID/BSSID を読むには位置情報の許可が要る(macOS 14以降)。
    func requestLocationIfNeeded() {
        if loc.authorizationStatus == .notDetermined { loc.requestWhenInUseAuthorization() }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        tickLink()
        onUpdate?()
    }

    private func tickLink() {
        link = LinkSampler.read()
        if link.associated {
            txHistory.append(link.txRate)
            if txHistory.count > 5 { txHistory.removeFirst(txHistory.count - 5) }  // 直近10秒
        } else {
            txHistory.removeAll()
        }

        // BSSIDが変わった = ローミングした。BSSIDが取れない環境(位置情報未許可)でも
        // 接続の開始時刻は分かるようにしておく。
        let wasAssociated = apSince != nil
        let bssidChanged = link.bssid != nil && link.bssid != lastBSSID
        if !link.associated {
            peakRSSIOnAP = nil; apSince = nil; lastBSSID = nil; rssiHistory.removeAll()
            // 切断中に切断前の値を出し続けると、実態と違う画面になる
            clearMeasurements()
        } else if bssidChanged || !wasAssociated {
            if wasAssociated && lastBSSID != nil { lastRoamAt = Date() }
            lastBSSID = link.bssid
            peakRSSIOnAP = link.rssi
            apSince = Date()
            betterStreak = 0
            rssiHistory = [link.rssi]
            clearMeasurements()   // 経路が変わったので前のAPの測定値は無効
        } else {
            // 単発の跳ね上がりでピークが不当に高くならないよう、直近3点の中央値で更新する
            rssiHistory.append(link.rssi)
            if rssiHistory.count > 3 { rssiHistory.removeFirst() }
            let sorted = rssiHistory.sorted()
            let med = sorted[sorted.count / 2]
            peakRSSIOnAP = max(peakRSSIOnAP ?? med, med)
        }
        recompute()
        onUpdate?()
    }

    private func recompute() {
        let l = linkForDisplay
        let g = smoothedGW
        let n = smoothedWAN
        better  = scanner.betterAP(than: l)
        // 経路が引けているかどうかは判定の前提条件。まだ一度も調べていない起動直後は
        // 「経路あり」とみなして測定中扱いにする。
        let hasRoute = gatewayIP != nil || !routeChecked
        score   = Scorer.score(link: l, gw: g, net: n, dns: dnsMS, hasGateway: hasRoute)
        verdict = Scorer.verdict(link: l, gw: g, net: n, dns: dnsMS,
                                 better: better, rssiDrop: rssiDrop, betterStreak: betterStreak,
                                 hasGateway: hasRoute,
                                 ownMbps: ownMbps, macBusy: load.busy)
        recentScores.append(score)
        if recentScores.count > 40 { recentScores.removeFirst(recentScores.count - 40) }
    }

    private func tickProbe() {
        guard !probing else { return }
        probing = true
        DispatchQueue.global().async {
            let ip = self.gatewayIP ?? NetProbe.defaultGateway()
            let g = ip.map { self.measureFirstHop($0, count: 5) }
            let c = NetProbe.counters(LinkSampler.interfaceName)
            // 画面を開いている間、または逼迫しているときだけアプリ一覧まで取る
            let withProcs = self.fastMode || self.load.busy
            let load = SystemLoad.read(includeProcesses: withProcs)
            DispatchQueue.main.async {
                // アプリ一覧を取らなかった回は、前回の一覧を保つ
                var load = load
                if load.topCPU.isEmpty { load.topCPU = self.load.topCPU }
                if load.topMemory.isEmpty { load.topMemory = self.load.topMemory }
                if load.cpuPercent == 0 { load.cpuPercent = self.load.cpuPercent }
                self.load = load
                self.updateThroughput(c)
                self.gatewayIP = ip
                self.routeChecked = true
                self.gw = g
                if let g { self.gwHistory.append(g); if self.gwHistory.count > 3 { self.gwHistory.removeFirst() } }
                self.probing = false
                self.recompute()
                self.updateStability()
                self.record()
                self.refreshTalkersIfNeeded()
                self.notifier.observe(verdict: self.verdict, score: self.score,
                                      actionable: self.actionableCheck?(self.verdict) ?? false,
                                      detail: self.detailLine())
                self.onUpdate?()
            }
        }
    }

    /// 経路が変わったときに測定値を捨てる。持ち越すと、実際には測れていない状態で
    /// 前の場所の数値を表示してしまう。
    private func clearMeasurements() {
        gw = nil; wan = nil; dnsMS = nil
        gatewayIP = nil; routeChecked = false
        gwHistory.removeAll(); wanHistory.removeAll(); txHistory.removeAll()
        rxMbps = nil; txMbps = nil; lastCounters = nil
    }

    /// 第一ホップの計測。ICMPが通らない機器では TCP の接続時間に切り替える。
    /// これをやらないと、ICMPを落とすルータの下で永久に「混雑」と誤判定してしまう。
    private func measureFirstHop(_ ip: String, count: Int) -> PingResult {
        if let port = gwTCPPort {
            return NetProbe.tcpPing(ip, port: port, count: count)
        }
        let r = NetProbe.ping(ip, count: count, interval: 0.2)
        if r.loss >= 100 {
            icmpFailStreak += 1
            if icmpFailStreak >= 3, let port = NetProbe.findTCPPort(ip) {
                gwTCPPort = port
                gwMethod = "TCP :\(port)"
                return NetProbe.tcpPing(ip, port: port, count: count)
            }
        } else {
            icmpFailStreak = 0
        }
        return r
    }

    /// 回線を埋めているプロセスを調べる。nettop は数秒かかるので、
    /// 自分の通信が原因と判定されたときだけ、間隔を空けて呼ぶ。
    private func refreshTalkersIfNeeded() {
        guard verdict == .selfTraffic || ownMbps >= 8 else {
            if ownMbps < 2 { topTalkers = [] }
            return
        }
        if let at = talkersAt, Date().timeIntervalSince(at) < 30 { return }
        guard !talkersRunning else { return }
        talkersRunning = true
        talkersAt = Date()
        DispatchQueue.global().async {
            let t = TopTalkers.read()
            DispatchQueue.main.async {
                self.topTalkers = Array(t.prefix(3))
                self.talkersRunning = false
                self.onUpdate?()
            }
        }
    }

    /// 累積カウンタの差分から実際に流れた速度を出す。
    /// これ自体は通信を発生させないので常時回せる。
    private func updateThroughput(_ c: NetProbe.IfCounters?) {
        defer { if let c { lastCounters = c } }
        guard let c, let prev = lastCounters else { return }
        let dt = c.at.timeIntervalSince(prev.at)
        guard dt > 0.5, c.rx >= prev.rx, c.tx >= prev.tx else { return }
        rxMbps = Double(c.rx - prev.rx) * 8 / dt / 1_000_000
        txMbps = Double(c.tx - prev.tx) * 8 / dt / 1_000_000
    }

    private func tickWAN() {
        guard !wanProbing else { return }
        wanProbing = true
        DispatchQueue.global().async {
            let n = NetProbe.probeWAN()
            let d = NetProbe.dnsMillis(server: NetProbe.primaryDNS())
            LinkSampler.refreshNoiseFallback()
            // サブプロセスを起こす処理なのでメインスレッドで呼ばない
            let ip = NetProbe.defaultGateway()
            let vpn = NetProbe.vpnInterface()
            DispatchQueue.main.async {
                self.vpnInterface = vpn
                self.routeChecked = true
                self.wan = n; self.dnsMS = d
                self.wanHistory.append(n)
                if self.wanHistory.count > 3 { self.wanHistory.removeFirst() }
                self.wanProbing = false
                if ip != self.gatewayIP {
                    self.gatewayIP = ip
                    // サブネットが変わったら計測方式の判定もやり直す
                    self.gwTCPPort = nil; self.icmpFailStreak = 0; self.gwMethod = "ping"
                }
                self.recompute(); self.onUpdate?()
            }
        }
    }

    /// 自動スキャンは「電波が弱い or 既に問題判定」のときだけ。通話を壊さないための制限。
    private func autoScan() {
        guard link.associated else { return }
        guard link.rssi < -63 || verdict.isProblem else { return }
        rescan()
    }

    /// 手動の「今すぐ精密測定」。通常の周期を待たず、スキャンと全プローブを同時に走らせる。
    /// 悪いと感じた瞬間の状態をその場で確定させるための入口。
    func deepCheck(progress: @escaping (String) -> Void, done: @escaping () -> Void) {
        progress("測定中…")
        let group = DispatchGroup()

        group.enter()
        scanner.scan(current: link) { _ in group.leave() }

        group.enter()
        DispatchQueue.global().async {
            let ip = NetProbe.defaultGateway()
            let g = ip.map { NetProbe.ping($0, count: 15, interval: 0.2) }   // 通常より多めに撃つ
            let n = NetProbe.probeWAN()
            let d = NetProbe.dnsMillis(server: NetProbe.primaryDNS())
            LinkSampler.refreshNoiseFallback()
            DispatchQueue.main.async {
                self.gatewayIP = ip
                if let g { self.gw = g; self.gwHistory = [g] }               // 手動測定は履歴を上書き
                self.wan = n; self.dnsMS = d
                self.wanHistory = [n]
                group.leave()
            }
        }

        // スキャンやpingが返らないと done が呼ばれず、画面のボタンが永久に押せなくなる。
        // 必ず1回だけ完了させる保険を掛ける。
        var finished = false
        let finish: () -> Void = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.recompute(); self?.record(); self?.onUpdate?(); done()
        }
        group.notify(queue: .main) { finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { finish() }
    }

    /// パネルを開いたときなど、乗り換え候補が必要な場面で使う。
    /// スキャンは通信を乱すので「問題が出ていて、かつ直近に測っていない」ときだけ。
    /// パネルを開いた瞬間に、アプリ一覧まで含めて読み直す。
    /// 次の定期計測を待つと数秒「計測中」のままになる。
    func refreshLoadNow() {
        DispatchQueue.global().async {
            let l = SystemLoad.read(includeProcesses: true)
            DispatchQueue.main.async { self.load = l; self.recompute(); self.onUpdate?() }
        }
    }

    func scanIfNeeded() {
        guard verdict.isProblem else { return }
        if let at = scanner.lastScanAt, Date().timeIntervalSince(at) < 60 { return }
        rescan()
    }

    func rescan(_ completion: (() -> Void)? = nil) {
        scanner.scan(current: link) { _ in
            // 連続回数はスキャンのたびにだけ更新する（2秒ごとの再計算で水増ししない）
            let b = self.scanner.betterAP(than: self.linkForDisplay)
            self.betterStreak = b != nil ? self.betterStreak + 1 : 0
            self.recompute(); self.onUpdate?(); completion?()
        }
    }

    private func record() {
        let s = Sample(at: Date(), associated: link.associated,
                       ssid: link.ssid, bssid: link.bssid,
                       rssi: link.rssi, noise: link.noise, txRate: smoothedTx,
                       channel: link.channel, width: link.width, band: link.band, phy: link.phy,
                       gwRTT: gw?.avg, gwJitter: gw?.stddev, gwLoss: gw?.loss,
                       netRTT: wan?.avg, netLoss: wan?.loss, dnsMS: dnsMS,
                       rxMbps: rxMbps, txMbps: txMbps,
                       score: score, verdict: verdict.rawValue)
        log.append(s)
    }

    func detailLine() -> String {
        var parts: [String] = []
        if link.associated {
            parts.append("\(link.rssi)dBm / ch\(link.channel) / \(Int(smoothedTx))Mbps")
        }
        if let g = gw, let a = g.avg {
            parts.append(String(format: "AP まで %.1fms±%.1f", a, g.stddev ?? 0))
        }
        return parts.joined(separator: " · ") + "\n" + verdict.advice
    }
}
