import Foundation
import CoreWLAN

/// 「今いる場所で、今より快適そうな別のWi-Fi」を出して、そこへ切り替える。
///
/// 混雑（CONGESTED）はつなぎ直しでは直らない。同じ混んだAPに戻るだけだから。
/// 有効な手はネットワークそのものを変えることなので、その導線をここで用意する。
enum NetworkSwitcher {

    /// このMacが過去に接続したことのあるSSID。
    /// パスワードがキーチェーンにあるので、これらだけがワンタップ切替の対象になる。
    static func preferredNetworks() -> [String] {
        let out = NetProbe.run("/usr/sbin/networksetup",
                               ["-listpreferredwirelessnetworks", LinkSampler.interfaceName],
                               timeout: 6)
        return out.split(separator: "\n")
            .dropFirst()                                   // 1行目は見出し
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 指定SSIDへ切り替える。
    ///
    /// CoreWLAN の associate を主経路にする。networksetup は失敗しても終了コード0を返し、
    /// エラーを標準出力に書くだけなので信頼できない（実測で -3900 を確認）。
    /// どちらも駄目なら、利用者がWi-Fiメニューから選べるよう案内する。
    static func connect(ssid: String, network: CWNetwork?,
                        completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global().async {
            var reasons: [String] = []

            // 1) CoreWLAN。既知のネットワークならキーチェーンの認証情報が使われる。
            if let n = network, let iface = CWWiFiClient.shared().interface() {
                do {
                    try iface.associate(to: n, password: nil)
                } catch {
                    reasons.append(Self.friendly(error))
                }
            } else {
                reasons.append("この場所でネットワークを見つけられませんでした")
            }

            if waitForAssociation(ssid) {
                DispatchQueue.main.async { completion(true, "") }
                return
            }

            // 2) networksetup。出力が空なら成功という仕様なので、出力の有無で見る。
            let out = NetProbe.run("/usr/sbin/networksetup",
                                   ["-setairportnetwork", LinkSampler.interfaceName, ssid],
                                   timeout: 25)
            let msg = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty { reasons.append(msg.replacingOccurrences(of: "\n", with: " ")) }

            let ok = waitForAssociation(ssid)
            DispatchQueue.main.async {
                completion(ok, ok ? "" : (reasons.first ?? "接続できませんでした"))
            }
        }
    }

    /// 実際にそのSSIDへ繋がるまで待つ。コマンドの戻り値は当てにならないので、
    /// 必ずリンクの状態そのもので確認する。
    private static func waitForAssociation(_ ssid: String, timeout: TimeInterval = 12) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let l = LinkSampler.read()
            if l.associated {
                // SSIDが読めない環境（位置情報未許可）では確認しようがないので、
                // 接続できていることだけを成功条件にする
                if l.ssid == nil || l.ssid == ssid { return true }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    private static func friendly(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case -3900: return "接続を拒否されました。メニューバーのWi-Fiから手動で選んでください"
        case -3903: return "パスワードが必要です"
        case -3905: return "このネットワークは見つかりませんでした"
        default:    return (error as NSError).localizedDescription
        }
    }

    /// スキャン結果から乗り換え候補を作る。
    /// 「電波が強い」だけでは混雑から逃げられないので、同一チャンネルのAP数（＝電波の
    /// 奪い合いの目安）とバンドを加味して並べる。
    /// 同じ物理APが出しているSSIDか。
    /// 1台のAPは複数のSSIDを流せる。その場合BSSIDは下位1オクテットだけが違う。
    /// 同じ無線機なので、そこへ移っても混雑は一切解消しない。
    static func sameRadio(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let x = a.split(separator: ":"), y = b.split(separator: ":")
        guard x.count == 6, y.count == 6 else { return false }
        return x.prefix(5).joined() == y.prefix(5).joined()
    }

    /// この場所で使える「物理AP」の台数。
    /// 1台のAPは複数SSIDを流すので、BSSIDをそのまま数えると台数を誤る。
    static func physicalAPCount(scan: [SeenAP], minRSSI: Int = -70) -> Int {
        var devices = Set<String>()
        for ap in scan where ap.rssi >= minRSSI {
            guard let b = ap.bssid else { continue }
            devices.insert(b.split(separator: ":").prefix(5).joined())
        }
        return devices.count
    }

    static func candidates(scan: [SeenAP], current: LinkInfo, known: [String]) -> [NetworkCandidate] {
        guard !scan.isEmpty else { return [] }
        let knownSet = Set(known)

        // SSIDごとに一番強いAPを代表にする
        var best: [String: SeenAP] = [:]
        for ap in scan {
            guard let ssid = ap.ssid, !ssid.isEmpty else { continue }
            if let e = best[ssid], e.rssi >= ap.rssi { continue }
            best[ssid] = ap
        }

        func crowding(_ ap: SeenAP) -> Int {
            scan.filter { $0.band == ap.band && abs($0.channel - ap.channel) <= 4 }.count - 1
        }
        let currentCrowding = current.associated
            ? scan.filter { $0.band == current.band && abs($0.channel - current.channel) <= 4 }.count - 1
            : 99

        var out: [NetworkCandidate] = []
        for (ssid, ap) in best {
            guard ssid != current.ssid else { continue }
            // 弱すぎるものは繋いでも悪化するだけなので落とす
            guard ap.rssi >= -80 else { continue }

            let c = crowding(ap)
            let connectable = knownSet.contains(ssid) || !ap.secure
            // 同じ無線機の別SSIDは、混雑対策としては無意味
            let sameDevice = sameRadio(ap.bssid, current.bssid)

            var reasons: [String] = []
            if sameDevice { reasons.append("同じ機器の別SSID・混雑は変わりません") }
            if c < currentCrowding { reasons.append("周りのWi-Fiが少なめ（\(c)台）") }
            if ap.rssi >= current.rssi + 8 { reasons.append("電波が強い") }
            if ap.band == 2 && current.band >= 5 { reasons.append("2.4GHz・速度は落ちるが空いている場合あり") }
            // 暗号化なしは「手軽」ではなく危険。名前を真似た偽のAPに一押しで
            // つながせないよう、長所として書かないし、おすすめにも回さない。
            let known = knownSet.contains(ssid)
            if !ap.secure { reasons.append("暗号化なし・通信が見られる可能性があります") }

            // 「今より良さそう」だけを推奨に回し、それ以外も情報として残す。
            // 候補を隠しすぎると「他にもあるはずだ」という不信につながる。
            let recommended = (c < currentCrowding || ap.rssi >= current.rssi + 8)
                && ap.rssi >= -75 && connectable && !sameDevice
                && (known || ap.secure)

            out.append(NetworkCandidate(
                ssid: ssid, rssi: ap.rssi, band: ap.band, channel: ap.channel,
                crowding: c,
                reason: reasons.isEmpty ? "\(ap.band)GHz" : reasons.joined(separator: " / "),
                recommended: recommended,
                connectable: connectable,
                secure: ap.secure,
                known: known))
        }

        // 推奨 → 繋げる → 混雑の少なさ → 電波の順
        out.sort {
            if $0.recommended != $1.recommended { return $0.recommended }
            if $0.connectable != $1.connectable { return $0.connectable }
            if $0.crowding != $1.crowding { return $0.crowding < $1.crowding }
            return $0.rssi > $1.rssi
        }
        return Array(out.prefix(8))
    }
}
