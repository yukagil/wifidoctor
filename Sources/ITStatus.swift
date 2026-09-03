import Foundation

/// 情シスに「いまどうなっているの？」と聞かれたときに、そのまま貼って返せるテキスト。
///
/// 1日分のレポート（`SampleLog.report`）とは用途が違う。
/// あちらは腰を据えて読む資料で、ファイルにして渡すもの。
/// こちらはチャットに貼る返信なので、**画面をスクロールせずに読める長さ**に収める。
///
/// 入れるものは「情シスが最初に聞くこと」に絞る:
/// 端末が何か・どのAPにつないでいるか・いま何が起きているか・いつからか・
/// 端末側で何を切り分け済みか。ここが埋まっていないと、必ず聞き返しになる。
enum ITStatus {

    /// 生きた計測オブジェクトから切り離して、値だけで組み立てられるようにする。
    /// こうしておかないと、実際のWi-Fiを用意しないと文面を検証できない。
    struct Input {
        var now = Date()
        var appVersion = ""
        var os = ""
        var model = ""
        var mac: String?
        var timeZone = TimeZone.current.identifier

        var associated = false
        var ssid: String?
        var apLabel: String?          // 呼び名。付いていなければ nil
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
        var gwRTT: Double?
        var gwJitter: Double?
        var gwLoss: Double?
        var wanRTT: Double?
        var dnsMS: Double?

        var vpn: String?
        var cpuPercent: Double = 0
        var ownMbps: Double = 0
        var macLine = ""
        var macWarn = false
        var usableAPs = 0
        var coChannel = 0
        var locationDenied = false

        /// 直近の記録。`window` の分だけ見る。
        var recent: [Sample] = []
    }

    /// 直近どれだけを「いま」として見るか。
    /// 短すぎると数分前の不調を落とし、長すぎると「いまの状況」ではなくなる。
    static let window: TimeInterval = 3600

    static func text(_ i: Input) -> String {
        let tf = SampleLog.dayFormatter(); tf.dateFormat = "HH:mm:ss"
        let stamp = SampleLog.dayFormatter(); stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var out = "【Wi-Fi の状況】\(stamp.string(from: i.now)) (\(i.timeZone))\n"

        // 端末。情シスは MAC でコントローラのログを引く。これが無いと突き合わせが始まらない。
        var device = "端末: "
        device += [i.model, i.os].filter { !$0.isEmpty }.joined(separator: " / ")
        if let m = i.mac { device += " / Wi-Fi MAC \(m)" }
        out += device + "\n"

        // 接続先
        out += "接続: " + connection(i) + "\n"

        // いまの判定
        out += "状態: \(i.verdict.label)"
        if i.associated && i.verdict != .measuring { out += "（\(i.score)点）" }
        if let since = i.apSince, i.associated {
            let m = Int(i.now.timeIntervalSince(since) / 60)
            if m >= 1 { out += " / このAPに接続して \(m)分" }
        }
        out += "\n"

        // 実測値。端末→AP と AP以降を分けて書く。ここが切り分けの本体。
        out += "\n■ いまの計測値\n"
        out += "  端末→AP   " + hop(i) + "\n"
        out += "  AP以降    " + upstream(i) + "\n"
        out += "  このMac   " + mac(i) + "\n"
        if let v = i.vpn { out += "  VPN       \(v) 経由（遅延はVPNの分を含みます）\n" }

        // 直近の推移
        out += "\n" + recentSection(i, tf: tf)

        // 申し送り。レポートと同じ判断を使う。別々に書くと言うことが食い違う。
        let windowed = inWindow(i)
        let durations = Sample.durations(windowed)
        var byVerdict: [String: TimeInterval] = [:]
        for (n, s) in windowed.enumerated() where n < durations.count {
            byVerdict[s.verdict, default: 0] += durations[n]
        }
        let advice = SampleLog.advice(byVerdict: byVerdict,
                                      total: Sample.totalSeconds(windowed),
                                      usableAPs: i.usableAPs)
        if !advice.isEmpty {
            out += advice.replacingOccurrences(of: "\n■ 情シスへの申し送り\n",
                                               with: "\n■ 確認をお願いしたいこと\n")
            out += "\n"
        }

        // 渡す本人が、何を渡すのかを分かった上で送れるようにする。
        // 知らずに提出させるのが一番まずい。
        out += "\n※ 端末側から見える範囲の記録です。\n"
        out += "   含まれるもの: 接続したWi-Fi名、AP（BSSID・呼び名）、端末のMACアドレス、時刻。\n"
        out += "※ さらに詳しい1日分の記録は、アプリの［レポートを書き出す］で出せます。\n"
        out += "（\(i.appVersion)）\n"
        return out
    }

    // MARK: - 各行

    private static func connection(_ i: Input) -> String {
        guard i.associated else { return "接続していません" }
        if i.locationDenied {
            return "接続中（位置情報の許可が無いため、Wi-Fi名とAPを識別できていません）"
                 + " / ch\(i.channel) (\(i.band)GHz) / RSSI \(i.rssi)dBm"
        }
        var t = ""
        if let s = i.ssid { t += "SSID \"\(s.safeForText)\"" }
        else {
            // 接続しているのに名前だけ読めないのは、位置情報の許可が無い場合。
            // 理由を書かないと、受け取った側は端末の異常だと読む。
            t += "Wi-Fi名を取得できていません（位置情報の許可が要ります）"
        }
        if let b = i.bssid {
            let name = i.apLabel.map { "\($0.safeForText) (\(b))" } ?? b
            t += " / AP \(name)"
        }
        t += " / ch\(i.channel)"
        if i.band > 0 { t += " (\(i.band)GHz" + (i.width > 0 ? " \(i.width)MHz" : "") + ")" }
        t += " / RSSI \(i.rssi)dBm"
        if i.noise < 0 { t += "（雑音 \(i.noise)dBm）" }
        if i.txRate > 0 { t += " / リンク \(Int(i.txRate))Mbps" }
        if !i.phy.isEmpty { t += " \(i.phy)" }
        return t
    }

    private static func hop(_ i: Input) -> String {
        guard let rtt = i.gwRTT else { return "測れていません（APまで応答なし）" }
        var t = String(format: "応答 %.1fms", rtt)
        if let j = i.gwJitter { t += String(format: " / ゆらぎ %.1fms", j) }
        if let l = i.gwLoss { t += String(format: " / とりこぼし %.1f%%", l) }
        if i.coChannel > 0 { t += " / 同じチャンネル付近に他 \(i.coChannel)台" }
        if i.usableAPs == 1 { t += " / この場所で使えるAPは1台のみ" }
        return t
    }

    private static func upstream(_ i: Input) -> String {
        var parts: [String] = []
        if let w = i.wanRTT { parts.append(String(format: "外部への応答 %.0fms", w)) }
        else { parts.append("外部へ到達できていません") }
        if let d = i.dnsMS { parts.append(String(format: "名前解決 %.0fms", d)) }
        return parts.joined(separator: " / ")
    }

    private static func mac(_ i: Input) -> String {
        var t = String(format: "CPU %.0f%%", i.cpuPercent)
        if i.ownMbps > 0.1 { t += String(format: " / このMacの通信 %.1fMbps", i.ownMbps) }
        // Mac側を疑わなくてよい、と言い切れるときだけ言う。
        // 根拠なく「端末は問題ありません」と書くと、切り分けを1周やり直させることになる。
        if !i.macWarn {
            t += " / 端末側の負荷は原因ではありません"
        } else if !i.macLine.isEmpty {
            t += " / \(i.macLine.safeForText)"
        }
        return t
    }

    /// `window` の分だけ切り出す。
    private static func inWindow(_ i: Input) -> [Sample] {
        let from = i.now.addingTimeInterval(-window)
        return Sample.representative(i.recent.filter { $0.at >= from })
    }

    private static func recentSection(_ i: Input, tf: DateFormatter) -> String {
        let mins = Int(window / 60)
        var out = "■ 直近\(mins)分\n"
        let samples = inWindow(i)
        guard !samples.isEmpty else {
            return out + "  記録がありません（起動したばかりです）\n"
        }
        let durations = Sample.durations(samples)
        let total = Sample.totalSeconds(samples)
        var bad: TimeInterval = 0
        for (n, s) in samples.enumerated() where n < durations.count {
            if Verdict(rawValue: s.verdict)?.isProblem ?? false { bad += durations[n] }
        }
        let pct = total > 0 ? Int((bad / total * 100).rounded()) : 0
        out += "  観測 \(Int((total / 60).rounded()))分 / うち不調 "
        out += "\(Int((bad / 60).rounded()))分（\(pct)%）\n"

        let spans = SampleLog.problemSpans(samples, durations).filter { $0.seconds >= 30 }
        // 長かったものから3件。全部並べるとチャットに貼れる長さを超える。
        for sp in spans.sorted(by: { $0.seconds > $1.seconds }).prefix(3)
                       .sorted(by: { $0.from.at < $1.from.at }) {
            out += "  " + sp.line(tf) + "\n"
        }
        if spans.count > 3 { out += "  （ほかに30秒以上の不調が \(spans.count - 3) 回）\n" }
        if spans.isEmpty && bad > 0 { out += "  （30秒以上続いた不調はありません）\n" }
        return out
    }
}
