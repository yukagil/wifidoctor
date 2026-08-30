import Foundation

/// 1時間ぶんのまとめ。
///
/// 「今日は遅かった」まで分かっても打つ手はない。
/// 「10時から12時が遅かった」まで分かって初めて、次の会議をどこに置くか決められる。
struct HourSummary: Identifiable {
    var id: Int { hour }
    var hour: Int
    var seconds: TimeInterval
    /// ふだんの点数（時間で重み付けした中央値）。柱の高さになる。
    var score: Int
    var level: Level
    /// 崩れていた時間。柱の下部を塗る割合と、ホバー時の説明に使う。
    var badSeconds: TimeInterval
    var badRatio: Double
    /// いちばん長く続いた不調と、その長さ。
    var topProblem: Verdict?
    var problemSeconds: TimeInterval
    /// この時間、どこ（どのAP・接続先）に何秒つないでいたか。下の比較表と突き合わせる。
    var byKey: [String: TimeInterval]

    /// 記録が短すぎる時間帯は判断材料にならないので、色を付けない。
    var hasData: Bool { seconds >= 60 }
    var minutes: Int { Int(seconds / 60) }
}

enum HourReport {

    /// 0時から23時までを必ず24個返す。記録が無い時間帯も「無い」と示したい。
    /// 抜けを詰めて描くと、空白が「良かった時間」に見えてしまう。
    static func hours(_ samples: [Sample],
                      by grouping: PlaceGrouping = .ap,
                      durations: [TimeInterval]? = nil) -> [HourSummary] {
        let durs = durations ?? Sample.durations(samples)
        let cal = Calendar.current

        struct Acc {
            var seconds: TimeInterval = 0
            var score: [(Double, TimeInterval)] = []
            var badSeconds: TimeInterval = 0
            var byVerdict: [Verdict: TimeInterval] = [:]
            var byKey: [String: TimeInterval] = [:]
        }
        var acc = [Int: Acc]()

        for (i, s) in samples.enumerated() {
            // つながっていなかった時間は「調子」ではない。点数0で赤く塗ると、
            // 席を外していただけの時間が不調として記憶される。
            guard s.associated, s.scoreVerdict != .offline else { continue }
            let h = cal.component(.hour, from: s.at)
            let d = durs[i]

            acc[h, default: Acc()].seconds += d
            acc[h, default: Acc()].score.append((Double(s.score), d))
            let v = s.scoreVerdict ?? .ok
            acc[h, default: Acc()].byVerdict[v, default: 0] += d
            if v.isProblem { acc[h, default: Acc()].badSeconds += d }
            if let key = grouping == .ap ? s.bssid : s.ssid, !key.isEmpty {
                acc[h, default: Acc()].byKey[key, default: 0] += d
            }
        }

        return (0..<24).map { h in
            guard let a = acc[h], a.seconds > 0 else {
                return HourSummary(hour: h, seconds: 0, score: 0, level: .offline,
                                   badSeconds: 0, badRatio: 0,
                                   topProblem: nil, problemSeconds: 0, byKey: [:])
            }
            let mid = Int((PlaceReport.quantile(a.score, 0.5) ?? 0).rounded())
            let worst = a.byVerdict.filter { $0.key.isProblem }.max { $0.value < $1.value }
            return HourSummary(
                hour: h,
                seconds: a.seconds,
                score: mid,
                level: mid >= 80 ? .good : (mid >= 60 ? .fair : .bad),
                badSeconds: a.badSeconds,
                badRatio: a.badSeconds / a.seconds,
                topProblem: worst?.key,
                problemSeconds: worst?.value ?? 0,
                byKey: a.byKey)
        }
    }

    /// いちばん調子が悪かった時間帯。
    /// 数分しか記録が無い時間帯を「今日いちばん悪かった」と言うと、
    /// 席を立っていただけの時間を悪者にしてしまう。十分な記録があるものだけを候補にする。
    /// 期間が延びれば必要な記録も延びる（7日なら「毎日10分」を求める）。
    static func worst(_ hours: [HourSummary], days: Int = 1) -> HourSummary? {
        let need = 600.0 * Double(max(1, days))
        return hours.filter { $0.seconds >= need && $0.level != .good }
            .min { $0.score < $1.score }
    }
}
