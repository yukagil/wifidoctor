import Foundation

/// 何を1行として比べるか。
///
/// 同じ接続先（SSID）でもAPが違えば体感は別物だし、逆に「この接続先はどこでも遅い」は
/// AP単位で見ていると気づけない。どちらか一方では判断できないので両方持つ。
///
/// 「回線」とは呼ばない。この言葉はアプリの中で既に「AP以降（ISP側）」を指しており、
/// 同じ語を別の意味で使うと、どこの話をしているのか読む人に分からなくなる。
enum PlaceGrouping {
    case ap        // AP（機器・BSSID）ごと
    case network   // 接続先（Wi-Fi名・SSID）ごと

    var title: String { self == .ap ? "AP（機器）ごと" : "接続先（Wi-Fi名）ごと" }
    var unitWord: String { self == .ap ? "AP" : "接続先" }
}

/// 「ふだん」と「悪いとき」の対。
///
/// 平均や中央値だけを出すと、"ほとんど快適だが時々完全に崩れる" 場所と
/// "常にそこそこ" の場所が同じ数字になる。会議を壊すのは前者なので、
/// 代表値と裾を必ず並べて出す。
struct Typical {
    var mid: Double?    // 中央値＝ふだん
    var bad: Double?    // 裾＝悪いとき（遅延側は p95、点数は p10）

    static let none = Typical(mid: nil, bad: nil)
    var known: Bool { mid != nil }
}

/// 比較表の1行。
struct PlaceSummary: Identifiable {
    var id: String { key }
    var key: String           // BSSID か SSID
    var name: String          // 付けた呼び名。無ければ SSID や短縮ID
    var sub: String           // 補足（APなら接続先の名前、接続先なら「AP 3台」）
    var seconds: TimeInterval

    /// 点数。mid＝ふだん（中央値）、bad＝悪いとき（下位10%）。
    var score: Typical
    var level: Level
    /// 調子が悪かった時間の合計と、その連続の最長。
    /// 「99分崩れた」より「一度に3分20秒切れた」の方が会議の実感に近い。
    var badSeconds: TimeInterval
    var worstRun: TimeInterval
    /// いちばん長く続いた不調。
    var topProblem: Verdict?
    var problemSeconds: TimeInterval

    var rtt: Typical
    var jitter: Typical
    /// 5発中1発でも落ちた計測の割合。損失率の中央値は常に0になって何も区別できない。
    var lossRatio: Double?
    var rssi: Int?

    /// つながっていた時間帯。上の帯と突き合わせるために持つ。
    var hours: Set<Int>

    /// 数分しか記録が無い行は、点数も中央値も意味を持たない。
    /// ローミングの一瞬を切り出して「この場所は遅い」と書かないための線。
    static let minSeconds: TimeInterval = 120
    var enough: Bool { seconds >= PlaceSummary.minSeconds }

    var minutes: Int { Int(seconds / 60) }

    /// 「12〜14時、18〜20時」。いつそこに居たのかを行自身に書くための一言。
    var hourWord: String {
        let sorted = hours.sorted()
        guard !sorted.isEmpty else { return "" }
        var runs: [[Int]] = [[sorted[0]]]
        for h in sorted.dropFirst() {
            if h == (runs[runs.count - 1].last ?? -9) + 1 { runs[runs.count - 1].append(h) }
            else { runs.append([h]) }
        }
        return runs.map { $0.count == 1 ? "\($0[0])時" : "\($0[0])〜\($0[$0.count - 1])時" }
            .joined(separator: "、")
    }

    /// 「混み合っている時間が 99分（一度に最長 3分20秒）」。次の行動につながる一言。
    var detail: String {
        guard enough else { return "記録が短く、判定できません" }
        guard badSeconds > 0 else { return "崩れた時間はありませんでした" }
        let cause = topProblem.map { "\($0.plainCause)時間" } ?? "調子が悪い時間"
        return "\(cause)が \(PlaceReport.spanWord(badSeconds))"
            + (worstRun >= 30 ? "（一度に最長 \(PlaceReport.spanWord(worstRun))）" : "")
    }
}

enum PlaceReport {

    static func summaries(_ samples: [Sample],
                          by grouping: PlaceGrouping = .ap,
                          durations: [TimeInterval]? = nil) -> [PlaceSummary] {
        let durs = durations ?? Sample.durations(samples)
        let cal = Calendar.current

        struct Acc {
            var seconds: TimeInterval = 0
            var ssid = ""
            var bssids = Set<String>()
            /// 値とその時間の重み。分位数も時間で重み付けする（画面の他の数字と揃える）。
            var score: [(Double, TimeInterval)] = []
            var rtt: [(Double, TimeInterval)] = []
            var jitter: [(Double, TimeInterval)] = []
            var rssi: [(Double, TimeInterval)] = []
            var lossChecks = 0
            var lossEvents = 0
            var badSeconds: TimeInterval = 0
            var run: TimeInterval = 0
            var worstRun: TimeInterval = 0
            var byVerdict: [Verdict: TimeInterval] = [:]
            var hourSeconds: [Int: TimeInterval] = [:]
        }
        var acc: [String: Acc] = [:]

        for (i, s) in samples.enumerated() {
            // つながっていなかった時間を「その先に居た時間」として数えない。
            // OFFLINE の記録は直前の接続先を残したまま書かれるので、除かないと
            // 「0点なのに問題なし」の時間がその先の実績に混ざる。
            guard s.associated, s.scoreVerdict != .offline else { continue }
            let key: String? = grouping == .ap ? s.bssid : s.ssid
            guard let key, !key.isEmpty else { continue }
            let d = durs[i]

            // 辞書から取り出して書き戻すと、中の配列が二重参照になって毎回まるごと複製される
            // （記録が増えるほど二乗で遅くなる）。その場で足す形にしておく。
            acc[key, default: Acc()].seconds += d
            acc[key, default: Acc()].score.append((Double(s.score), d))
            if let ssid = s.ssid { acc[key, default: Acc()].ssid = ssid }
            if let b = s.bssid { acc[key, default: Acc()].bssids.insert(b) }
            if let v = s.gwRTT { acc[key, default: Acc()].rtt.append((v, d)) }
            if let v = s.gwJitter { acc[key, default: Acc()].jitter.append((v, d)) }
            acc[key, default: Acc()].rssi.append((Double(s.rssi), d))
            if let l = s.gwLoss {
                acc[key, default: Acc()].lossChecks += 1
                if l > 0 { acc[key, default: Acc()].lossEvents += 1 }
            }

            let v = s.scoreVerdict ?? .ok
            acc[key, default: Acc()].byVerdict[v, default: 0] += d
            if v.isProblem {
                acc[key, default: Acc()].badSeconds += d
                acc[key, default: Acc()].run += d
                if acc[key]!.run > acc[key]!.worstRun {
                    acc[key, default: Acc()].worstRun = acc[key]!.run
                }
            } else {
                acc[key, default: Acc()].run = 0
            }

            acc[key, default: Acc()].hourSeconds[cal.component(.hour, from: s.at), default: 0] += d
        }

        return acc.map { key, a -> PlaceSummary in
            let enough = a.seconds >= PlaceSummary.minSeconds
            let mid = quantile(a.score, 0.5)
            let badRatio = a.seconds > 0 ? a.badSeconds / a.seconds : 0
            let level: Level = !enough ? .offline
                : Phrase.level(score: Int(mid ?? 0), badRatio: badRatio)
            let worst = a.byVerdict.filter { $0.key.isProblem }.max { $0.value < $1.value }

            return PlaceSummary(
                key: key,
                name: (grouping == .ap ? (APNames.label(for: key) ?? key) : key).safeForText,
                // 呼び名を付けていなければ名前に短縮IDが入る。そこで繰り返さない。
                sub: grouping == .ap ? a.ssid : "AP \(a.bssids.count)台",
                seconds: a.seconds,
                score: enough ? Typical(mid: mid, bad: quantile(a.score, 0.10)) : .none,
                level: level,
                badSeconds: a.badSeconds,
                worstRun: a.worstRun,
                topProblem: worst?.key,
                problemSeconds: worst?.value ?? 0,
                rtt: enough ? Typical(mid: quantile(a.rtt, 0.5), bad: quantile(a.rtt, 0.95)) : .none,
                jitter: enough ? Typical(mid: quantile(a.jitter, 0.5),
                                         bad: quantile(a.jitter, 0.95)) : .none,
                lossRatio: (enough && a.lossChecks > 0)
                    ? Double(a.lossEvents) / Double(a.lossChecks) : nil,
                rssi: enough ? quantile(a.rssi, 0.5).map { Int($0.rounded()) } : nil,
                // 数十秒だけ掠めた時間帯まで「そこに居た」と書くと、上の帯と話が合わなくなる
                hours: Set(a.hourSeconds.filter { $0.value >= 60 }.keys))
        }
        .sorted { $0.seconds > $1.seconds }
    }

    /// 時間で重み付けした分位数。
    /// 件数で数えると、測る間隔が変わったときに短い時間の値が過大に効く。
    static func quantile(_ vs: [(Double, TimeInterval)], _ p: Double) -> Double? {
        guard !vs.isEmpty else { return nil }
        let sorted = vs.sorted { $0.0 < $1.0 }
        let total = sorted.reduce(0.0) { $0 + max(0, $1.1) }
        guard total > 0 else { return sorted[sorted.count / 2].0 }
        let target = total * p
        var run = 0.0
        for (v, w) in sorted {
            run += max(0, w)
            if run >= target { return v }
        }
        return sorted[sorted.count - 1].0
    }

    /// 「3分20秒」「99分」。短い時間を「0分」と書かないための整形。
    static func spanWord(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)秒" }
        if s < 600 { return s % 60 == 0 ? "\(s / 60)分" : "\(s / 60)分\(s % 60)秒" }
        if s < 3600 { return "\(s / 60)分" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)時間" : "\(h)時間\(m)分"
    }
}
