import Foundation

/// 日付ごとの JSONL に追記していく。
/// 「遅かった瞬間」は後から再現できないので、記録が切り分けの生命線になる。
final class SampleLog {
    /// 記録の置き場所。動作確認のときだけ差し替えられるようにしてある。
    ///
    /// ここが固定だったせいで、保持期間のテストが「昨日の日付のファイル」を
    /// 作っては消す過程で、実際の記録を1日ぶん破壊した。
    /// テストが本物のデータに触れられる構造そのものが誤りなので、入口で差し替える。
    private(set) static var dir: URL = defaultDir()

    private static func defaultDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WiFiDoctor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 動作確認用の空のフォルダへ切り替える。テストの最初に必ず呼ぶ。
    @discardableResult
    static func useTemporaryDirectory() -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WiFiDoctorTest-\(UUID().uuidString)", isDirectory: true)
        cleanUpTemporaryDirectory()   // 自分が前に作ったぶんを孤児にしない
        // 落ちて残ったぶんも片付ける。同時に走っているものを壊さないよう、古いものだけ。
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        if let old = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
            let now = Date()
            for n in old where n.hasPrefix("WiFiDoctorTest-") {
                let u = base.appendingPathComponent(n)
                let at = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? now
                if now.timeIntervalSince(at) > 600 { try? FileManager.default.removeItem(at: u) }
            }
        }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        temporaryDir = tmp
        dir = tmp
        return tmp
    }

    private static var temporaryDir: URL?

    /// 自分が作った一時領域だけを片付ける。
    /// 起動時に他のぶんまで消すと、テストを2つ走らせたときに使用中のものを消す。
    static func cleanUpTemporaryDirectory() {
        guard let tmp = temporaryDir else { return }
        try? FileManager.default.removeItem(at: tmp)
        temporaryDir = nil
    }

    /// 本物の置き場所を使っていないこと。壊す側のテストはこれを確かめてから動く。
    static var isTemporary: Bool { dir != defaultDir() }

    private let enc: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private let dec: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    private let q = DispatchQueue(label: "wifidoctor.log")

    /// 日付の読み書きに使う書式。
    ///
    /// 利用者の暦法設定（和暦・仏暦など）を引き継ぐと、ファイル名が
    /// `0008-08-31.jsonl` のように変わる。同じ設定のままなら往復するが、
    /// 暦を切り替えた瞬間に古い名前が別の年として解釈され、
    /// 保持期間の削除が全部消す／一件も消さない のどちらかに振れる。
    static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current          // 「その日」は利用者の時間帯で切る
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    static func fileURL(for date: Date) -> URL {
        dir.appendingPathComponent("\(dayFormatter().string(from: date)).jsonl")
    }

    func append(_ s: Sample) {
        q.async {
            guard var data = try? self.enc.encode(s) else { return }
            data.append(0x0A)
            let url = SampleLog.fileURL(for: s.at)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                // 既存ファイルがあるのにここへ来た場合、上書きすればその日が消える。
                // 新規作成のときだけ書く。
                try? data.write(to: url, options: .withoutOverwriting)
            }
        }
    }

    func load(date: Date) -> [Sample] {
        guard let data = try? Data(contentsOf: SampleLog.fileURL(for: date)) else { return [] }
        return decodeLines(data)
    }

    /// 行ごとに解く。ファイル全体を1つの文字列にすると、
    /// 追記中に落ちて壊れたバイトが1つ混じっただけで、その日の記録が丸ごと
    /// 読めなくなる（ファイルは残っているのに画面は「記録なし」になる）。
    private func decodeLines(_ data: Data) -> [Sample] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap {
            try? dec.decode(Sample.self, from: Data($0))
        }
    }

    /// 前回読んだ続きだけを読む。1日分は最大17000件になるので、
    /// パネルを開くたびに全件パースすると無駄が大きい。
    func loadTail(date: Date, from offset: inout UInt64) -> [Sample] {
        let url = SampleLog.fileURL(for: date)
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = SampleLog.fileSize(for: date)
        guard size > offset else { return [] }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd(), !data.isEmpty else { return [] }
        // 読んだ量で進める。size で進めると、読んでいる間の追記を飛ばしたことになる。
        // さらに最後の改行までに留めて、書きかけの行を次回もう一度読み直す。
        if let lastLF = data.lastIndex(of: 0x0A) {
            offset += UInt64(data.distance(from: data.startIndex, to: lastLF)) + 1
            return decodeLines(data[data.startIndex...lastLF])
        }
        return []
    }

    /// 記録は1日あたり1〜5MB増える（測る間隔が状態で変わるため幅がある）。
    /// 放置すると年で数百MBになるので古いものを消す。
    static let retentionDays = 30

    func pruneOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: SampleLog.dir.path) else { return }
        let f = SampleLog.dayFormatter()
        // 「30日分を残す」なので、切り口も日の始まりに揃える
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.startOfDay(for: Date())
        let cutoff = cal.date(byAdding: .day, value: -SampleLog.retentionDays, to: today) ?? today
        for name in files where name.hasSuffix(".jsonl") {
            guard let d = f.date(from: String(name.dropLast(6))) else { continue }  // 日付形式でないものは残す
            if d < cutoff {
                try? fm.removeItem(at: SampleLog.dir.appendingPathComponent(name))
            }
        }
        trimSpeedTests()
    }

    /// 速度テスト履歴の追記。切り詰めと同じキューで行う。
    /// 別々に触ると、切り詰めがファイルを差し替えた隙に書いた1件が消える。
    func appendSpeedTest(_ line: String) {
        q.async {
            let url = SampleLog.dir.appendingPathComponent("speedtests.jsonl")
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .withoutOverwriting)
            }
        }
    }

    func loadSpeedTests() -> [String] {
        let url = SampleLog.dir.appendingPathComponent("speedtests.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    /// スピードテストの履歴も無制限には持たない。
    private func trimSpeedTests() {
        q.sync {
            let url = SampleLog.dir.appendingPathComponent("speedtests.jsonl")
            guard let data = try? Data(contentsOf: url) else { return }
            let lines = data.split(separator: 0x0A)
            guard lines.count > 500 else { return }
            var kept = Data()
            for l in lines.suffix(500) { kept.append(contentsOf: l); kept.append(0x0A) }
            try? kept.write(to: url, options: .atomic)
        }
    }

    /// 表示用に件数を落とす。単純な間引きだと短時間の悪化が消えてしまうので、
    /// 区間ごとに「最も悪かった記録」を残す。
    static func downsample(_ samples: [Sample], maxCount: Int) -> [Sample] {
        guard samples.count > maxCount, maxCount > 0,
              let first = samples.first?.at, let last = samples.last?.at else { return samples }
        let span = max(1, last.timeIntervalSince(first))
        var buckets: [Int: Sample] = [:]
        for s in samples {
            // Int へ落とす前に範囲へ収める。壊れたレコードで極端な日付が入ると、
            // 変換の時点でトラップする（クランプが後だと間に合わない）。
            let pos = s.at.timeIntervalSince(first) / span * Double(maxCount)
            let i = Int(min(Double(maxCount - 1), max(0, pos)))
            if let e = buckets[i], e.score <= s.score { continue }
            buckets[i] = s
        }
        return buckets.keys.sorted().compactMap { buckets[$0] }
    }

    static func fileSize(for date: Date) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(for: date).path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func report(date: Date) -> String {
        let df = SampleLog.dayFormatter()
        return report(samples: load(date: date), title: df.string(from: date))
    }

    /// 情シスにそのまま渡せる形のテキストレポート。期間をまたいでも同じ形式で出す。
    /// `alreadyFiltered` は「呼び出し側で representative 済み」の意味。
    /// 二重に掛けると、絞り込みで生まれた短い断片がさらに落ちて、
    /// 画面に出ている分数と添付レポートの分数が食い違う。
    func report(samples rawSamples: [Sample], title: String, usableAPs: Int = -1,
                alreadyFiltered: Bool = false) -> String {
        let tf = SampleLog.dayFormatter(); tf.dateFormat = "M/d HH:mm"
        guard !rawSamples.isEmpty else { return "\(title) の記録はありません。" }
        // スリープ中に飛び飛びで残った記録は集計から外す
        let samples = alreadyFiltered ? rawSamples : Sample.representative(rawSamples)
        let dropped = rawSamples.count - samples.count
        guard !samples.isEmpty else { return "\(title) の記録はありません。" }

        var out = "Wi-Fi 診断レポート  \(title)  [\(Build.version)]\n"
        out += "観測 \(samples.count) 件\n"
        // 渡す本人が判断できるように、何が入っているかを先に書く。
        // 知らずに提出させるのが一番まずい。
        out += "※ このレポートには、接続していたWi-Fi名とAP（BSSID・呼び名）、"
        out += "および分単位の時刻が含まれます。\n\n"
        if dropped > 0 {
            out += "（スリープ中に飛び飛びで残った \(dropped) 件は集計から除外しています）\n"
        }
        out += "\n"

        // 原因別の滞在時間。計測間隔は一定ではないので、実時刻の差から積み上げる。
        let durations = Sample.durations(samples)
        var byVerdict: [String: TimeInterval] = [:]
        for (i, s) in samples.enumerated() { byVerdict[s.verdict, default: 0] += durations[i] }
        out += "■ どんな状態だったか\n"
        for v in Verdict.allCases {
            guard let sec = byVerdict[v.rawValue], sec > 0 else { continue }
            let mins = Int((sec / 60).rounded())
            // 内部の名前をそのまま出さない。読む人には意味がない。
            let pad = v.label.padding(toLength: 22, withPad: " ", startingAt: 0)
            out += "  \(pad)\(String(format: "%4d", mins))分\n"
        }

        // 画面と同じ物差しで出す。件数平均だと、測る間隔が変わったときに
        // 短い時間の点が過大に効いて、同じ記録なのに数字が食い違う。
        let scorePairs = zip(samples, durations).map { (Double($0.0.score), $0.1) }
        out += String(format: "\n■ 全体の点数  ふだん %.0f点 / 悪いとき %.0f点 / 最低 %.0f点\n",
                      PlaceReport.quantile(scorePairs, 0.5) ?? 0,
                      PlaceReport.quantile(scorePairs, 0.10) ?? 0,
                      samples.map { Double($0.score) }.min() ?? 0)

        // 悪化していた区間だけを塊にまとめて出す(全件出すと読めない)
        out += "\n■ 調子が悪かった時間帯\n"
        var runStart: Sample? = nil
        var runWorst: Sample? = nil
        var prev: Sample? = nil
        var wrote = false
        // 区間ごとに全件を filter すると、不調が細切れなほど遅くなる
        // （＝調子の悪い環境ほど待たされる）。歩きながら最悪を持ち回る。
        func flush(_ end: Sample) {
            guard let st = runStart else { return }
            let worst = runWorst ?? st
            out += String(format: "  %@-%@  %@  最悪%d点  RSSI %ddBm / ch%d / %.0fMbps / GW %.1fms\n",
                          tf.string(from: st.at), tf.string(from: end.at),
                          (Verdict(rawValue: st.verdict)?.label ?? st.verdict),
                          worst.score, worst.rssi, worst.channel, worst.txRate, worst.gwRTT ?? -1)
            wrote = true
            runStart = nil
            runWorst = nil
        }
        for s in samples {
            let bad = Verdict(rawValue: s.verdict)?.isProblem ?? false
            if bad {
                if runStart == nil { runStart = s; runWorst = s }
                else if let p = prev, s.verdict != p.verdict { flush(p); runStart = s; runWorst = s }
                if s.score < (runWorst?.score ?? Int.max) { runWorst = s }
            } else if let p = prev, runStart != nil {
                flush(p)
            }
            prev = s
        }
        if let p = prev { flush(p) }
        if !wrote { out += "  なし\n" }

        // 場所別の実績。どの会議室が使えるかを比べるための本体。
        out += placeSection(samples: samples, durations: durations)

        out += advice(byVerdict: byVerdict, total: Sample.totalSeconds(samples),
                      usableAPs: usableAPs)
        return out
    }

    /// 場所（AP）ごとの実績。呼び名を付けてあれば場所名で出る。
    /// 集計は画面の比較表と同じものを使う。別々に書くと、同じ記録から
    /// 別の点数が出て、どちらを信じればいいのか説明できなくなる。
    private func placeSection(samples: [Sample], durations: [TimeInterval]) -> String {
        var out = "\n■ 場所別の実績\n"
        let places = PlaceReport.summaries(samples, by: .ap, durations: durations)

        guard !places.isEmpty else {
            out += "  位置情報の許可が無いため、どのAPに接続していたかを記録できていません。\n"
            out += "  システム設定 > プライバシーとセキュリティ > 位置情報サービス で許可すると記録できます。\n"
            return out
        }

        for p in places {
            out += "  \(p.name)\n"
            guard p.enough else {
                out += "    \(Int(p.seconds))秒だけ（判定できるほどの記録がありません） / \(p.key)\n"
                continue
            }
            out += String(format: "    ふだん %d点 / 悪いとき %d点 / %d分 / 電波 %ddBm / %@\n",
                          Int(p.score.mid ?? 0), Int(p.score.bad ?? 0),
                          p.minutes, p.rssi ?? 0, p.key)
            out += String(format: "    応答 %d→%dms / ゆらぎ %d→%dms / とりこぼし %.1f%%\n",
                          Int(p.rtt.mid ?? 0), Int(p.rtt.bad ?? 0),
                          Int(p.jitter.mid ?? 0), Int(p.jitter.bad ?? 0),
                          (p.lossRatio ?? 0) * 100)
            if p.badSeconds > 0 {
                out += "    \(p.detail)\n"
            }
            if !p.hourWord.isEmpty { out += "    つないでいた時間帯 \(p.hourWord)\n" }
        }
        if APNames.all().isEmpty {
            out += "  ※ アプリの［詳細］からAPに呼び名を付けると、ここに会議室名が出ます。\n"
        }
        return out
    }

    /// 情シスに渡したときに「で、何をすればいいのか」が分かるようにする。
    /// クライアント側で直せない問題は、AP側の設定で直せることが多い。
    private func advice(byVerdict: [String: TimeInterval], total: TimeInterval,
                        usableAPs: Int = -1) -> String {
        guard total > 0 else { return "" }
        func ratio(_ v: Verdict) -> Double { (byVerdict[v.rawValue] ?? 0) / total }

        var items: [String] = []

        if ratio(.sticky) > 0.05 {
            items.append("""
              ・遠いAPを掴んだままになる時間が長い（観測時間の\(Int(ratio(.sticky) * 100))%）
                macOSは自力ではなかなか掴み直しません。AP側で対処できます:
                  - 最小RSSI（クライアントを一定以下の電波で切り離す設定）の導入
                  - 802.11k / 802.11v の有効化（APから端末へ移動を促せる）
                  - 送信出力が高すぎると遠くのAPまで届いてしまい、掴み直しが起きにくくなります
            """)
        }
        if ratio(.congested) > 0.10 {
            // ここで観測しているのは「電波は良いのに第一ホップの応答が遅い」だけ。
            // 混雑・干渉のほかに、ルータが ICMP を後回しにしている、
            // 端末の省電力で遅延が伸びている、といった説明も付く。
            // 切り分けきれていないことを、増設の要求として書かない。
            var t = """
              ・電波は良好なのに、AP までの応答が遅い時間が長い（観測時間の\(Int(ratio(.congested) * 100))%）
                端末から見えるのはここまでです。AP側の混雑・干渉のほか、
                ルータの負荷や応答の優先度でも同じ見え方になります。
                切り分けにはAP側のログ（同時接続数・チャンネル利用率）が必要です。
            """
            if usableAPs == 1 {
                t += "\n    観測した時点では、この場所で実用的に使えるAPは1台でした。"
                   + "端末側で別のAPへ逃げる余地はありません。"
            }
            items.append(t)
        }
        if ratio(.weak) > 0.10 {
            items.append("""
              ・電波が弱い場所での利用が長い（観測時間の\(Int(ratio(.weak) * 100))%）
                この場所はAPの電波が届きにくい可能性があります。設置位置の見直しをご検討ください。
            """)
        }
        if ratio(.isp) + ratio(.noInternet) > 0.05 {
            items.append("""
              ・AP以降（社内NW〜回線）で遅延や到達不能が発生
                端末とAPの間は正常でした。上位側の確認をお願いします。
            """)
        }

        guard !items.isEmpty else { return "" }
        return "\n■ 情シスへの申し送り\n" + items.joined(separator: "\n")
    }
}
