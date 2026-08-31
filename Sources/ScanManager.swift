import Foundation
import CoreWLAN

/// 近隣APのスキャン。
/// スキャンは他チャンネルへ電波を離すため通信が一瞬途切れる。会議中の通話を壊さないよう
/// 「自動では滅多に走らせず、電波が弱いときと手動要求時だけ」に絞る。
final class ScanManager {
    /// 1回のスキャンは必ず取りこぼす（チャンネルを順に回ってビーコンを拾うため、
    /// たまたま拾えないAPが出る）。macOSのWi-Fiメニューが多く見えるのは結果を
    /// 蓄積しているから。ここでも同じように、直近に見えたAPを貯めて足し合わせる。
    private var cache: [String: (ap: SeenAP, at: Date)] = [:]
    /// 接続に使うため CoreWLAN のオブジェクトも保持する。
    /// networksetup 経由の接続は失敗することがあるので、こちらを主経路にする。
    private var cwCache: [String: CWNetwork] = [:]
    /// BSSID単位でも持つ。特定のAPへ張り替えるには、そのAPのオブジェクトが要る。
    private var cwByBSSID: [String: CWNetwork] = [:]
    private let ttl: TimeInterval = 600

    var lastScan: [SeenAP] {
        let now = Date()
        return cache.values
            .filter { now.timeIntervalSince($0.at) < ttl }
            .map { $0.ap }
            .sorted { $0.rssi > $1.rssi }
    }
    private(set) var lastScanAt: Date?
    /// SSID が取れない(位置情報未許可)場合、同一SSID判定ができないので推定扱いになる。
    private(set) var ssidVisible = false
    /// スキャンは返ってきたのに、1台も名前が取れなかった。
    /// この状態だと切替候補は永久に空になるので、黙って「見つかりません」と出さない。
    var namesUnavailable: Bool { lastScanAt != nil && !ssidVisible }

    private let q = DispatchQueue(label: "wifidoctor.scan")

    func scan(current: LinkInfo, completion: @escaping ([SeenAP]) -> Void) {
        q.async {
            guard let i = CWWiFiClient.shared().interface() else {
                DispatchQueue.main.async { completion([]) }; return
            }
            var found: [SeenAP] = []
            var raw: [CWNetwork] = []
            if let nets = try? i.scanForNetworks(withSSID: nil) {
                raw = Array(nets)
                for n in nets {
                    let ch = n.wlanChannel
                    let band: Int = {
                        guard let ch else { return 0 }
                        switch ch.channelBand {
                        case .band2GHz: return 2
                        case .band5GHz: return 5
                        case .band6GHz: return 6
                        default: return ch.channelNumber <= 14 ? 2 : 5
                        }
                    }()
                    found.append(SeenAP(ssid: n.ssid,
                                        bssid: n.bssid,
                                        rssi: n.rssiValue,
                                        channel: ch?.channelNumber ?? 0,
                                        band: band,
                                        isCurrent: n.bssid != nil && n.bssid == current.bssid,
                                        secure: !n.supportsSecurity(.none)))
                }
            }
            found.sort { $0.rssi > $1.rssi }
            DispatchQueue.main.async {
                for n in raw {
                    if let b = n.bssid, !b.isEmpty { self.cwByBSSID[b] = n }
                    if let ssid = n.ssid, !ssid.isEmpty {
                        // SSIDごとに一番強いAPを接続先候補として覚えておく
                        if let e = self.cwCache[ssid], e.rssiValue >= n.rssiValue { continue }
                        self.cwCache[ssid] = n
                    }
                }
                self.merge(found)
                self.writeDiagnostic(found)
                completion(self.lastScan)
            }
        }
    }

    /// 取り込みと期限切れの整理。実機のスキャンを起こさずに検証できるよう分けてある。
    /// （テストが本物のスキャンを走らせると、利用者のWi-Fiを一瞬乱すうえ、
    ///   結果が環境で変わって検証にならない）
    func merge(_ found: [SeenAP], at now: Date = Date()) {
        for ap in found {
            let key = ap.bssid ?? "\(ap.ssid ?? "?")#\(ap.channel)"
            cache[key] = (ap, now)
        }
        cache = cache.filter { now.timeIntervalSince($0.value.at) < ttl }
        lastScanAt = now
        ssidVisible = cache.values.contains { $0.ap.ssid != nil }
    }

    /// スキャン結果の素の内容をファイルに残す。
    /// SSIDが取れるかどうかは権限のある実行環境でしか確かめられず、
    /// ここが nil だと乗り換え候補の機能が黙って何も出さなくなる。
    private func writeDiagnostic(_ found: [SeenAP]) {
        let f = SampleLog.dayFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var t = "最終スキャン \(f.string(from: Date()))\n"
        t += "取得数 \(found.count) / SSIDが取れた数 \(found.filter { $0.ssid != nil }.count)"
        t += " / BSSIDが取れた数 \(found.filter { $0.bssid != nil }.count)\n"
        for a in found.prefix(12) {
            t += "  ssid=\(a.ssid ?? "<nil>") bssid=\(a.bssid ?? "<nil>")"
            t += " rssi=\(a.rssi) ch\(a.channel) \(a.band)GHz\n"
        }
        try? t.write(to: SampleLog.dir.appendingPathComponent("lastscan.txt"),
                     atomically: true, encoding: .utf8)
    }

    /// SSIDに対応する CoreWLAN のネットワーク。接続に使う。
    func cwNetwork(for ssid: String) -> CWNetwork? { cwCache[ssid] }
    func cwNetwork(bssid: String) -> CWNetwork? { cwByBSSID[bssid] }

    /// 「今より明確に強い、乗り換え先になりうるAP」を返す。
    /// SSIDが見えるなら同一SSID内で厳密に比較。見えないなら同一バンドで推定する。
    func betterAP(than link: LinkInfo, marginDB: Int = 8) -> (ap: SeenAP, certain: Bool)? {
        guard !lastScan.isEmpty, link.associated else { return nil }
        if ssidVisible, let ssid = link.ssid {
            // 電波の強さだけで選ぶと、同じSSIDの 2.4GHz は届く距離が長いぶん常に強く見え、
            // 5GHz から 2.4GHz へ引き戻す助言になる（バンドステアリングと逆）。
            // 同じバンドか、上のバンドへ行く場合だけを候補にする。
            let same = lastScan.filter {
                $0.ssid == ssid && $0.bssid != link.bssid && $0.band >= link.band
            }
            if let best = same.first, best.rssi >= link.rssi + marginDB { return (best, true) }
            return nil
        }
        // 推定モード: SSIDが分からないので「同じバンドに十分強い別APがある」ことしか言えない
        let cand = lastScan.filter { $0.band == link.band && $0.rssi >= link.rssi + marginDB + 4 }
        if let best = cand.first { return (best, false) }
        return nil
    }

    /// この場所で実際に使える「物理AP」の台数。
    /// 1台のAPは複数のSSIDを流すので、BSSIDをそのまま数えると台数を誤る。
    /// 上位5オクテットが同じものは同一機器として1台に畳む。
    func usablePhysicalAPs(minRSSI: Int = -70) -> Int {
        NetworkSwitcher.physicalAPCount(scan: lastScan, minRSSI: minRSSI)
    }

    /// 自分のチャンネル付近に何台のAPが居るか = 電波時間の奪い合いの目安。
    func coChannelCount(_ link: LinkInfo) -> Int {
        lastScan.filter { $0.band == link.band && abs($0.channel - link.channel) <= 4 && !$0.isCurrent }.count
    }
}
