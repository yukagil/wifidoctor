import Foundation

/// 日付ごとの JSONL に追記していく。
/// 「遅かった瞬間」は後から再現できないので、記録が切り分けの生命線になる。
final class SampleLog {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WiFiDoctor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private let enc: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private let dec: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    private let q = DispatchQueue(label: "wifidoctor.log")

    static func fileURL(for date: Date) -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return dir.appendingPathComponent("\(f.string(from: date)).jsonl")
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
                try? data.write(to: url)
            }
        }
    }

    func load(date: Date) -> [Sample] {
        let url = SampleLog.fileURL(for: date)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return try? dec.decode(Sample.self, from: d)
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
        offset = size
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return try? dec.decode(Sample.self, from: d)
        }
    }

    /// 記録は1日あたり約5MB増える。放置すると年1.7GBになるので古いものを消す。
    static let retentionDays = 30

    func pruneOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: SampleLog.dir.path) else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let cutoff = Calendar.current.date(byAdding: .day,
                                           value: -SampleLog.retentionDays, to: Date()) ?? Date()
        for name in files where name.hasSuffix(".jsonl") {
            guard let d = f.date(from: String(name.dropLast(6))) else { continue }  // 日付形式でないものは残す
            if d < cutoff {
                try? fm.removeItem(at: SampleLog.dir.appendingPathComponent(name))
            }
        }
        trimSpeedTests()
    }

    /// スピードテストの履歴も無制限には持たない。
    private func trimSpeedTests() {
        let url = SampleLog.dir.appendingPathComponent("speedtests.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        guard lines.count > 500 else { return }
        let kept = lines.suffix(500).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 表示用に件数を落とす。単純な間引きだと短時間の悪化が消えてしまうので、
    /// 区間ごとに「最も悪かった記録」を残す。
    static func downsample(_ samples: [Sample], maxCount: Int) -> [Sample] {
        guard samples.count > maxCount, maxCount > 0,
              let first = samples.first?.at, let last = samples.last?.at else { return samples }
        let span = max(1, last.timeIntervalSince(first))
        var buckets: [Int: Sample] = [:]
        for s in samples {
            let i = min(maxCount - 1, max(0, Int(s.at.timeIntervalSince(first) / span * Double(maxCount))))
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
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return report(samples: load(date: date), title: df.string(from: date))
    }

    /// 情シスにそのまま渡せる形のテキストレポート。期間をまたいでも同じ形式で出す。
    func report(samples rawSamples: [Sample], title: String, usableAPs: Int = -1) -> String {
        let tf = DateFormatter(); tf.dateFormat = "M/d HH:mm"
        guard !rawSamples.isEmpty else { return "\(title) の記録はありません。" }
        // スリープ中に飛び飛びで残った記録は集計から外す
        let samples = Sample.representative(rawSamples)
        let dropped = rawSamples.count - samples.count
        guard !samples.isEmpty else { return "\(title) の記録はありません。" }

        var out = "Wi-Fi 診断レポート  \(title)\n"
        out += "観測 \(samples.count) 件 / 記録フォルダ: \(SampleLog.dir.path)\n"
        if dropped > 0 {
            out += "（スリープ中に飛び飛びで残った \(dropped) 件は集計から除外しています）\n"
        }
        out += "\n"

        // 原因別の滞在時間。計測間隔は一定ではないので、実時刻の差から積み上げる。
        let durations = Sample.durations(samples)
        var byVerdict: [String: TimeInterval] = [:]
        for (i, s) in samples.enumerated() { byVerdict[s.verdict, default: 0] += durations[i] }
        out += "■ 状態別の時間\n"
        for v in Verdict.allCases {
            guard let sec = byVerdict[v.rawValue], sec > 0 else { continue }
            let mins = Int((sec / 60).rounded())
            let pad = v.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)
            out += "  \(pad)\(String(format: "%4d", mins))分  (\(v.label))\n"
        }

        out += String(format: "\n■ スコア  平均 %.0f / 最低 %.0f\n",
                      Sample.averageScore(samples),
                      samples.map { Double($0.score) }.min() ?? 0)

        // 悪化していた区間だけを塊にまとめて出す(全件出すと読めない)
        out += "\n■ 問題が出ていた区間\n"
        var runStart: Sample? = nil
        var prev: Sample? = nil
        var wrote = false
        func flush(_ end: Sample) {
            guard let st = runStart else { return }
            let worst = samples.filter { $0.at >= st.at && $0.at <= end.at }.min { $0.score < $1.score } ?? st
            out += String(format: "  %@-%@  %@  最悪%d点  RSSI %ddBm / ch%d / %.0fMbps / GW %.1fms\n",
                          tf.string(from: st.at), tf.string(from: end.at),
                          (Verdict(rawValue: st.verdict)?.label ?? st.verdict),
                          worst.score, worst.rssi, worst.channel, worst.txRate, worst.gwRTT ?? -1)
            wrote = true
            runStart = nil
        }
        for s in samples {
            let bad = Verdict(rawValue: s.verdict)?.isProblem ?? false
            if bad {
                if runStart == nil { runStart = s }
                else if let p = prev, s.verdict != p.verdict { flush(p); runStart = s }
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
    private func placeSection(samples: [Sample], durations: [TimeInterval]) -> String {
        var out = "\n■ 場所別の実績\n"

        struct Agg {
            var seconds: TimeInterval = 0
            var scoreSum = 0
            var count = 0
            var rssiSum = 0
            var byHour: [Int: (sum: Int, n: Int)] = [:]
        }
        var agg: [String: Agg] = [:]
        let cal = Calendar.current
        for (i, s) in samples.enumerated() {
            guard let b = s.bssid else { continue }
            var a = agg[b] ?? Agg()
            a.seconds += durations[i]
            a.scoreSum += s.score
            a.rssiSum += s.rssi
            a.count += 1
            let h = cal.component(.hour, from: s.at)
            var e = a.byHour[h] ?? (0, 0)
            e.sum += s.score; e.n += 1
            a.byHour[h] = e
            agg[b] = a
        }

        guard !agg.isEmpty else {
            out += "  位置情報の許可が無いため、どのAPに接続していたかを記録できていません。\n"
            out += "  システム設定 > プライバシーとセキュリティ > 位置情報サービス で許可すると記録できます。\n"
            return out
        }

        for (b, a) in agg.sorted(by: { $0.value.seconds > $1.value.seconds }) {
            let name = APNames.name(for: b) ?? "AP \(APNames.shortID(b))"
            let avg = a.scoreSum / max(1, a.count)
            out += String(format: "  %@\n", name)
            out += String(format: "    平均 %d点 / %d分 / 平均RSSI %ddBm / %@\n",
                          avg, Int(a.seconds / 60), a.rssiSum / max(1, a.count), b)
            // 十分な標本がある時間帯だけ、最も悪かった時間を出す
            let worst = a.byHour.filter { $0.value.n >= 12 }
                .min { ($0.value.sum / $0.value.n) < ($1.value.sum / $1.value.n) ? true : false }
            if let w = worst, a.byHour.count > 1 {
                out += String(format: "    最も悪い時間帯 %d時台（平均 %d点）\n",
                              w.key, w.value.sum / w.value.n)
            }
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
            var t = """
              ・APの混雑が長い（観測時間の\(Int(ratio(.congested) * 100))%）
                電波は届いているのに応答が遅い状態です。AP台数の増設、チャンネル設計の見直し、
                同一チャンネルに重なるAPの削減が効きます。
            """
            if usableAPs == 1 {
                t += "\n    この場所は実用的なAPが1台しかありません。端末側では回避できないため、"
                   + "増設をご検討ください。"
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
