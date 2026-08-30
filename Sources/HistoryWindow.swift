import AppKit

// MARK: - グラフ

/// 同じ時間軸に「判定 / スコア / 電波 / 遅延」を積んで描く。
/// 単独の値では原因が分からず、"電波が落ちた瞬間に遅延が跳ねたのか"
/// "電波は良いのに遅延だけ跳ねたのか" の対比で初めて切り分けられるため。
final class ChartView: NSView {
    var samples: [Sample] = [] { didSet { hoverIndex = nil; needsDisplay = true } }
    override var isFlipped: Bool { true }

    static func color(_ v: String) -> NSColor {
        switch Verdict(rawValue: v) ?? .ok {
        case .ok: return .systemGreen
        case .sticky: return .systemOrange
        case .congested: return .systemYellow
        case .weak: return .systemRed
        case .isp: return .systemPurple
        case .dns: return .systemTeal
        case .selfTraffic: return .systemIndigo
        case .macBusy: return .systemBrown
        case .measuring: return .systemGray
        case .noInternet: return .systemBrown
        case .offline: return .systemGray
        }
    }

    /// 1つのパネルに重ねる線。2本重ねると「どちらの区間が原因か」が直接読める。
    private struct Line {
        var title: String
        var color: NSColor
        var value: (Sample) -> Double?
    }

    private struct Series {
        var title: String
        var note: String?          // 誤解を避けるための注記
        var lo: Double
        var hi: Double
        var lines: [Line]
        var fmt: (Double) -> String
    }

    /// 縦軸は実データに合わせて伸ばす。固定上限だとスパイクが天井に張り付いて
    /// 「どれくらい酷いのか」が読めなくなるため。
    private func upper(_ vs: [Double], floor f: Double, cap: Double) -> Double {
        guard !vs.isEmpty else { return f }
        let sorted = vs.sorted()
        // 外れ値1点で全体が潰れないよう95パーセンタイル基準
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return min(cap, max(f, (p95 * 1.25 / 10).rounded(.up) * 10))
    }

    /// 体感を決める順に並べる。
    /// 平均遅延が良くてもジッタと損失が悪ければ会議は乱れるので、その2つを独立して見せる。
    private var series: [Series] {
        let rttHi = upper(samples.compactMap { $0.gwRTT } + samples.compactMap { $0.netRTT },
                          floor: 30, cap: 500)
        let jitHi = upper(samples.compactMap { $0.gwJitter }, floor: 10, cap: 200)
        let lossHi = upper(samples.compactMap { $0.gwLoss } + samples.compactMap { $0.netLoss },
                           floor: 10, cap: 100)
        let mbpsHi = upper(samples.map { $0.txRate }, floor: 200, cap: 2400)
        let ms: (Double) -> String = { String(format: "%.0f", $0) }

        return [
            Series(title: "応答の速さ (ms)",
                   note: "低いほど良い",
                   lo: 0, hi: rttHi,
                   lines: [
                    Line(title: "自分→AP", color: .systemRed, value: { $0.gwRTT }),
                    Line(title: "インターネット", color: .systemPurple, value: { $0.netRTT }),
                   ], fmt: ms),

            Series(title: "ゆらぎ (ms)",
                   note: "会議の音声が途切れる主因",
                   lo: 0, hi: jitHi,
                   lines: [Line(title: "ジッタ", color: .systemOrange, value: { $0.gwJitter })],
                   fmt: ms),

            Series(title: "パケット損失 (%)",
                   note: "0%が正常",
                   lo: 0, hi: lossHi,
                   lines: [
                    Line(title: "自分→AP", color: .systemRed, value: { $0.gwLoss }),
                    Line(title: "インターネット", color: .systemPurple, value: { $0.netLoss }),
                   ], fmt: ms),

            Series(title: "電波の強さ (dBm)",
                   note: "遅さの原因側の指標",
                   lo: -90, hi: -30,
                   lines: [Line(title: "RSSI", color: .systemBlue, value: { Double($0.rssi) })],
                   fmt: ms),

            Series(title: "リンク速度 (Mbps)",
                   note: "規格上の接続速度。実効スループットではない",
                   lo: 0, hi: mbpsHi,
                   lines: [Line(title: "リンク", color: .systemGreen, value: { $0.txRate })],
                   fmt: ms),
        ]
    }

    private let left: CGFloat = 62
    private let right: CGFloat = 14
    private let bandH: CGFloat = 12
    private let axisH: CGFloat = 18
    private let gapV: CGFloat = 10
    private let gapSeconds: TimeInterval = 150

    /// カーソルが指している観測点。ここを起点に全系列の断面を出す。
    private var hoverIndex: Int?
    private var panels: [NSRect] = []
    private var cachedSeries: [Series] = []

    // MARK: - マウス追従

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = indexAt(x: p.x)
        if i != hoverIndex { hoverIndex = i; needsDisplay = true }
    }

    /// 検証用: 実際のマウス操作なしにカーソル位置を与える。
    func hoverForTest(x: CGFloat) -> Bool {
        hoverIndex = indexAt(x: x)
        needsDisplay = true
        return hoverIndex != nil
    }

    override func mouseExited(with event: NSEvent) {
        if hoverIndex != nil { hoverIndex = nil; needsDisplay = true }
    }

    /// x座標に最も近い観測点。等間隔ではない(記録が飛ぶ)ので時刻で最近傍を取る。
    private func indexAt(x: CGFloat) -> Int? {
        guard samples.count > 1 else { return nil }
        let plotW = bounds.width - left - right
        guard plotW > 0, x >= left - 4, x <= left + plotW + 4 else { return nil }
        let t0 = samples.first!.at.timeIntervalSince1970
        let t1 = max(samples.last!.at.timeIntervalSince1970, t0 + 1)
        let t = t0 + Double((x - left) / plotW) * (t1 - t0)
        var best = 0
        var bestD = Double.infinity
        for (i, s) in samples.enumerated() {
            let d = abs(s.at.timeIntervalSince1970 - t)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    // MARK: - 描画

    override func draw(_ dirty: NSRect) {
        NSColor.textBackgroundColor.setFill(); bounds.fill()

        guard samples.count > 1 else {
            let s = NSAttributedString(string: "この期間の記録がありません", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
            s.draw(at: NSPoint(x: bounds.midX - s.size().width / 2, y: bounds.midY))
            return
        }

        let plotW = bounds.width - left - right
        let t0 = samples.first!.at.timeIntervalSince1970
        let t1 = max(samples.last!.at.timeIntervalSince1970, t0 + 1)
        func X(_ s: Sample) -> CGFloat {
            left + plotW * CGFloat((s.at.timeIntervalSince1970 - t0) / (t1 - t0))
        }

        var y: CGFloat = 8
        for (i, s) in samples.enumerated() {
            let x0 = X(s)
            let x1 = i + 1 < samples.count ? X(samples[i + 1]) : left + plotW
            ChartView.color(s.verdict).setFill()
            NSRect(x: x0, y: y, width: max(1, x1 - x0), height: bandH).fill()
        }
        label("判定", at: NSPoint(x: 8, y: y), size: 9, color: .secondaryLabelColor)
        y += bandH + gapV

        let sers = series
        let panelH = max(24, (bounds.height - y - axisH - CGFloat(sers.count) * gapV) / CGFloat(sers.count))
        panels = []
        cachedSeries = sers
        for s in sers {
            let r = NSRect(x: left, y: y, width: plotW, height: panelH)
            panels.append(r)
            drawSeries(s, in: r, X: X)
            y += panelH + gapV
        }

        // AP切替の縦線。ラベルが重ならないよう最小間隔を空ける。
        var prevB: String? = samples.first?.bssid
        var lastLabelX: CGFloat = -999
        for s in samples.dropFirst() {
            defer { if s.bssid != nil { prevB = s.bssid } }
            guard let b = s.bssid, let p = prevB, b != p else { continue }
            let x = X(s)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 8))
            path.line(to: NSPoint(x: x, y: bounds.height - axisH))
            path.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.systemOrange.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 1
            path.stroke()
            if x - lastLabelX > 62 {
                // 呼び名を付けてあれば、どこへ移ったかがそのまま読める
                let text = APNames.name(for: b) ?? "AP切替"
                label(text, at: NSPoint(x: x + 3, y: 8 + bandH + 1), size: 8, color: .systemOrange)
                lastLabelX = x
            }
        }

        let tf = DateFormatter()
        tf.dateFormat = (t1 - t0) > 86_400 ? "M/d HH:mm" : "HH:mm"
        for f in stride(from: 0.0, through: 1.0, by: 0.2) {
            let idx = min(samples.count - 1, Int(Double(samples.count - 1) * f))
            let x = min(X(samples[idx]), left + plotW - 46)
            label(tf.string(from: samples[idx].at),
                  at: NSPoint(x: x, y: bounds.height - axisH + 2), size: 9, color: .tertiaryLabelColor)
        }

        if let hi = hoverIndex { drawCrosshair(index: hi, X: X) }
    }

    private func drawSeries(_ s: Series, in r: NSRect, X: (Sample) -> CGFloat) {
        NSColor.separatorColor.setStroke()
        for f in [0.0, 0.5, 1.0] {
            let yy = r.minY + r.height * CGFloat(f)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX, y: yy)); p.line(to: NSPoint(x: r.maxX, y: yy))
            p.lineWidth = 0.5; p.stroke()
        }
        label(s.fmt(s.hi), at: NSPoint(x: 8, y: r.minY - 5), size: 9, color: .tertiaryLabelColor)
        label(s.fmt(s.lo), at: NSPoint(x: 8, y: r.maxY - 9), size: 9, color: .tertiaryLabelColor)

        // 見出し・注記・凡例を左端にまとめる
        var ly = r.midY - 16
        label(s.title, at: NSPoint(x: 8, y: ly), size: 9.5, color: .secondaryLabelColor, bold: true)
        ly += 11
        if let n = s.note {
            label(n, at: NSPoint(x: 8, y: ly), size: 8, color: .tertiaryLabelColor)
            ly += 10
        }
        if s.lines.count > 1 {
            for ln in s.lines {
                label("— " + ln.title, at: NSPoint(x: 8, y: ly), size: 8, color: ln.color)
                ly += 10
            }
        }

        for ln in s.lines {
            let path = NSBezierPath()
            var started = false
            var prev: Sample?
            for smp in samples {
                guard let v = ln.value(smp) else { prev = smp; continue }
                let pt = NSPoint(x: X(smp), y: yFor(v, s, r))
                if let p = prev, smp.at.timeIntervalSince(p.at) > gapSeconds { started = false }
                if started { path.line(to: pt) } else { path.move(to: pt); started = true }
                prev = smp
            }
            ln.color.setStroke()
            path.lineWidth = 1.3
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    private func yFor(_ v: Double, _ s: Series, _ r: NSRect) -> CGFloat {
        let c = max(s.lo, min(s.hi, v))
        return r.maxY - r.height * CGFloat((c - s.lo) / (s.hi - s.lo))
    }

    // MARK: - 断面表示

    private func drawCrosshair(index: Int, X: (Sample) -> CGFloat) {
        let smp = samples[index]
        let x = X(smp)

        // 縦線
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: 8))
        line.line(to: NSPoint(x: x, y: bounds.height - axisH))
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()
        line.lineWidth = 1
        line.stroke()

        // 各系列の該当点に印を打つ
        for (i, ser) in cachedSeries.enumerated() where i < panels.count {
            for ln in ser.lines {
                guard let v = ln.value(smp) else { continue }
                let pt = NSPoint(x: x, y: yFor(v, ser, panels[i]))
                let dot = NSBezierPath(ovalIn: NSRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7))
                NSColor.textBackgroundColor.setFill(); dot.fill()
                ln.color.setStroke(); dot.lineWidth = 2; dot.stroke()
            }
        }

        drawTooltip(for: smp, atX: x)
    }

    private func drawTooltip(for s: Sample, atX x: CGFloat) {
        let body = tooltipText(s)
        let pad: CGFloat = 9
        let maxW: CGFloat = 250
        let size = body.boundingRect(with: NSSize(width: maxW, height: 600),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let w = min(maxW, ceil(size.width)) + pad * 2
        let h = ceil(size.height) + pad * 2

        // 右に出すと画面外になる場合は左へ回り込ませる
        var ox = x + 14
        if ox + w > bounds.maxX - 4 { ox = x - 14 - w }
        ox = max(4, ox)
        let oy = min(max(8, 8 + bandH + 6), bounds.height - axisH - h - 4)

        let card = NSRect(x: ox, y: oy, width: w, height: h)
        let bg = NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 9
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        bg.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.setStroke()
        bg.lineWidth = 1
        bg.stroke()

        body.draw(with: NSRect(x: card.minX + pad, y: card.minY + pad,
                               width: w - pad * 2, height: h - pad * 2),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// その時刻の全指標を1枚にまとめる。単位と平易な言葉を併記して、
    /// 数値だけ見ても意味が取れない人でも読めるようにする。
    private func tooltipText(_ s: Sample) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.tabStops = [NSTextTab(textAlignment: .left, location: 86)]
        p.defaultTabInterval = 86
        p.lineSpacing = 2.5

        let out = NSMutableAttributedString()
        func row(_ k: String, _ v: String, _ tint: NSColor? = nil) {
            out.append(NSAttributedString(string: k + "\t", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]))
            out.append(NSAttributedString(string: v + "\n", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: tint ?? NSColor.labelColor, .paragraphStyle: p]))
        }

        let tf = DateFormatter(); tf.dateFormat = "M月d日 HH:mm:ss"
        out.append(NSAttributedString(string: tf.string(from: s.at) + "\n", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: p]))

        let v = Verdict(rawValue: s.verdict) ?? .ok
        out.append(NSAttributedString(string: "● " + v.label + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: ChartView.color(s.verdict), .paragraphStyle: p]))

        row("スコア", "\(s.score) / 100")
        row("電波", "\(s.rssi) dBm（\(Phrase.signalWord(s.rssi))）",
            s.rssi < -70 ? .systemRed : (s.rssi < -63 ? .systemOrange : .labelColor))

        if let g = s.gwRTT {
            let t: NSColor = g > 25 ? .systemRed : (g > 12 ? .systemOrange : .labelColor)
            var v = String(format: "%.1f ms", g)
            if let j = s.gwJitter { v += String(format: " ±%.1f", j) }
            if let l = s.gwLoss, l > 0 { v += String(format: " 損失%.0f%%", l) }
            row("自分→AP", v, t)
        }
        if let n = s.netRTT {
            let t: NSColor = (s.netLoss ?? 0) > 3 ? .systemRed : .labelColor
            var v = String(format: "%.1f ms", n)
            if let l = s.netLoss, l > 0 { v += String(format: " 損失%.0f%%", l) }
            row("インターネット", v, t)
        }
        if let d = s.dnsMS { row("DNS", String(format: "%.0f ms", d)) }

        row("リンク速度", String(format: "%.0f Mbps", s.txRate))
        row("無線", "\(s.phy) / \(s.band)GHz ch\(s.channel) / \(s.width)MHz")
        if let ssid = s.ssid { row("接続先", ssid) }
        if let b = s.bssid {
            row("AP", APNames.name(for: b).map { "\($0)（\(APNames.shortID(b))）" } ?? b)
        }

        return out
    }

    private func label(_ t: String, at p: NSPoint, size: CGFloat,
                       color: NSColor, bold: Bool = false) {
        NSAttributedString(string: t, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular),
            .foregroundColor: color]).draw(at: p)
    }
}

// MARK: - ウィンドウ

final class HistoryWindowController: NSWindowController {
    private let log: SampleLog
    private let chart = ChartView()
    private let text = NSTextView()
    private let rangePop = NSPopUpButton()
    private let summary = NSTextField(labelWithString: "")
    private var current: [Sample] = []

    /// 期間の選択肢。(表示名, さかのぼる日数)
    private let ranges: [(String, Int)] = [
        ("今日", 1), ("過去3日", 3), ("過去7日", 7), ("過去30日", 30)
    ]

    init(log: SampleLog) {
        self.log = log
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 820),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "WiFiDoctor — 推移と診断レポート"
        w.setFrameAutosaveName("WiFiDoctorHistory")
        w.acceptsMouseMovedEvents = true      // クロスヘアの追従に必要
        w.center()
        super.init(window: w)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }

        rangePop.addItems(withTitles: ranges.map { $0.0 })
        rangePop.target = self; rangePop.action = #selector(reloadAction)

        let bar = NSStackView(views: [
            NSTextField(labelWithString: "期間"), rangePop, NSView(),
            NSButton(title: "更新", target: self, action: #selector(reloadAction)),
            NSButton(title: "レポートを書き出す", target: self, action: #selector(exportReport)),
        ])
        bar.orientation = .horizontal; bar.spacing = 8

        summary.font = .systemFont(ofSize: 11.5, weight: .medium)
        summary.textColor = .secondaryLabelColor

        let legend = NSStackView()
        legend.orientation = .horizontal; legend.spacing = 10
        for v in Verdict.allCases {
            let l = NSTextField(labelWithString: "■ \(v.label)")
            l.font = .systemFont(ofSize: 10)
            l.textColor = ChartView.color(v.rawValue)
            legend.addArrangedSubview(l)
        }
        legend.addArrangedSubview({
            let l = NSTextField(labelWithString: "┆ AP切替")
            l.font = .systemFont(ofSize: 10); l.textColor = .systemOrange; return l
        }())
        legend.addArrangedSubview(NSView())
        legend.addArrangedSubview({
            let l = NSTextField(labelWithString: "グラフにカーソルを合わせるとその時刻の詳細が出ます")
            l.font = .systemFont(ofSize: 10); l.textColor = .tertiaryLabelColor; return l
        }())

        text.isEditable = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 10)
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let stack = NSStackView(views: [bar, summary, chart, legend, scroll])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            chart.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
    }

    @objc private func reloadAction() { reload() }

    func reload() {
        let days = ranges[max(0, rangePop.indexOfSelectedItem)].1
        let cal = Calendar.current
        var all: [Sample] = []
        for d in 0..<days {
            guard let date = cal.date(byAdding: .day, value: -d, to: Date()) else { continue }
            all.append(contentsOf: log.load(date: date))
        }
        // スリープ中の飛び飛びの記録はグラフからも外す。
        // 残すと灰色だらけになり「一晩中壊れていた」ように見える。
        let sorted = Sample.representative(all.sorted { $0.at < $1.at })
        current = sorted
        // 30日分は最大14万件になる。全点を折れ線にすると描画が重く、
        // 画素より細かい情報は見えないので、悪化を保ったまま間引く。
        chart.samples = SampleLog.downsample(sorted, maxCount: 4000)
        text.string = log.report(samples: current,
                                 title: ranges[max(0, rangePop.indexOfSelectedItem)].0)
        summary.stringValue = headline(current)
    }

    private func headline(_ s: [Sample]) -> String {
        guard !s.isEmpty else { return "記録なし" }
        let bad = s.filter { Verdict(rawValue: $0.verdict)?.isProblem ?? false }
        let pct = Int(Double(bad.count) / Double(s.count) * 100)
        let avg = Sample.averageScore(s)
        let hours = Sample.totalSeconds(s) / 3600
        var t = String(format: "観測 %.1f時間 / 平均スコア %.0f / 問題ありだった割合 %d%%", hours, avg, pct)
        if s.count > 4000 { t += "（グラフは表示のため間引いています。悪化した瞬間は残しています）" }
        return t
    }

    @objc private func exportReport() {
        let p = NSSavePanel()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        p.nameFieldStringValue = "wifi-report-\(f.string(from: Date())).txt"
        let body = text.string
        p.begin { r in
            guard r == .OK, let url = p.url else { return }
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
