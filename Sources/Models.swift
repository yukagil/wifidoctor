import Foundation

/// 1回の観測。リンク層(CoreWLAN)とネットワーク層(probe)をまとめて1レコードにする。
struct Sample: Codable {
    var at: Date
    // link
    var associated: Bool
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var noise: Int
    var txRate: Double
    var channel: Int
    var width: Int          // MHz
    var band: Int           // 2 or 5 or 6
    var phy: String
    // network
    var gwRTT: Double?      // ms (avg)
    var gwJitter: Double?   // ms (stddev)
    var gwLoss: Double?     // %
    var netRTT: Double?     // ms to 1.1.1.1
    var netLoss: Double?
    var dnsMS: Double?
    // 実際に流れた量（受動観測）。スピードテスト無しで帯域の下限が分かる。
    var rxMbps: Double?
    var txMbps: Double?
    // verdict
    var score: Int
    var verdict: String     // Verdict.rawValue

    var snr: Int { rssi - noise }
    var scoreVerdict: Verdict? { Verdict(rawValue: verdict) }
}

enum Verdict: String, Codable, CaseIterable {
    case ok          = "OK"
    case sticky      = "STICKY"       // 遠いAPを掴んだまま
    case congested   = "CONGESTED"    // 電波は良いが電波時間の奪い合い
    case weak        = "WEAK"         // 単純に電波が弱い(近くに良いAPも無い)
    case isp         = "ISP"          // AP以降が遅い
    case dns         = "DNS"          // 名前解決が遅い
    case selfTraffic = "SELF_TRAFFIC"  // このMac自身の通信で回線を埋めている
    case macBusy     = "MAC_BUSY"      // 回線は正常だが、Mac自体が重い
    case measuring   = "MEASURING"     // 接続直後などで、まだ一度も測れていない
    case noInternet  = "NO_INTERNET"   // Wi-Fiには繋がっているが外に出られない
    case offline     = "OFFLINE"

    var label: String {
        switch self {
        case .ok:        return "良好"
        case .sticky:    return "遠いAPを掴んでいる"
        case .congested: return "APが混雑"
        case .weak:      return "電波が弱い"
        case .isp:       return "AP以降(回線)が遅い"
        case .dns:       return "DNSが遅い"
        case .selfTraffic: return "このMacの通信で混雑"
        case .macBusy:   return "Macの負荷が高い"
        case .measuring: return "確認中"
        case .noInternet: return "インターネットに出られません"
        case .offline:   return "未接続"
        }
    }

    /// メニューに出す具体的な打ち手。
    var advice: String {
        switch self {
        case .ok:        return "問題ありません。"
        case .sticky:    return "より強いAPが近くにあります。[強制ローミング] で掴み直してください。"
        case .congested: return "電波は良好なのに遅延が出ています。APの利用者過多か干渉です。別の会議室/別バンドへ移動するか、有線・テザリングを検討してください。"
        case .weak:      return "APから遠すぎます。物理的にAPへ近づいてください。近くに代わりのAPは見つかりません。"
        case .isp:       return "自分〜AP間は正常です。原因は社内NW/ISP側なので情シスへ連携してください（［レポートを書き出す］の結果を添付）。"
        case .dns:       return "DNSサーバの応答が遅いです。DNSを 1.1.1.1 / 8.8.8.8 に変更すると改善する可能性があります。"
        case .selfTraffic: return "このMac自身が大量に通信しています。転送やバックアップが終わるまで待つか、一時停止してください。"
        case .macBusy:   return "回線は正常です。CPUやメモリの負荷で動作が重くなっています。"
        case .measuring: return "接続したばかりです。最初の測定が終わるまで少しお待ちください。"
        case .noInternet: return "サインインが必要なWi-Fiかもしれません。ブラウザで任意のページを開いて確認してください。"
        case .offline:   return "Wi-Fiに接続されていません。"
        }
    }

    /// 原因を普段の言葉で。レポートの文に埋め込んで使う。
    /// 「STICKY」や「遠いAPを掴んでいる」では、読む人が何を直せばいいのか決められない。
    var plainCause: String {
        switch self {
        case .congested:   return "混み合っている"
        case .sticky:      return "遠いWi-Fiにつながったまま"
        case .weak:        return "電波が弱い"
        case .isp:         return "その先の回線が遅い"
        case .dns:         return "ページの表示が遅い"
        case .selfTraffic: return "このMacの通信で詰まっている"
        case .macBusy:     return "Macが重い"
        case .noInternet:  return "外に出られない"
        default:           return "調子が悪い"
        }
    }

    /// 通知を出すべき異常か。
    /// 通知や「問題あり」集計の対象か。
    /// macBusy は回線の問題ではないので、Wi-Fiの不調としては数えない。
    var isProblem: Bool {
        self != .ok && self != .offline && self != .measuring && self != .macBusy
    }
}

extension Sample {
    /// 各記録が代表する時間の長さ。次の記録との差から求める。
    /// 計測間隔は状況で変わるので「1件=5秒」と決め打ちできない。
    /// スリープ等で記録が飛んだ区間を実時間として数えないよう上限を設ける。
    static func durations(_ samples: [Sample]) -> [TimeInterval] {
        guard samples.count > 1 else { return samples.isEmpty ? [] : [5] }

        var deltas: [TimeInterval] = []
        for i in 0..<(samples.count - 1) {
            deltas.append(max(0, samples[i + 1].at.timeIntervalSince(samples[i].at)))
        }
        // 空白の上限。中央値だけから決めると、調子が良いときだけ間隔が伸びる
        // （Monitor は安定すると 12秒、バッテリーなら 18秒まで空ける）ぶんが
        // 頭打ちに掛かり、良かった時間だけが選択的に削られて稼働時間が過少になる。
        // 設計上の最大間隔（18秒）の倍を下限に置く。
        let sorted = deltas.sorted()
        let median = sorted[sorted.count / 2]
        let cap = min(120, max(40, median * 3))

        var out = deltas.map { min($0, cap) }
        out.append(min(median, cap))     // 最後の記録は直近の間隔ぶんとみなす
        return out
    }

    static func totalSeconds(_ samples: [Sample]) -> TimeInterval {
        durations(samples).reduce(0, +)
    }

    /// 記録を「セッション」に切る。大きな空白で区切られたひと続きの観測。
    static func sessions(_ samples: [Sample], gap: TimeInterval = 300) -> [[Sample]] {
        guard !samples.isEmpty else { return [] }
        var out: [[Sample]] = []
        var cur: [Sample] = [samples[0]]
        for s in samples.dropFirst() {
            if let last = cur.last, s.at.timeIntervalSince(last.at) > gap {
                out.append(cur); cur = [s]
            } else {
                cur.append(s)
            }
        }
        out.append(cur)
        return out
    }

    /// 集計に使える記録だけを残す。
    ///
    /// 蓋を閉じている間も macOS は15〜18分おきに短時間だけ起きる（dark wake）。
    /// そこで数件だけ記録が残るが、これは低電力状態でWi-Fiが復帰しきる前の値で、
    /// 利用者が使っていた時間ではない。連続測定と同じ重みで平均に混ぜると
    /// 実態より大幅に低く出る（実データで 61点 → 37点）。
    ///
    /// 「大きな空白に挟まれた、ごく短いひと続き」をまとめて落とす。
    /// 孤立した1件だけを見る方式では、dark wake中に2〜3件まとまって
    /// 記録された場合を取りこぼす（実データで57件中26件しか落とせなかった）。
    static func representative(_ samples: [Sample],
                               isolationGap: TimeInterval = 300,
                               minSessionSeconds: TimeInterval = 60) -> [Sample] {
        let all = sessions(samples, gap: isolationGap)
        guard all.count > 1 else { return samples }   // 区切りが無いならそのまま
        var out: [Sample] = []
        for s in all {
            guard let first = s.first, let last = s.last else { continue }
            let span = last.at.timeIntervalSince(first.at)
            if span < minSessionSeconds { continue }   // 使っていた時間とは言えない
            out.append(contentsOf: s)
        }
        // 全部落ちてしまうなら、判断材料が無いので元を返す
        return out.isEmpty ? samples : out
    }

    static func averageScore(_ samples: [Sample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0.0) { $0 + Double($1.score) } / Double(samples.count)
    }
}

/// スキャンで見えた近隣AP。
struct SeenAP {
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var channel: Int
    var band: Int
    var isCurrent: Bool
    var secure: Bool = true      // 暗号化あり＝パスワードが要る
}
