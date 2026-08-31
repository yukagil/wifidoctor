import Foundation
import SwiftUI
import AppKit

enum Page { case home, detail, settings, switching, speedtest, naming, mac }

/// Monitor（計測）と SwiftUI（表示）の橋渡し。
/// Monitor 側は一切 UI を知らないままにしておきたいので、変換はここへ寄せる。
final class AppState: ObservableObject {

    @Published private(set) var snap = Snapshot.placeholder
    @Published private(set) var recent: [Sample] = []      // ホームの折れ線（直近1時間）
    @Published var page: Page = .home
    @Published private(set) var busy: String? {            // 実行中の表示
        didSet { armBusyWatchdog() }
    }
    private var busyWatchdog: DispatchWorkItem?
    @Published private(set) var flash: String?             // 実行結果の一言
    @Published private(set) var speed: NetProbe.SpeedResult?
    @Published private(set) var speedAt: Date?
    @Published private(set) var speedHistory: [SpeedRecord] = []

    @Published var notifyOn: Bool {
        didSet {
            monitor.notifier.enabled = notifyOn
            Settings.store.set(notifyOn, forKey: "notifyOn")
        }
    }
    /// ⌥⌘W で呼び出すかどうか。既定は切。全アプリの標準ショートカットを奪うため。
    @Published var hotKeyOn: Bool {
        didSet {
            Settings.store.set(hotKeyOn, forKey: "hotKeyOn")
            onHotKeyChange?()
        }
    }
    var onHotKeyChange: (() -> Void)?
    @Published var compactBar: Bool {
        didSet {
            Settings.store.set(compactBar, forKey: "compactBar")
            onCompactChange?()
        }
    }
    @Published var loginOn: Bool {
        didSet {
            guard loginOn != LoginItem.isEnabled else { return }
            _ = LoginItem.set(loginOn)
            loginStatus = LoginItem.statusText
        }
    }
    @Published private(set) var loginStatus: String = ""

    let monitor: Monitor
    var onCompactChange: (() -> Void)?
    var openHistory: (() -> Void)?

    /// 接続中APの呼び名。詳細画面で編集する。
    @Published var apNameDraft: String = ""
    private var apNameLoadedFor: String?

    /// 表示中のBSSIDが変わったら入力欄を差し替える。
    private func syncAPNameDraft(_ bssid: String?) {
        guard bssid != apNameLoadedFor else { return }
        apNameLoadedFor = bssid
        apNameDraft = APNames.name(for: bssid) ?? ""
    }

    func commitAPName() {
        // 入力を始めたときのAPに付ける。打っている間にローミングすると、
        // 気づかないうちに別のAPへ名前が付いてしまう。
        guard let b = apNameLoadedFor ?? monitor.linkForDisplay.bssid else { return }
        APNames.set(apNameDraft, for: b)
        reloadNamedAPs()
        refresh()
    }

    /// 付けた名前の一覧。付け間違いを直せるように編集画面へ出す。
    @Published private(set) var namedAPs: [(bssid: String, name: String)] = []

    func reloadNamedAPs() {
        namedAPs = APNames.all()
            .map { (bssid: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
    }

    func removeAPName(_ bssid: String) {
        APNames.set("", for: bssid)
        if bssid == monitor.linkForDisplay.bssid { apNameDraft = "" }
        reloadNamedAPs()
        refresh()
    }

    /// 過去に接続したことのあるSSID。切替できるのはこれらだけ。
    private var knownNetworks: [String] = []
    private var knownAt: Date?

    init(monitor: Monitor) {
        self.monitor = monitor
        defer {
            // 自分で直せる状態のときだけ通知する
            monitor.actionableCheck = { [weak self] v in
                guard let self else { return false }
                switch v {
                case .sticky, .weak: return true
                case .congested:     return self.snap.candidates.contains { $0.recommended }
                case .selfTraffic: return true   // 転送を止めれば自分で直せる
                case .ok, .isp, .dns, .offline, .noInternet,
                     .measuring, .macBusy: return false
                }
            }
        }
        // 既定は入り。ただし一度切ったら覚える（切ったつもりが再起動で戻るのを防ぐ）
        self.notifyOn = Settings.store.object(forKey: "notifyOn") as? Bool ?? true
        self.hotKeyOn = Settings.store.bool(forKey: "hotKeyOn")
        self.compactBar = Settings.store.bool(forKey: "compactBar")
        self.loginOn = LoginItem.isEnabled
        self.loginStatus = LoginItem.statusText
    }

    // MARK: - 取り込み

    /// 既知ネットワーク一覧はサブプロセス呼び出しなので、10分に1回だけ取り直す。
    func refreshKnownNetworks() {
        if let at = knownAt, Date().timeIntervalSince(at) < 600 { return }
        knownAt = Date()
        DispatchQueue.global().async {
            let n = NetworkSwitcher.preferredNetworks()
            DispatchQueue.main.async { self.knownNetworks = n; self.refresh() }
        }
    }

    func refresh() {
        let m = monitor
        let l = m.linkForDisplay
        var s = Snapshot()
        s.level = Phrase.level(score: m.score, verdict: m.verdict)
        s.score = m.score
        s.headline = Phrase.headline(m.verdict)
        s.usableAPs = m.scanner.usablePhysicalAPs()
        s.vpn = m.vpnInterface
        s.locationDenied = m.locationDenied
        s.measuring = m.verdict == .measuring
        s.scanNamesUnavailable = m.scanner.namesUnavailable
        s.localBlocked = m.localNetworkBlocked
        s.macWarn = m.load.busy || m.ownMbps >= 8
        s.macLine = Phrase.macLine(load: m.load, ownMbps: m.ownMbps,
                                   topTalker: m.topTalkers.first?.name)
        s.network = l.ssid
        s.apShort = APNames.label(for: l.bssid)
        s.apNamed = APNames.name(for: l.bssid) != nil
        s.apFull = l.bssid
        syncAPNameDraft(l.bssid)
        s.apSince = m.apSince
        s.candidates = NetworkSwitcher.candidates(
            scan: m.scanner.lastScan, current: l, known: knownNetworks)

        // 「切り替える」を主ボタンに出すのは、実際に良くなりそうな候補があるときだけ。
        // 逃げ場が1台も無いなら、押せるボタンを出しても嘘になる
        // 逃げ場が1台も無いなら、押せるボタンを出しても嘘になる
        let noEscape = m.verdict == .congested && s.usableAPs <= 1
                       && m.scanner.lastScanAt != nil
        // 管理側で端末の状態を変える操作を止めているなら、そもそも押させない
        let stuck = noEscape || !Settings.Managed.allowsNetworkChange
        s.primary = stuck ? .none
            : Phrase.primary(for: m.verdict,
                             hasAlternatives: s.candidates.contains { $0.recommended })
        let li = loadInsight()
        s.capabilities = Phrase.capabilities(
            rtt: m.wanForDisplay?.avg ?? m.gwForDisplay?.avg,
            jitter: m.gwForDisplay?.stddev,
            loss: max(m.gwForDisplay?.loss ?? 0, m.wanForDisplay?.loss ?? 0),
            down: speed?.downMbps, up: speed?.upMbps,
            peakRx: li.peakRx, peakTx: li.peakTx, bloat: li.bloat)
        // リード文は必ず capabilities から導く（別々に書くと食い違うため）
        s.subline = Phrase.sublineForPlace(m.verdict, usableAPs: s.usableAPs,
                                           vpn: s.vpn, caps: s.capabilities)
        // 距離そのものは測れないが「同じAPのまま電波が落ちた」量は分かる。
        // 移動して置いていかれた証拠になるので、通常のリード文より優先して出す。
        // 回線を埋めている犯人が分かっているなら名指しする
        if m.verdict == .selfTraffic, let top = m.topTalkers.first {
            s.subline = String(format: "%@ が %.0fMbps 使っています", top.name, top.mbps)
        }
        if m.verdict == .sticky, m.rssiDrop >= 8 {
            s.subline = "電波が \(m.rssiDrop)dB 低下。移動前のWi-Fiをつかんだままです"
        }
        s.details = buildDetails(m, l)
        buildPath(m, l, into: &s)
        snap = s
    }

    /// パソコン →(無線)→ Wi-Fi機器 →(回線)→ インターネット の3点2区間に落とす。
    /// 実際に別々に計測できるのがこの2区間なので、絵と計測を1対1で対応させる。
    private func buildPath(_ m: Monitor, _ l: LinkInfo, into s: inout Snapshot) {
        // 判定と同じ値を使う。生の最新値を出すと判定と食い違う。
        let gw = m.gwForDisplay
        let wan = m.wanForDisplay
        let gwMS = gw?.avg
        let wanMS = wan?.avg
        // AP から先だけの時間 = 全体 − 自分〜AP
        let upstream = (wanMS != nil && gwMS != nil) ? max(0, wanMS! - gwMS!) : wanMS

        let seg1 = Phrase.segLevel(ms: gwMS, jitter: gw?.stddev, loss: gw?.loss,
                                   badMS: 25, fairMS: 12)
        let seg2 = Phrase.segLevel(ms: upstream, jitter: nil, loss: wan?.loss,
                                   badMS: 150, fairMS: 60)

        // どの区間を名指しするかは判定と一致させる（絵と文言がズレると混乱するため）。
        // ただし、その区間自体が健全に見えているなら名指ししない。
        // 緑で「速い」と出ている区間に「ここが原因」と書くのは、単に間違い。
        let culprit1 = Phrase.isCulprit(verdict: m.verdict, hop: 0,
                                        level: l.associated ? seg1 : .offline)
        let culprit2 = Phrase.isCulprit(verdict: m.verdict, hop: 1, level: seg2)

        let apLevel: Level = !l.associated ? .offline
            : (l.rssi >= -63 ? .good : (l.rssi >= -70 ? .fair : .bad))

        // このMac自身の状態も経路の一部。常に緑にしておくと
        // 「原因はMac側」というケースを絵で表現できない。
        let macLevel: Level = m.load.busy
            ? (m.load.cpuBusy && m.load.memoryTight ? .bad : .fair) : .good
        let macCaption: String? = m.load.busy
            ? (m.load.memoryTight ? "メモリ不足" : "CPU負荷が高い")
            : (m.ownMbps >= 8 ? String(format: "送受信 %.0fMbps", m.ownMbps) : nil)
        s.nodes = [
            PathNode(icon: "laptopcomputer", title: "このMac",
                     caption: macCaption, level: macLevel),
            PathNode(icon: "antenna.radiowaves.left.and.right", title: "Wi-Fi機器",
                     caption: l.associated ? "電波 \(Phrase.signalWord(l.rssi))" : "未接続",
                     level: apLevel),
            // 測っていない／出られていないときに緑を出さない。
            // 「インターネットに出られません」と書いた画面の右端が緑だと、
            // どちらを信じればいいのか分からなくなる。
            PathNode(icon: "globe", title: "インターネット",
                     caption: nil,
                     level: internetLevel(m)),
        ]

        func internetLevel(_ m: Monitor) -> Level {
            if m.verdict == .noInternet { return .bad }
            guard let w = m.wanForDisplay else { return .offline }   // まだ測れていない
            return w.loss > 5 ? .bad : .good
        }

        func fmt(_ v: Double?) -> String {
            guard let v else { return "測定中" }
            // 引き算の結果が0付近になることがある。「0ミリ秒」は誤解を招くので避ける。
            if v < 1 { return "1ミリ秒未満" }
            return String(format: "%.0f ミリ秒", v)
        }

        let lv1: Level = l.associated ? seg1 : .offline
        s.segments = [
            PathSegment(word: Phrase.segWord(level: lv1, ms: gwMS,
                                             jitter: gw?.stddev, loss: gw?.loss, fairMS: 12),
                        value: fmt(gwMS), level: lv1, culprit: culprit1),
            PathSegment(word: Phrase.segWord(level: seg2, ms: upstream,
                                             jitter: nil, loss: wan?.loss, fairMS: 60),
                        value: fmt(upstream), level: seg2, culprit: culprit2),
        ]
    }

    private func buildDetails(_ m: Monitor, _ l: LinkInfo) -> [DetailRow] {
        guard l.associated else {
            return [DetailRow(label: "状態", value: "未接続", note: nil, warn: true)]
        }
        var rows: [DetailRow] = []

        rows.append(DetailRow(
            label: "電波の強さ",
            value: "\(Phrase.signalWord(l.rssi))（\(l.rssi) dBm）",
            note: "Wi-Fi機器との距離や障害物で決まります",
            warn: l.rssi < -68))

        let exp = LinkSampler.expectedRate(phy: l.phy, width: l.width)
        let pct = exp > 0 ? Int((l.txRate / exp * 100).rounded()) : 0
        rows.append(DetailRow(
            label: "リンク速度（規格上）",
            value: String(format: "%.0f Mbps", l.txRate),
            note: "Wi-Fi機器との間で取り決めた速度。実際に出る速度ではありません（規格上限の約\(pct)%）",
            warn: pct < 35))

        rows.append(DetailRow(
            label: "Wi-Fi機器までの反応",
            value: "\(Phrase.latencyWord(m.gwForDisplay?.avg))" +
                   (m.gwForDisplay?.avg.map { String(format: "（%.0f ミリ秒）", $0) } ?? ""),
            note: "ここが遅いとWi-Fi側が原因です",
            warn: (m.gwForDisplay?.avg ?? 0) > 12))

        rows.append(DetailRow(
            label: "インターネットまでの反応（往復の合計）",
            value: "\(Phrase.latencyWord(m.wanForDisplay?.avg))" +
                   (m.wanForDisplay?.avg.map { String(format: "（%.0f ミリ秒）", $0) } ?? ""),
            note: "Wi-Fi区間を含んだ合計。上の値との差が回線側の時間です",
            warn: (m.wanForDisplay?.avg ?? 0) > 100 || (m.wanForDisplay?.loss ?? 0) > 3))

        if m.scanner.lastScanAt != nil {
            let scan = m.scanner.lastScan
            let co = m.scanner.coChannelCount(l)
            rows.append(DetailRow(
                label: "近くのWi-Fi機器",
                value: "全 \(scan.count) 台 / 同じチャンネル \(co) 台",
                note: "同じチャンネルが多いほど電波の順番待ちが起きます。"
                    + "各機器に何台つながっているかはmacOSでは取得できません",
                warn: co >= 3))

            let devices = m.scanner.usablePhysicalAPs()
            rows.append(DetailRow(
                label: "この場所で使える機器",
                value: "\(devices) 台",
                note: devices <= 1
                    ? "逃げ先がないため、混雑しても切り替えでは解消できません"
                    : "電波が届く範囲にある物理的なWi-Fi機器の数（SSIDの数ではありません）",
                warn: devices <= 1))

            if let ssid = l.ssid {
                let same = scan.filter { $0.ssid == ssid }.count
                rows.append(DetailRow(
                    label: "このネットワークのAP",
                    value: "\(same) 台が見えています",
                    note: same > 1 ? "移動すると近い機器へ切り替わります" : "この場所では1台だけです",
                    warn: false))
            }
        }

        // Mac自身の状態。回線が正常なのに遅い場合、ここが答えになる。
        if m.ownMbps >= 1 {
            var note = "このMac自身が流している量"
            if let top = m.topTalkers.first {
                note += "（主に \(top.name)）"
            }
            rows.append(DetailRow(
                label: "このMacの通信量",
                value: String(format: "%.1f Mbps", m.ownMbps),
                note: note,
                warn: m.ownMbps >= 8))
        }
        if m.load.busy {
            rows.append(DetailRow(
                label: "Macの負荷",
                value: m.load.reason,
                note: "回線が正常でも、ここが逼迫していると遅く感じます",
                warn: true))
        }

        if let vpn = m.vpnInterface {
            rows.append(DetailRow(
                label: "VPN",
                value: "接続中（\(vpn)）",
                note: "「インターネットまでの反応」にはVPNの往復も含まれます",
                warn: true))
        }

        rows.append(DetailRow(
            label: "接続先",
            value: l.ssid ?? "不明",
            note: {
                var parts: [String] = []
                if let b = l.bssid {
                    if let n = APNames.name(for: b) { parts.append("\(n)（\(b)）") }
                    else { parts.append("機器ID \(b)") }
                }
                if let since = m.apSince { parts.append("\(Phrase.durationWord(since))つなぎっぱなし") }
                parts.append("\(l.band)GHz / \(l.phy)")
                return parts.joined(separator: " ・ ")
            }(),
            warn: false))

        return rows
    }

    /// 受動観測から得られる知見。
    struct LoadInsight {
        var peakRx: Double?      // 今日、実際に流れた最大の受信速度
        var peakTx: Double?
        var idleRTT: Double?     // 回線が空いているときの遅延
        var loadedRTT: Double?   // 実際に通信が流れているときの遅延
        var bloat: Double?       // その差 = 混雑時にどれだけ詰まるか
    }

    private var cachedInsight: LoadInsight?
    /// 件数だけでは中身の入れ替わりを見逃す。先頭と末尾の時刻も鍵に含める。
    private var cachedInsightKey: (count: Int, first: Date, last: Date)?

    /// 「アイドル時は綺麗なのに負荷がかかると崩れる」回線を、追加の通信なしで見抜く。
    /// 全記録を走査するので、記録が増えていないときは前回の結果を使い回す。
    func loadInsight() -> LoadInsight {
        guard let first = recent.first?.at, let last = recent.last?.at else {
            cachedInsight = nil; cachedInsightKey = nil
            return LoadInsight()
        }
        let key = (recent.count, first, last)
        if let c = cachedInsight, let k = cachedInsightKey,
           k.count == key.0, k.first == key.1, k.last == key.2 { return c }
        let r = computeLoadInsight()
        cachedInsight = r
        cachedInsightKey = key
        return r
    }

    private func computeLoadInsight() -> LoadInsight {
        var out = LoadInsight()
        guard !recent.isEmpty else { return out }

        out.peakRx = recent.compactMap { $0.rxMbps }.max()
        out.peakTx = recent.compactMap { $0.txMbps }.max()

        // 通信が流れている時間帯とアイドル時間帯でRTTを比べる
        var loaded: [Double] = []
        var idle: [Double] = []
        for s in recent {
            guard let rtt = s.gwRTT else { continue }
            let load = (s.rxMbps ?? 0) + (s.txMbps ?? 0)
            if load > 1.5 { loaded.append(rtt) }
            else if load < 0.15 { idle.append(rtt) }
        }
        // 標本が少ないと偶然の差を掴むだけなので判定しない
        guard loaded.count >= 8, idle.count >= 8 else { return out }

        func median(_ x: [Double]) -> Double { let s = x.sorted(); return s[s.count / 2] }
        let l = median(loaded), i = median(idle)
        out.loadedRTT = l
        out.idleRTT = i
        out.bloat = max(0, l - i)
        return out
    }

    private var tailOffset: UInt64 = 0
    private var tailDay: String = ""

    /// ホームの帯グラフ。今日0:00からの全記録。
    /// 1時間だと会議1本ぶんしか見えず「今日はずっと不調だった」が掴めないため。
    /// 初回だけ全件読み、以降は追記ぶんだけを継ぎ足す。
    var recentForDisplay: [Sample] { Sample.representative(recent) }

    var load: SystemLoad { monitor.load }
    var topTalkers: [TopTalkers.Entry] { monitor.topTalkers }
    var ownMbps: Double { monitor.ownMbps }

    /// 改善案。Mac側だけでなく、回線を埋めているアプリも含める。
    var macSuggestions: [String] {
        var out = monitor.load.suggestions
        if monitor.ownMbps >= 8, let top = monitor.topTalkers.first {
            out.append(String(format: "「%@」が %.0fMbps 使っています。転送を一時停止すると回線が空きます",
                              top.name, top.mbps))
        }
        return out
    }

    func reloadRecent() {
        let f = SampleLog.dayFormatter()
        let today = f.string(from: Date())

        if today != tailDay || recent.isEmpty {
            tailDay = today
            recent = monitor.log.load(date: Date())
            tailOffset = SampleLog.fileSize(for: Date())
            return
        }
        let more = monitor.log.loadTail(date: Date(), from: &tailOffset)
        if !more.isEmpty { recent.append(contentsOf: more) }
    }

    // MARK: - 操作

    /// 「つなぎ直す」。切断を伴うので、押した本人に結果まで見せて完結させる。
    func reconnect() {
        guard busy == nil else { return }
        // 管理側で止められていれば実行しない（画面から消すだけでは足りない）
        guard Settings.Managed.allowsNetworkChange else {
            flash = "この操作は管理者によって無効にされています"
            return
        }
        let before = monitor.linkForDisplay
        busy = "つなぎ直しています…"
        flash = nil
        // 乗り換え先が分かっているなら、そのAPへ直接張り替える（一番速い）
        let target = monitor.better.flatMap { b in
            b.ap.bssid.flatMap { monitor.scanner.cwNetwork(bssid: $0) }
        }
        let current = before.bssid.flatMap { monitor.scanner.cwNetwork(bssid: $0) }
            ?? before.ssid.flatMap { monitor.scanner.cwNetwork(for: $0) }

        Roamer.forceRoam(target: target, current: current, progress: { [weak self] s in
            self?.busy = s
        }, done: { [weak self] r in
            guard let self else { return }
            guard r.ok else {
                self.busy = nil
                self.flash = r.message.isEmpty
                    ? "つなぎ直せませんでした。Wi-Fiの状態をご確認ください"
                    : r.message
                return
            }
            // 直後の値は安定しないので、測り直してから結果を出す
            self.monitor.deepCheck(progress: { [weak self] _ in
                self?.busy = "接続後の状態を確認しています…"
            }, done: { [weak self] in
                guard let self else { return }
                let after = self.monitor.linkForDisplay
                self.busy = nil
                self.refresh(); self.reloadRecent()
                let d = after.rssi - before.rssi
                let took = String(format: "%.1f秒", r.seconds)
                if d >= 5 {
                    self.flash = "より強いWi-Fiに切り替わりました（\(d)dB 改善・\(took)）"
                } else if after.bssid != before.bssid {
                    self.flash = "別のWi-Fi機器につなぎ直しました（\(took)）"
                } else {
                    self.flash = "同じ機器に戻りました。ここが一番強いようです（\(took)）"
                }
            })
        })
    }

    /// クイックスキャン。近隣APの再スキャンと各区間の測り直しを一度に行う。
    func quickScan() {
        guard busy == nil else { return }
        busy = "調べています…"
        flash = nil
        monitor.deepCheck(progress: { [weak self] s in
            self?.busy = s
        }, done: { [weak self] in
            self?.busy = nil
            self?.refresh(); self?.reloadRecent()
        })
    }

    /// 実効速度テスト。回線を飽和させるので手動でしか呼ばない。
    func runSpeedTest() {
        guard busy == nil else { return }
        busy = "実効速度を測っています…（約20秒）"
        flash = nil
        DispatchQueue.global().async {
            let r = NetProbe.speedTest()
            DispatchQueue.main.async {
                self.busy = nil
                self.speed = r
                self.speedAt = Date()
                if r.ok {
                    self.appendSpeedLog(r)
                    self.reloadSpeedHistory()
                    self.refresh()
                } else {
                    self.flash = "速度を測定できませんでした。ネットワークが不安定な可能性があります"
                }
            }
        }
    }

    /// 過去のスピードテスト結果。場所ごとの比較に使えるので履歴を残す。
    func reloadSpeedHistory() {
        let f = ISO8601DateFormatter()
        speedHistory = monitor.log.loadSpeedTests().compactMap { line -> SpeedRecord? in
            guard let d = line.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let atS = j["at"] as? String, let at = f.date(from: atS) else { return nil }
            return SpeedRecord(at: at,
                               down: (j["down"] as? Double) ?? -1,
                               up: (j["up"] as? Double) ?? -1,
                               ssid: (j["ssid"] as? String) ?? "")
        }.suffix(6).reversed()
    }

    /// スピードテストは頻度が全く違うので、通常の観測ログとは別ファイルに残す。
    private func appendSpeedLog(_ r: NetProbe.SpeedResult) {
        // 文字列を手で組むと、SSID に " や \ や改行が入った瞬間に行が壊れる
        // （SSIDは任意のバイト列を取りうる）。無限大やNaNでも壊れる。
        func finite(_ v: Double?) -> Double {
            guard let v, v.isFinite else { return -1 }
            return v
        }
        let obj: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "down": finite(r.downMbps),
            "up": finite(r.upMbps),
            "rpm": finite(r.rpm),
            "ssid": monitor.linkForDisplay.ssid ?? "",
            "bssid": monitor.linkForDisplay.bssid ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let line = String(data: data, encoding: .utf8) else { return }
        monitor.log.appendSpeedTest(line)
    }

    var speedSummary: String? {
        guard let r = speed, let at = speedAt else { return nil }
        let f = SampleLog.dayFormatter(); f.dateFormat = "HH:mm"
        guard let d = r.downMbps else { return "測定失敗（\(f.string(from: at))）" }
        var t = String(format: "下り %.0f Mbps", d)
        if let u = r.upMbps { t += String(format: " / 上り %.0f Mbps", u) }
        return t + "（\(f.string(from: at))時点）"
    }

    /// ローカルネットワークの設定を開く。位置情報と同じく、断ると自力で戻れない。
    func openLocalNetworkSettings() {
        for s in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
                  "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"] {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    /// 位置情報の設定を開く。許可はアプリ側からは戻せないので、場所まで案内する。
    func openLocationSettings() {
        // 「システム設定」以降は識別子が変わっている。新しい方から順に試す。
        for s in ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
                  "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"] {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    /// 別のWi-Fiへ切り替える。混雑から逃げるための主操作。
    func switchTo(_ c: NetworkCandidate) {
        guard busy == nil else { return }
        guard Settings.Managed.allowsNetworkChange else {
            flash = "この操作は管理者によって無効にされています"
            return
        }
        busy = "\(c.ssid) に切り替えています…"
        flash = nil
        NetworkSwitcher.connect(ssid: c.ssid,
                                network: monitor.scanner.cwNetwork(for: c.ssid)) { [weak self] ok, msg in
            guard let self else { return }
            guard ok else {
                self.busy = nil
                self.flash = "\(c.ssid) に切り替えられませんでした。\(msg)"
                return
            }
            self.monitor.deepCheck(progress: { [weak self] _ in
                self?.busy = "切替後の状態を確認しています…"
            }, done: { [weak self] in
                guard let self else { return }
                self.busy = nil
                self.refresh(); self.reloadRecent()
                self.flash = "\(c.ssid) に切り替えました"
            })
        }
    }

    /// 主ボタンの実行。原因によって中身が変わる。
    func runPrimary() {
        switch snap.primary {
        case .reconnect:     reconnect()
        case .switchNetwork: page = .switching
        case .report:        exportReport()
        case .none:          break
        }
    }

    /// 実行中表示が解除されないと全ボタンが押せなくなる。最後の砦として強制解除する。
    private func armBusyWatchdog() {
        busyWatchdog?.cancel()
        guard busy != nil else { busyWatchdog = nil; return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.busy != nil else { return }
            self.busy = nil
            self.flash = "処理が完了しませんでした。もう一度お試しください"
        }
        busyWatchdog = w
        // つなぎ直しは最悪62秒、その後の確認に45秒かかる。90秒だと
        // 本当の結果より先に「完了しませんでした」を出してしまう。
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: w)
    }

    func clearFlash() { flash = nil }

    /// 検証用に画面状態を直接差し替える。実ネットワークを再現できない状況
    /// （回線障害・未接続など）でも描画を確認できるようにするため。
    func applyForTest(_ s: Snapshot, recent: [Sample] = [], flash: String? = nil) {
        self.snap = s
        self.recent = recent
        self.flash = flash
    }

    func exportReport() {
        let p = NSSavePanel()
        let f = SampleLog.dayFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        p.nameFieldStringValue = "wifi-report-\(f.string(from: Date())).txt"
        let body = monitor.log.report(samples: monitor.log.load(date: Date()),
                                      title: "今日",   // 他の日は履歴ウィンドウの期間から
                                      usableAPs: monitor.scanner.usablePhysicalAPs())
        NSApp.activate(ignoringOtherApps: true)
        p.begin { r in
            guard r == .OK, let url = p.url else { return }
            do {
                try body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // 黙って消えると、渡したつもりのファイルが無い状態になる
                let a = NSAlert()
                a.messageText = "書き出せませんでした"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }
}
