import Foundation

/// レポートの冒頭に置く「いまの状態」。
///
/// 読み手は情シスなので、平易な言い換えはむしろ邪魔になる。
/// RTT・ジッタ・ロス・RSSI といった素の言葉で、値をそのまま並べる。
/// アプリの判定（APが混雑、など）は内部の符号も添えて、
/// このアプリを知らない人でも他の資料と突き合わせられるようにする。
enum ITStatus {

    /// 生きた計測オブジェクトから切り離して、値だけで組み立てられるようにする。
    /// こうしておかないと、実際のWi-Fiを用意しないと文面を検証できない。
    struct Input {
        var now = Date()
        var os = ""
        var model = ""
        var mac: String?
        var timeZone = TimeZone.current.identifier

        var associated = false
        var ssid: String?
        var apLabel: String?          // 付けた呼び名。無ければ nil
        var bssid: String?
        var channel = 0
        var band = 0
        var width = 0
        var rssi = 0
        var noise = 0
        var txRate: Double = 0
        var phy = ""
        var apSince: Date?

        var verdict: Verdict = .measuring
        var score = 0
        var gwIP: String?
        var gwRTT: Double?
        var gwJitter: Double?
        var gwLoss: Double?
        var wanRTT: Double?
        var wanLoss: Double?
        var dnsMS: Double?

        var vpn: String?
        var cpuPercent: Double = 0
        var ownMbps: Double = 0
        var macWarn = false
        var usableAPs = 0
        var coChannel = 0
        var locationDenied = false
    }

    /// 端末そのものの素性。レポートの見出しに入れる。
    static func device(_ i: Input) -> String {
        var t = [i.model, i.os].filter { !$0.isEmpty }.joined(separator: " / ")
        // 情シスはこの MAC でコントローラ側のログを引く。無いと突き合わせが始まらない。
        if let m = i.mac { t += t.isEmpty ? "Wi-Fi MAC \(m)" : " / Wi-Fi MAC \(m)" }
        return t
    }

    static func head(_ i: Input) -> String {
        var out = "■ いまの状態\n"
        guard i.associated else { return out + "  未接続\n" }

        // 接続先。どのAPの話なのかが無いレポートは、受け取っても動けない。
        out += "  " + link(i) + "\n"
        out += "  " + state(i) + "\n"
        out += "  第一ホップ(端末→AP)  " + hop(i) + "\n"
        out += "  上流(AP以降)         " + upstream(i) + "\n"
        var env: [String] = []
        if i.coChannel > 0 { env.append("同一ch±4に他 \(i.coChannel)台") }
        if i.usableAPs > 0 { env.append("この地点で実用可能なAP \(i.usableAPs)台") }
        if let v = i.vpn { env.append("VPN \(v) 経由（上流の値はトンネル込み）") }
        if !env.isEmpty { out += "  周辺                 " + env.joined(separator: " / ") + "\n"}
        out += "  端末側               " + host(i) + "\n"
        return out
    }

    // MARK: - 各行

    private static func link(_ i: Input) -> String {
        if i.locationDenied || (i.ssid == nil && i.bssid == nil) {
            // 接続しているのに名前だけ読めないのは、位置情報の許可が無い場合。
            // 理由を書かないと、受け取った側は端末の異常だと読む。
            return "SSID/BSSID 取得不可（端末の位置情報が未許可）"
                 + " / ch\(i.channel) \(i.band)GHz / RSSI \(i.rssi)dBm"
        }
        var t = "SSID \"\(i.ssid?.safeForText ?? "-")\""
        if let b = i.bssid {
            t += " / BSSID \(b)"
            if let n = i.apLabel { t += "（\(n.safeForText)）" }
        }
        t += " / ch\(i.channel)"
        if i.band > 0 {
            t += " \(i.band)GHz"
            if i.width > 0 { t += " \(i.width)MHz" }
        }
        t += " / RSSI \(i.rssi)dBm"
        if i.noise < 0 { t += " / ノイズ \(i.noise)dBm / SNR \(i.rssi - i.noise)dB" }
        if i.txRate > 0 { t += " / リンクレート \(Int(i.txRate))Mbps" }
        if !i.phy.isEmpty { t += " \(i.phy)" }
        return t
    }

    private static func state(_ i: Input) -> String {
        // 内部の符号も出す。このアプリを知らない人が他の資料と突き合わせられるように。
        var t = "判定 \(i.verdict.rawValue)（\(i.verdict.label)）"
        if i.verdict != .measuring { t += " / スコア \(i.score)" }
        if let since = i.apSince {
            let m = Int(i.now.timeIntervalSince(since) / 60)
            if m >= 1 { t += " / 同一BSSIDに \(m)分 接続中" }
        }
        return t
    }

    private static func hop(_ i: Input) -> String {
        var t = ""
        if let ip = i.gwIP { t += "GW \(ip) " }
        guard let rtt = i.gwRTT else { return t + "応答なし" }
        t += String(format: "RTT %.1fms", rtt)
        if let j = i.gwJitter { t += String(format: " / ジッタ %.1fms", j) }
        if let l = i.gwLoss { t += String(format: " / ロス %.1f%%", l) }
        return t
    }

    private static func upstream(_ i: Input) -> String {
        var parts: [String] = []
        if let w = i.wanRTT {
            var t = String(format: "RTT %.0fms", w)
            if let l = i.wanLoss, l > 0 { t += String(format: " / ロス %.0f%%", l) }
            parts.append(t)
        } else {
            parts.append("到達不可")
        }
        parts.append(i.dnsMS.map { String(format: "DNS %.0fms", $0) } ?? "DNS 応答なし")
        return parts.joined(separator: " / ")
    }

    private static func host(_ i: Input) -> String {
        var t = String(format: "CPU %.0f%%", i.cpuPercent)
        t += String(format: " / 端末の送受信 %.1fMbps", i.ownMbps)
        // 端末側を疑わなくてよい、と言い切れるときだけ言う。
        // 根拠なく「端末は問題ありません」と書くと、切り分けを1周やり直させる。
        t += i.macWarn ? " / 端末側に負荷あり（下の判定を参照）" : " / 端末側の負荷は判定に影響なし"
        return t
    }
}
