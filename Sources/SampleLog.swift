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
    /// - Parameter includeHours: 場所ごとの「つないでいた時間帯」を入れるか。
    ///   これは誰がどの部屋に何時にいたかの記録になり、ネットワークの切り分けには使わない。
    ///   既定で外し、自分用に見たいときだけ入れる。
    /// - Parameter status: 渡すと「現在の接続」を先頭に入れる。
    ///   どの端末がどのAPにつないでいる話なのかが無いレポートは、受け取っても動けない。
    ///
    /// 読み手は情シス。順番は「事実 → このアプリの解釈」で、混ぜない。
    /// スコアと判定はこのアプリが決めた尺度であって、調査の一次情報ではない。
    /// 上から読んで実測値だけで話ができ、必要なら最後の解釈を見る、という形にする。
    func report(samples rawSamples: [Sample], title: String, usableAPs: Int = -1,
                alreadyFiltered: Bool = false, includeHours: Bool = false,
                status: ITStatus.Input? = nil) -> String {
        // 秒まで出す。分単位だとコントローラのログと突き合わせられない。
        let tf = SampleLog.dayFormatter(); tf.dateFormat = "M/d HH:mm:ss"
        guard !rawSamples.isEmpty else { return "\(title) の記録はありません。" }
        // スリープ中に飛び飛びで残った記録は集計から外す
        let samples = alreadyFiltered ? rawSamples : Sample.representative(rawSamples)
        let dropped = rawSamples.count - samples.count
        guard !samples.isEmpty else { return "\(title) の記録はありません。" }
        let durations = Sample.durations(samples)

        var out = "Wi-Fi 測定レポート  \(title)  [\(Build.version)]\n"
        // AP側のログに引き当てるための鍵。これが無いと突き合わせが始まらない。
        let device = status.map { ITStatus.device($0) }
            ?? LinkSampler.hardwareAddress.map { "Wi-Fi MAC \($0)" } ?? ""
        if !device.isEmpty { out += "端末: \(device)\n" }
        out += "測定 \(samples.count) 件 / "
        out += "\(tf.string(from: samples[0].at)) - \(tf.string(from: samples[samples.count - 1].at))"
        out += " (\(TimeZone.current.identifier))\n"
        // 値の出どころを書く。何をどう測ったかが分からない数字は検証できない。
        out += "測定方法: 第一ホップ = 既定ゲートウェイへ ICMP 5発（間隔0.2秒、"
        out += "Wi-Fiインターフェースに限定）。応答が無い場合は TCP 80/443/53 へ接続を試行\n"
        out += "          上流 = 1.1.1.1 へ ICMP / DNS = 名前解決の所要時間\n"
        // 渡す本人が判断できるように、何が入っているかを先に書く。
        // 知らずに提出させるのが一番まずい。
        out += "※ このレポートには、接続していたWi-Fi名とAP（BSSID・呼び名）、"
        out += "端末のMACアドレス、および測定した時刻が含まれます。\n"
        if dropped > 0 {
            out += "※ スリープ中に飛び飛びで残った \(dropped) 件は集計から除外しています。\n"
        }
        out += "\n"
        if let status { out += ITStatus.head(status) + "\n" }

        out += SampleLog.apSection(samples: samples, durations: durations, tf: tf)
        out += placeSection(samples: samples, durations: durations,
                            includeHours: includeHours)
        out += SampleLog.exceedSection(samples: samples, durations: durations, tf: tf)
        out += SampleLog.interpretation(samples: samples, durations: durations,
                                        usableAPs: usableAPs, status: status)
        return out
    }

    /// 接続していたAPと、切り替わった時刻。
    /// ローミングの前後で数値が変わるので、区間を分けて読むための土台になる。
    static func apSection(samples: [Sample], durations: [TimeInterval],
                          tf: DateFormatter) -> String {
        var out = "■ APの切り替わり\n"
        var events: [String] = []
        for i in 1..<max(1, samples.count) {
            let a = samples[i - 1], b = samples[i]
            guard a.bssid != b.bssid else { continue }
            var t = "  \(tf.string(from: b.at))  "
            t += "\(a.bssid ?? "未接続") → \(b.bssid ?? "未接続")"
            if let n = APNames.name(for: b.bssid) { t += "（\(n.safeForText)）" }
            t += "  RSSI \(a.rssi) → \(b.rssi)dBm"
            if a.channel != b.channel { t += " / ch\(a.channel) → ch\(b.channel)" }
            events.append(t)
        }
        // 全部並べると、電波の弱い場所では数十行になる。
        if events.count > 20 {
            out += events.prefix(20).joined(separator: "\n") + "\n"
            out += "  （ほかに \(events.count - 20) 回）\n"
        } else if events.isEmpty {
            out += "  なし（測定した範囲では同じAPのまま）\n"
        } else {
            out += events.joined(separator: "\n") + "\n"
        }
        return out
    }

    /// しきい値を超えていた区間。
    ///
    /// どの基準で切り出したのかを先に書く。基準の書いていない「不調」の一覧は、
    /// 受け取った側が正しさを検証できない。判定名ではなく、超えた項目そのものを書く。
    static func exceedSection(samples: [Sample], durations: [TimeInterval],
                              tf: DateFormatter) -> String {
        let t = Exceed.current()
        var out = "\n■ しきい値を超えた区間\n"
        out += String(format: "  抽出条件: 第一ホップ RTT > %.0fms / ジッタ > %.0fms"
                            + " / ロス > %.0f%% / RSSI < %.0fdBm のいずれか\n",
                      t.rtt, t.jitter, t.loss, t.rssi)
        out += "            30秒以上続いたものを1区間とし、60秒以内の中断は同一区間として結合\n"

        let spans = SampleLog.exceedSpans(samples, durations, t)
        let shown = spans.filter { $0.seconds >= 30 }
        for sp in shown { out += sp.lines(tf) }
        if shown.isEmpty { out += "  なし\n" }
        let brief = spans.count - shown.count
        if brief > 0 { out += "  （ほかに30秒未満の超過が \(brief) 回）\n" }
        return out
    }

    /// ここから下はこのアプリ独自の見方であることを、はっきり分けて書く。
    /// 上の実測値が一次情報で、こちらは参考。混ぜると、独自の尺度を
    /// 事実として引用されてしまう。
    static func interpretation(samples: [Sample], durations: [TimeInterval],
                               usableAPs: Int, status: ITStatus.Input? = nil) -> String {
        var byVerdict: [String: TimeInterval] = [:]
        for (i, s) in samples.enumerated() where i < durations.count {
            byVerdict[s.verdict, default: 0] += durations[i]
        }
        var out = "\n■ 参考: このアプリによる分類\n"
        out += "  以下は WiFiDoctor 独自の分類と尺度です。一次情報は上の実測値です。\n"
        if let status { out += ITStatus.classification(status) }
        for v in Verdict.allCases {
            guard let sec = byVerdict[v.rawValue], sec > 0 else { continue }
            let name = "\(v.rawValue)（\(v.label)）"
            out += "  \(SampleLog.pad(name, 36))\(String(format: "%4d", Int((sec / 60).rounded())))分\n"
        }
        out += SampleLog.advice(byVerdict: byVerdict,
                                total: Sample.totalSeconds(samples), usableAPs: usableAPs)
        return out
    }

    private func placeSection(samples: [Sample], durations: [TimeInterval],
                              includeHours: Bool) -> String {
        var out = "\n■ AP別の実測値\n"
        let places = PlaceReport.summaries(samples, by: .ap, durations: durations)

        guard !places.isEmpty else {
            out += "  位置情報の許可が無いため、どのAPに接続していたかを記録できていません。\n"
            out += "  システム設定 > プライバシーとセキュリティ > 位置情報サービス で許可すると記録できます。\n"
            return out
        }

        for p in places {
            out += "  \(p.name)\n"
            guard p.enough else {
                out += "    \(p.key) / 接続 \(Int(p.seconds))秒（判定に足る記録がありません）\n"
                continue
            }
            out += String(format: "    %@ / 接続 %d分 / RSSI p50 %ddBm\n",
                          p.key, p.minutes, p.rssi ?? 0)
            out += String(format: "    第一ホップ RTT p50 %dms, p95 %dms"
                                + " / ジッタ p50 %dms, p95 %dms / ロス %.1f%%\n",
                          Int(p.rtt.mid ?? 0), Int(p.rtt.bad ?? 0),
                          Int(p.jitter.mid ?? 0), Int(p.jitter.bad ?? 0),
                          (p.lossRatio ?? 0) * 100)

            if includeHours, !p.hourWord.isEmpty {
                out += "    つないでいた時間帯 \(p.hourWord)\n"
            }
        }
        if APNames.all().isEmpty {
            out += "  ※ アプリの［詳細］からAPに呼び名を付けると、ここに会議室名が出ます。\n"
        }
        return out
    }

    /// 等幅で読む前提の桁揃え。全角は2桁ぶんとして数える。
    /// 文字数で揃えると、日本語が混ざった瞬間に列がばらける。
    static func pad(_ s: String, _ width: Int) -> String {
        var w = 0
        for u in s.unicodeScalars {
            // 記号・かな・漢字・全角括弧はどれも2桁ぶんの幅で表示される
            w += (u.value >= 0x1100 && u.value <= 0x1FFFF) ? 2 : 1
        }
        return s + String(repeating: " ", count: max(1, width - w))
    }

    /// 区間を切り出す基準。既定はこのアプリの検出しきい値で、MDMで変えられる。
    /// 値を文面に書き出すので、受け取った側が「何をもって超過としたか」を検証できる。
    struct Exceed {
        var rtt: Double, jitter: Double, loss: Double, rssi: Double

        static func current() -> Exceed {
            Exceed(rtt: Settings.Thresholds.gwRTT,
                   jitter: Settings.Thresholds.gwJitter,
                   loss: Settings.Thresholds.gwLoss,
                   rssi: Settings.Thresholds.weakRSSI)
        }

        /// この1件が超えている項目。判定名ではなく、超えた項目そのものを返す。
        func hit(_ s: Sample) -> [String] {
            var v: [String] = []
            if let r = s.gwRTT, r > rtt { v.append("RTT") }
            if let j = s.gwJitter, j > jitter { v.append("ジッタ") }
            if let l = s.gwLoss, l > loss { v.append("ロス") }
            if s.associated && Double(s.rssi) < rssi { v.append("RSSI") }
            // 応答が返らないのは、どの数値よりも重い事実なので必ず拾う
            if s.associated && s.gwRTT == nil { v.append("GW応答なし") }
            return v
        }
    }

    /// しきい値を超えていた、ひとつながりの区間。
    ///
    /// 1件ずつ並べると数百行になり、読む側の目が使えない。
    /// 短い中断で切れた区間は1つに束ね、区間ごとの実測値を分位で示す。
    struct ExceedSpan {
        var from: Date
        var to: Date
        var seconds: TimeInterval = 0
        /// 超えた項目ごとの継続時間。長かった順に並べて書く。
        var hits: [String: TimeInterval] = [:]
        var samples: [(Sample, TimeInterval)] = []

        var bssids: [String] { Array(Set(samples.compactMap { $0.0.bssid })).sorted() }

        private func q(_ f: (Sample) -> Double?, _ p: Double) -> Double? {
            PlaceReport.quantile(samples.compactMap { s in f(s.0).map { ($0, s.1) } }, p)
        }

        func lines(_ tf: DateFormatter) -> String {
            let order = hits.sorted { $0.value > $1.value }.map { $0.key }
            var out = "  \(tf.string(from: from))-\(tf.string(from: to))"
            out += "（\(PlaceReport.spanWord(seconds))）  超過: \(order.joined(separator: ", "))\n"

            // どのAPで起きたのかが無い時刻の羅列は、受け取った側で調べようがない
            var ap = "    AP "
            ap += bssids.map { b in
                APNames.name(for: b).map { "\(b)（\($0.safeForText)）" } ?? b
            }.joined(separator: ", ")
            if bssids.isEmpty { ap += "不明（位置情報の許可なし）" }
            let chans = Set(samples.map { $0.0.channel }).sorted()
            ap += " / ch" + chans.map(String.init).joined(separator: ",")
            out += ap + "\n"

            var m = "    "
            let rtt = samples.compactMap { $0.0.gwRTT }
            m += "RTT " + (q({ $0.gwRTT }, 0.5).map { String(format: "p50 %.0f", $0) } ?? "p50 -")
            m += (q({ $0.gwRTT }, 0.95).map { String(format: " p95 %.0f", $0) } ?? "")
            m += (rtt.max().map { String(format: " 最大 %.0fms", $0) } ?? "ms")
            let noReply = samples.filter { $0.0.associated && $0.0.gwRTT == nil }
            if !noReply.isEmpty {
                m += String(format: " / 応答なし %.0f秒", noReply.reduce(0) { $0 + $1.1 })
            }
            m += q({ $0.gwJitter }, 0.95).map { String(format: " / ジッタ p95 %.0fms", $0) } ?? ""
            m += q({ $0.gwLoss }, 0.95).map { String(format: " / ロス p95 %.0f%%", $0) } ?? ""
            out += m + "\n"

            var w = "    "
            w += q({ Double($0.rssi) }, 0.5).map { String(format: "RSSI p50 %.0f", $0) } ?? "RSSI -"
            w += (samples.map { $0.0.rssi }.min().map { " 最低 \($0)dBm" } ?? "dBm")
            w += q({ $0.txRate }, 0.5).map { String(format: " / リンクレート p50 %.0fMbps", $0) } ?? ""
            w += q({ $0.netRTT }, 0.5).map { String(format: " / 上流RTT p50 %.0fms", $0) } ?? ""
            out += w + "\n"
            return out
        }
    }

    /// - Parameter gapToMerge: これ以内の中断は同じ区間として扱う。
    static func exceedSpans(_ samples: [Sample], _ durations: [TimeInterval],
                            _ t: Exceed = .current(),
                            gapToMerge: TimeInterval = 60) -> [ExceedSpan] {
        var spans: [ExceedSpan] = []
        for (i, x) in samples.enumerated() {
            let hit = t.hit(x)
            guard !hit.isEmpty else { continue }
            let d = i < durations.count ? durations[i] : 0
            if var last = spans.last, x.at.timeIntervalSince(last.to) <= gapToMerge {
                last.to = x.at
                last.seconds += d
                for h in hit { last.hits[h, default: 0] += d }
                last.samples.append((x, d))
                spans[spans.count - 1] = last
            } else {
                var sp = ExceedSpan(from: x.at, to: x.at, seconds: d)
                for h in hit { sp.hits[h] = d }
                sp.samples = [(x, d)]
                spans.append(sp)
            }
        }
        return spans
    }

    /// 情シスに渡したときに「で、何をすればいいのか」が分かるようにする。
    /// クライアント側で直せない問題は、AP側の設定で直せることが多い。
    private static func advice(byVerdict: [String: TimeInterval], total: TimeInterval,
                        usableAPs: Int = -1) -> String {
        guard total > 0 else { return "" }
        func ratio(_ v: Verdict) -> Double { (byVerdict[v.rawValue] ?? 0) / total }

        var items: [String] = []

        if ratio(.sticky) > 0.05 {
            items.append("""
              ・遠いAPを掴んだままになる時間が長い（STICKY / 観測時間の\(Int(ratio(.sticky) * 100))%）
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
              ・RSSI は良好なのに、第一ホップの RTT が伸びる時間が長い（CONGESTED / 観測時間の\(Int(ratio(.congested) * 100))%）
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
              ・RSSI が低い状態での利用が長い（WEAK / 観測時間の\(Int(ratio(.weak) * 100))%）
                この場所はAPの電波が届きにくい可能性があります。設置位置の見直しをご検討ください。
            """)
        }
        if ratio(.isp) + ratio(.noInternet) > 0.05 {
            items.append("""
              ・AP以降（社内NW〜回線）で遅延・到達不能が発生（ISP / NO_INTERNET）
                端末とAPの間は正常でした。上位側の確認をお願いします。
            """)
        }

        guard !items.isEmpty else { return "" }
        return "\n■ 参考: 確認をお願いしたいこと\n" + items.joined(separator: "\n")
    }
}
