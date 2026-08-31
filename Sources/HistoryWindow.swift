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
            Series(title: "応答の速さ（ms）",
                   note: "低いほど良い",
                   lo: 0, hi: rttHi,
                   lines: [
                    Line(title: "自分→AP", color: .systemRed, value: { $0.gwRTT }),
                    Line(title: "インターネット", color: .systemPurple, value: { $0.netRTT }),
                   ], fmt: ms),

            Series(title: "ゆらぎ（ms）",
                   note: "会議の音声が途切れる主因",
                   lo: 0, hi: jitHi,
                   lines: [Line(title: "ゆらぎ", color: .systemOrange, value: { $0.gwJitter })],
                   fmt: ms),

            Series(title: "とりこぼし（%）",
                   note: "0%が正常",
                   lo: 0, hi: lossHi,
                   lines: [
                    Line(title: "自分→AP", color: .systemRed, value: { $0.gwLoss }),
                    Line(title: "インターネット", color: .systemPurple, value: { $0.netLoss }),
                   ], fmt: ms),

            Series(title: "電波の強さ（dBm）",
                   note: "遅さの原因側の指標",
                   lo: -90, hi: -30,
                   lines: [Line(title: "RSSI", color: .systemBlue, value: { Double($0.rssi) })],
                   fmt: ms),

            Series(title: "リンク速度（Mbps）",
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

        let tf = SampleLog.dayFormatter()
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

        let tf = SampleLog.dayFormatter(); tf.dateFormat = "M月d日 HH:mm:ss"
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
        // 左の余白に収まらない注記は切り詰める。draw(at:) のままだと
        // グラフの描画域へ100pt近くはみ出して、折れ線と文字が重なる。
        let a = NSAttributedString(string: t, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular),
            .foregroundColor: color])
        let room = max(40, left - p.x - 4)
        if a.size().width <= room { a.draw(at: p); return }
        a.draw(with: NSRect(x: p.x, y: p.y, width: room, height: size * 1.6),
               options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }
}

// MARK: - 共通の色と言葉

enum Palette {
    static func level(_ l: Level) -> NSColor {
        switch l {
        case .good: return .systemGreen
        case .fair: return .systemOrange
        case .bad: return .systemRed
        case .offline: return .systemGray
        }
    }
    /// 既定値を置かない。省略できるようにすると、崩れた割合を渡し忘れた場所だけ
    /// 昔の「点数だけ」の基準が生き残る。
    static func level(score: Int, badRatio: Double) -> Level {
        Phrase.level(score: score, badRatio: badRatio)
    }

    /// 点数そのものに色を付ける。良し悪しの判定ではなく、数値の見た目のため。
    /// 「悪いとき 48点」のような、分布の裾を出すときに使う。
    static func scoreColor(_ score: Int) -> NSColor {
        level(score >= 80 ? .good : (score >= 60 ? .fair : .bad))
    }
    static func word(_ l: Level) -> String {
        switch l {
        case .good: return "快適"
        case .fair: return "ふつう"
        case .bad: return "遅い"
        case .offline: return "記録不足"
        }
    }

    /// 上の帯と下の行を結ぶ識別色。良し悪しは緑/橙/赤で表しているので、その3色は避ける。
    static let ids: [NSColor] = [
        .systemBlue, .systemPurple, .systemTeal, .systemPink,
        .systemIndigo, .systemBrown, .systemCyan, .systemGray,
    ]
    static func id(_ key: String, in places: [PlaceSummary]) -> NSColor {
        guard let i = places.firstIndex(where: { $0.key == key }) else { return .systemGray }
        return ids[i % ids.count]
    }
}

/// 文字を置くだけの小さな道具。座標で組む描画が続くので、呼び出しを短くしておく。
extension NSView {
    @discardableResult
    func put(_ t: String, x: CGFloat, y: CGFloat, size: CGFloat,
             weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
             mono: Bool = false, maxWidth: CGFloat? = nil, lines: Int = 1) -> CGFloat {
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let s = NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: color])
        if let w = maxWidth {
            s.draw(with: NSRect(x: x, y: y, width: w, height: size * 1.55 * CGFloat(lines)),
                   options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            return min(w, s.size().width)
        }
        s.draw(at: NSPoint(x: x, y: y))
        return s.size().width
    }

    /// 右端を揃えて置く。数字は右揃えでないと桁が比べられない。
    @discardableResult
    func putRight(_ t: String, rightEdge: CGFloat, y: CGFloat, size: CGFloat,
                  weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                  mono: Bool = true) -> CGFloat {
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let s = NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: color])
        s.draw(at: NSPoint(x: rightEdge - s.size().width, y: y))
        return s.size().width
    }
}

// MARK: - 結論

/// 画面のいちばん上。ここだけ読んで閉じても用が足りるように書く。
///
/// 数字を並べる前に、まず「今日はどうだったのか」を文で言い切る。
/// 表やグラフは、その結論を確かめたい人のためのもの。
final class VerdictCard: NSView {
    private var score: Int?
    private var bad: Int?
    private var level: Level = .offline
    private var lines: [String] = []
    func set(score: Int?, bad: Int?, level: Level, lines: [String]) {
        self.score = score; self.bad = bad; self.level = level; self.lines = lines
        needsDisplay = true
    }
    /// 動作確認から見る用。表と食い違っていないかを外から確かめられるようにしておく。
    var shownScore: Int? { score }

    // 手で描いた文字は、そのままでは読み上げの対象にならない。
    // この画面の結論はここにしかないので、要素として名乗らせる。
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? {
        (score.map { "総合 \(Palette.word(level)) \($0)点。" } ?? "") + lines.joined(separator: " ")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            .stroke()

        // 大きな点数。色だけで良し悪しが分かるようにする。
        let c = Palette.level(level)
        let box = NSRect(x: 14, y: 14, width: 92, height: bounds.height - 28)
        c.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()

        let n = score.map { "\($0)" } ?? "—"
        let w = NSAttributedString(string: n, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 32, weight: .semibold)]).size().width
        put(n, x: box.midX - w / 2, y: box.minY + 6, size: 32, weight: .semibold, color: c,
            mono: true)
        let word = "ふだん \(Palette.word(level))"
        let ww = NSAttributedString(string: word, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium)]).size().width
        put(word, x: box.midX - ww / 2, y: box.minY + 48, size: 11, weight: .medium, color: c)
        if let bad, let score, bad < score - 2 {
            let t = "悪いとき \(bad)点"
            let tw = NSAttributedString(string: t, attributes: [
                .font: NSFont.systemFont(ofSize: 10)]).size().width
            put(t, x: box.midX - tw / 2, y: box.minY + 64, size: 10,
                color: Palette.scoreColor(bad))
        }

        var y: CGFloat = 14
        for (i, line) in lines.enumerated() {
            let last = i == lines.count - 1 && lines.count > 2
            _ = put(line, x: 120, y: y,
                    size: i == 0 ? 15 : 12,
                    weight: i == 0 ? .semibold : .regular,
                    color: i == 0 ? .labelColor : .secondaryLabelColor,
                    maxWidth: bounds.width - 134,
                    lines: last ? 2 : 1)
            y += i == 0 ? 26 : (last ? 36 : 19)
        }
    }
}

// MARK: - いつ

/// 1日を時間ごとに見せ、その下に「そのときどこにつないでいたか」を並べる。
///
/// 「今日は遅かった」では動けない。「12時台が遅く、そこは nikopresso だった」
/// まで一目で見えて初めて、次にどこへ座るかを決められる。
final class HourStripView: NSView {
    var hours: [HourSummary] = [] { didSet { needsDisplay = true } }
    /// 色と並びの基準。下の行と同じ順序・同じ色を使う。
    var places: [PlaceSummary] = [] { didSet { needsDisplay = true } }
    var selectedKey: String? { didSet { needsDisplay = true } }
    var selectedHour: Int? { didSet { needsDisplay = true } }
    /// 何日ぶんをまとめているか。最悪の時間帯を選ぶ足切りが期間で変わる。
    var days: Int = 1 { didSet { needsDisplay = true } }
    var onSelectHour: ((Int?) -> Void)?
    /// カーソルが指している時間の説明。窓側のラベルに出す。
    var onHover: ((String?) -> Void)?

    override var isFlipped: Bool { true }

    private var hoverHour: Int?
    private let legendH: CGFloat = 0
    private let axisH: CGFloat = 15
    private let placeH: CGFloat = 30

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    private func hour(at p: NSPoint) -> Int? {
        let h = Int((p.x - gutter) / colW())
        return (0..<24).contains(h) ? h : nil
    }

    override func mouseMoved(with e: NSEvent) {
        let h = hour(at: convert(e.locationInWindow, from: nil))
        guard h != hoverHour else { return }
        hoverHour = h
        onHover?(h.flatMap { hours.indices.contains($0) ? line(hours[$0]) : nil })
        needsDisplay = true
    }
    override func mouseExited(with e: NSEvent) {
        hoverHour = nil; onHover?(nil); needsDisplay = true
    }
    override func mouseDown(with e: NSEvent) {
        guard let h = hour(at: convert(e.locationInWindow, from: nil)),
              hours.indices.contains(h), hours[h].hasData else { onSelectHour?(nil); return }
        onSelectHour?(selectedHour == h ? nil : h)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        let recorded = hours.filter { $0.hasData }
        guard !recorded.isEmpty else { return "時間ごとの調子。記録はありません" }
        return "時間ごとの調子。" + recorded.map { line($0) }.joined(separator: "。")
    }

    private func name(_ key: String) -> String {
        places.first { $0.key == key }?.name ?? key
    }

    /// カーソルを合わせた時間の一行。下の行と同じ言葉で書く。
    func line(_ h: HourSummary) -> String {
        guard h.hasData else { return "\(h.hour)時台 ・ 記録なし" }
        var t = "\(h.hour)時台 ・ ふだん \(h.score)点（\(Palette.word(h.level))） ・ \(h.minutes)分ぶん"
        if let k = h.byKey.max(by: { $0.value < $1.value })?.key { t += " ・ \(name(k))" }
        if h.badSeconds >= 30 {
            let cause = h.topProblem.map { "\($0.plainCause)時間" } ?? "崩れた時間"
            t += " ・ \(cause)が \(PlaceReport.spanWord(h.badSeconds))"
        }
        return t
    }

    /// その時間、いちばん長くつないでいた先。帯の下の区切りに使う。
    private func dominant(_ h: HourSummary) -> String? {
        h.byKey.max { $0.value < $1.value }?.key
    }

    /// 目盛りの数字を置く左の余白。ここを空けないと0時の柱と重なって読めない。
    private let gutter: CGFloat = 24

    private func colW() -> CGFloat { max(1, (bounds.width - gutter) / 24) }

    override func draw(_ dirty: NSRect) {
        let colW = colW()
        let barTop = legendH + 6
        let labelTop = bounds.height - placeH - axisH
        let barBottom = labelTop
        let barArea = max(10, barBottom - barTop)

        // 100点満点の目盛り。基準線が無いと柱の高さを比べられない。
        for (v, label) in [(80.0, "80"), (60.0, "60")] {
            let y = barBottom - barArea * CGFloat(v / 100)
            NSColor.separatorColor.setFill()
            NSRect(x: gutter, y: y, width: bounds.width - gutter, height: 1).fill()
            put(label, x: 2, y: y - 7, size: 9.5, color: .tertiaryLabelColor, mono: true)
        }

        for (i, h) in hours.enumerated() {
            let x = gutter + CGFloat(i) * colW
            let col = NSRect(x: x + 2.5, y: barTop, width: max(2, colW - 5), height: barArea)

            if selectedHour == i || hoverHour == i {
                NSColor.labelColor.withAlphaComponent(selectedHour == i ? 0.10 : 0.05).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: barTop - 4, width: colW,
                                                 height: labelTop - barTop + axisH + 4),
                             xRadius: 5, yRadius: 5).fill()
            }

            guard h.hasData else {
                // 記録が無い時間は、床にうっすら残すだけ。空白は「良かった」に見える。
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSRect(x: col.minX, y: barBottom - 2, width: col.width, height: 2).fill()
                continue
            }

            let hgt = max(4, barArea * CGFloat(h.score) / 100)
            let bar = NSRect(x: col.minX, y: barBottom - hgt, width: col.width, height: hgt)
            // 数分しか記録の無い時間は、同じ高さでも重みが違う。薄くして、点数も伏せる。
            let thin = h.seconds < 600
            // 選んだ先の話をしているときは、それ以外の時間を消さずに薄くする。
            // 消すと比べる相手がいなくなり、選んだ先が良く見えるだけの画面になる。
            let other = selectedKey != nil && dominant(h) != selectedKey
            let alpha: CGFloat = other ? 0.18 : (thin ? 0.35 : 1)

            Palette.level(h.level).withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()

            // 点数は柱の上に直接。凡例と首っ引きにさせない。
            if colW > 26 && !thin && !other {
                let s = "\(h.score)"
                let w = NSAttributedString(string: s, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)])
                    .size().width
                put(s, x: col.midX - w / 2, y: max(barTop - 2, bar.minY - 13), size: 9.5,
                    weight: .medium, color: .secondaryLabelColor, mono: true)
            }
        }

        // 時刻の目盛り。3時間おきに置く。
        for i in stride(from: 0, to: 24, by: 3) {
            put("\(i)時", x: gutter + CGFloat(i) * colW + 2, y: labelTop + 1, size: 9.5,
                color: .tertiaryLabelColor)
        }

        drawPlaces(top: bounds.height - placeH, colW: colW)
    }

    /// 帯の下に「いつ、どこにつないでいたか」を区間で並べる。
    /// 上の柱と下の行を結ぶのはこの帯なので、色だけでなく名前も必ず書く。
    private func drawPlaces(top: CGFloat, colW: CGFloat) {
        var i = 0
        while i < hours.count {
            guard let key = dominant(hours[i]) else { i += 1; continue }
            var j = i
            while j + 1 < hours.count, dominant(hours[j + 1]) == key { j += 1 }

            let span = (i...j).reduce(0.0) { $0 + (hours[$1].byKey[key] ?? 0) }
            let x = gutter + CGFloat(i) * colW + 2.5
            let w = CGFloat(j - i + 1) * colW - 5
            let dim = (selectedKey != nil && selectedKey != key) || span < 600
            let c = Palette.id(key, in: places)
            c.withAlphaComponent(dim ? 0.25 : 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: top + 2, width: w, height: 5),
                         xRadius: 2.5, yRadius: 2.5).fill()
            // 数分しか居なかった区間に名前を出すと、潰れた文字が並ぶだけで読めない
            if span >= 600 {
                put(name(key), x: x, y: top + 10, size: 10,
                    weight: dim ? .regular : .medium,
                    color: dim ? .tertiaryLabelColor : .secondaryLabelColor,
                    maxWidth: w)
            }
            i = j + 1
        }
    }
}

// MARK: - どこ

/// 比べるための1行。
///
/// 数字だけを並べても「15 は良いのか悪いのか」が分からない。
/// 値のすぐ下に何の値かを書き、位置を揃えて、初めて比較になる。
final class CompareRow: NSView {
    let place: PlaceSummary
    private let accent: NSColor
    var selected: Bool { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hover = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// 右側に固定幅で置く数字の列。名前の長さで位置がずれないようにする。
    /// どの列も「ふだん / 悪いとき」の対で出す。代表値だけを並べると、
    /// ほとんど快適だが時々完全に崩れる場所と、常にそこそこの場所が同じ数字になる。
    enum Cell { case span, rtt, jitter, loss, rssi }
    static let cells: [(kind: Cell, title: String, width: CGFloat)] = [
        (.span, "使った時間", 88), (.rtt, "応答 ms", 84), (.jitter, "ゆらぎ ms", 84),
        (.loss, "とりこぼし %", 84), (.rssi, "電波 dBm", 84),
    ]
    static let scoreW: CGFloat = 116

    init(_ p: PlaceSummary, accent: NSColor, selected: Bool) {
        self.place = p; self.accent = accent; self.selected = selected
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                 .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hover = true }
    override func mouseExited(with e: NSEvent) { hover = false }
    override func mouseDown(with e: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        guard place.enough, let mid = place.score.mid else {
            return "\(place.name)。記録が短く判定できません"
        }
        var t = "\(place.name)。ふだん \(Int(mid))点 \(Palette.word(place.level))"
        if let bad = place.score.bad { t += "、悪いとき \(Int(bad))点" }
        t += "。\(PlaceReport.spanWord(place.seconds))つないで、\(place.detail)"
        return t
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    static func timeWord(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)分" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)時間" : "\(h)時間\(m)分"
    }

    override func draw(_ dirty: NSRect) {
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.10)
                  : NSColor.labelColor.withAlphaComponent(hover ? 0.07 : 0.03)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        // 地との差が 1.07:1 しかなく、行の矩形が見えない。枠で境目を作る。
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.6) : NSColor.separatorColor)
            .setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                  xRadius: 8, yRadius: 8)
        border.lineWidth = selected ? 1.5 : 1
        border.stroke()

        // 左端の色。上の帯の区間と同じ色で、どの時間帯の話かを結ぶ。
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 8, width: 4, height: bounds.height - 16),
                     xRadius: 2, yRadius: 2).fill()

        var right = bounds.width - 12
        for cell in CompareRow.cells.reversed() {
            drawCell(cell, rightEdge: right)
            right -= cell.width
        }
        drawScore(rightEdge: right)

        // 名前の欄が余りを全部取ると、名前と数字の間に数百ptの空白ができて
        // 目で結べなくなる。上限を置いて、余りは数字側に寄せる。
        let nameW = min(340, max(90, right - CompareRow.scoreW - 20))
        put(place.name, x: 14, y: 9, size: 14, weight: .semibold, maxWidth: nameW)
        let sub = [place.sub, place.hourWord].filter { !$0.isEmpty }.joined(separator: " ・ ")
        put(sub, x: 14, y: 30, size: 11, color: .secondaryLabelColor, maxWidth: nameW)
        put(place.detail, x: 14, y: 47, size: 11,
            color: place.badSeconds > 0 ? .secondaryLabelColor : .tertiaryLabelColor,
            maxWidth: nameW)
    }

    private func drawScore(rightEdge: CGFloat) {
        guard place.enough, let mid = place.score.mid else {
            putRight("—", rightEdge: rightEdge, y: 8, size: 27, weight: .semibold,
                     color: .tertiaryLabelColor)
            putRight("記録不足", rightEdge: rightEdge, y: 44, size: 10.5,
                     color: .tertiaryLabelColor, mono: false)
            return
        }
        let c = Palette.level(place.level)
        var right = rightEdge
        if let bad = place.score.bad, bad < mid - 2 {
            right -= putRight(" / \(Int(bad))", rightEdge: rightEdge, y: 16, size: 15,
                              color: Palette.scoreColor(Int(bad)))
        }
        putRight("\(Int(mid))", rightEdge: right, y: 8, size: 27, weight: .semibold, color: c)
        putRight(Palette.word(place.level), rightEdge: rightEdge, y: 44, size: 10.5,
                 weight: .medium, color: c, mono: false)
    }

    /// 良し悪しの手がかりが無い数字は比較に使えない。しきい値を超えた側だけ色を付ける。
    private func tint(_ kind: CompareRow.Cell, _ v: Double) -> NSColor {
        switch kind {
        case .rtt:    return v > 50 ? .systemRed : (v > 25 ? .systemOrange : .labelColor)
        case .jitter: return v > 40 ? .systemRed : (v > 20 ? .systemOrange : .labelColor)
        case .loss:   return v > 5 ? .systemRed : (v > 1 ? .systemOrange : .labelColor)
        case .rssi:   return v < -70 ? .systemRed : (v < -60 ? .systemOrange : .labelColor)
        case .span:   return .labelColor
        }
    }

    private func drawCell(_ cell: (kind: CompareRow.Cell, title: String, width: CGFloat),
                          rightEdge: CGFloat) {
        putRight(cell.title, rightEdge: rightEdge, y: 44, size: 10.5,
                 color: .secondaryLabelColor, mono: false)

        // 使った時間だけは裾を持たない。1つの値で足りる。
        if cell.kind == .span {
            putRight(PlaceReport.spanWord(place.seconds), rightEdge: rightEdge, y: 18, size: 16)
            return
        }
        guard place.enough else {
            putRight("—", rightEdge: rightEdge, y: 18, size: 16, color: .tertiaryLabelColor)
            return
        }
        let v = CompareRow.value(place, cell.kind)
        drawPair(v.mid, v.bad, cell.kind, rightEdge)
    }

    /// どの列に何の値を出すか。描画から切り出しておく。
    /// 見出しの文字列で振り分けていたときは、見出しを直しただけで
    /// 全列が同じ値になり、それをテストが素通りした。
    static func value(_ p: PlaceSummary, _ kind: Cell) -> (mid: Double?, bad: Double?) {
        switch kind {
        case .rtt:    return (p.rtt.mid, p.rtt.bad)
        case .jitter: return (p.jitter.mid, p.jitter.bad)
        // 損失率の中央値は5発中0発が大半で常に0になり、何も区別できない。
        // 「1回でも落ちた計測の割合」なら差が出る。
        case .loss:   return (p.lossRatio.map { $0 * 100 }, nil)
        case .rssi:   return (p.rssi.map { Double($0) }, nil)
        case .span:   return (p.seconds, nil)
        }
    }

    private func drawPair(_ mid: Double?, _ bad: Double?, _ kind: CompareRow.Cell,
                          _ rightEdge: CGFloat) {
        var right = rightEdge
        if let bad, bad > (mid ?? 0) + 1 {
            right -= putRight(" / \(Int(bad.rounded()))", rightEdge: right, y: 20, size: 14,
                              color: tint(kind, bad))
        }
        guard let mid else {
            putRight("—", rightEdge: right, y: 18, size: 16, color: .tertiaryLabelColor)
            return
        }
        let text = kind == .loss ? String(format: "%.1f", mid) : "\(Int(mid.rounded()))"
        putRight(text, rightEdge: right, y: 18, size: 16, color: tint(kind, mid))
    }
}

// MARK: - ウィンドウ

/// スクロールの中身に使う縦スタック。
/// 上下が反転していないと、内容がはみ出したときに下端から表示されてしまう。
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class HistoryWindowController: NSWindowController {
    private let log: SampleLog
    private let chart = ChartView()
    private let text = NSTextView()
    private let rangePop = NSPopUpButton()
    private let unitSeg = NSSegmentedControl(labels: ["APごと", "接続先ごと"],
                                             trackingMode: .selectOne, target: nil, action: nil)
    private let clearButton = NSButton()
    private let verdict = VerdictCard()
    private let hourStrip = HourStripView()
    private let hoursTitle = NSTextField(labelWithString: "時間ごとの調子")
    private let hoursHint = NSTextField(labelWithString: "")
    private let placesTitle = NSTextField(labelWithString: "つないでいた先")
    private let placesHint = NSTextField(labelWithString: "")
    private let placeStack = FlippedStackView()
    private let detailToggle = NSButton()
    private let detailBox = NSStackView()

    private var current: [Sample] = []
    private var places: [PlaceSummary] = []
    private var rows: [PlaceSummary] = []
    private var grouping: PlaceGrouping = .ap
    private var selectedKey: String?
    private var selectedHour: Int?
    private var showsDetail = false
    /// 折りたたみを開いたときに描く対象。開くまで組み立てない。
    private var detailSamples: [Sample] = []

    private let ranges: [(String, Int)] = [
        ("今日", 1), ("過去3日", 3), ("過去7日", 7), ("過去30日", 30)
    ]

    init(log: SampleLog) {
        self.log = log
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "WiFiDoctor — いつ・どこが遅かったか"
        w.minSize = NSSize(width: 820, height: 560)
        w.acceptsMouseMovedEvents = true
        super.init(window: w)
        build()
        // 保存済みのサイズを使うが、壊れて極端に小さい場合は既定に戻す。
        // 一度潰れたサイズが保存されると、次から開くたびに潰れたままになる。
        // テスト中は保存しない。利用者が調整した位置とサイズを潰してしまう。
        if let name = Settings.windowAutosaveName("WiFiDoctorHistory") {
            w.setFrameAutosaveName(name)
        }
        // 復元値は minSize でクランプされてから返るので、minSize と比べても必ず通ってしまう。
        // 中身が必要としている大きさと比べ、足りなければ既定に戻す。
        let need = w.contentView?.fittingSize ?? .zero
        if w.frame.width < need.width || w.frame.height < need.height {
            w.setFrame(NSRect(x: 0, y: 0, width: max(940, need.width),
                              height: max(720, need.height + 28)), display: false)
            w.center()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 見出しと、その右に添える小さな説明を1行にする。
    private func titleRow(_ title: NSTextField, _ hint: NSTextField,
                          control: NSView? = nil) -> NSStackView {
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        var views: [NSView] = [title]
        if let control { views.append(control) }
        views.append(contentsOf: [hint, NSView()])
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 10
        s.alignment = .centerY
        return s
    }

    private func build() {
        guard let content = window?.contentView else { return }

        rangePop.addItems(withTitles: ranges.map { $0.0 })
        rangePop.target = self; rangePop.action = #selector(reloadAction)

        unitSeg.selectedSegment = 0
        unitSeg.target = self; unitSeg.action = #selector(unitChanged)
        unitSeg.controlSize = .small

        clearButton.title = "すべて表示に戻す"
        clearButton.bezelStyle = .rounded
        clearButton.target = self; clearButton.action = #selector(clearSelection)
        clearButton.isHidden = true

        let bar = NSStackView(views: [
            NSTextField(labelWithString: "期間"), rangePop,
            NSView(),
            clearButton,
            NSButton(title: "更新", target: self, action: #selector(reloadAction)),
            NSButton(title: "レポートを書き出す", target: self, action: #selector(exportReport)),
        ])
        bar.orientation = .horizontal; bar.spacing = 8

        hourStrip.onSelectHour = { [weak self] h in self?.selectHour(h) }
        hourStrip.onHover = { [weak self] t in self?.showHint(t) }

        placeStack.orientation = .vertical
        placeStack.alignment = .leading
        placeStack.spacing = 6

        let placeScroll = NSScrollView()
        placeScroll.documentView = placeStack
        // documentView にすると自動サイズ調整が付き、幅も高さも 0 に固定されてしまう。
        placeStack.translatesAutoresizingMaskIntoConstraints = false
        placeScroll.hasVerticalScroller = true
        placeScroll.drawsBackground = false
        placeScroll.borderType = .noBorder

        // 詳しい情報は既定でたたんでおく。普段見るものではない。
        detailToggle.title = "▸ 詳しく見る（グラフと生のレポート）"
        detailToggle.bezelStyle = .inline
        detailToggle.setButtonType(.momentaryPushIn)
        detailToggle.target = self
        detailToggle.action = #selector(toggleDetail)

        text.isEditable = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 10)
        let textScroll = NSScrollView()
        textScroll.documentView = text
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder

        let legend = NSStackView()
        legend.orientation = .horizontal
        legend.spacing = 10
        for v in [Verdict.ok, .congested, .sticky, .weak, .isp, .selfTraffic] {
            let l = NSTextField(labelWithString: "■ \(v.label)")
            l.font = .systemFont(ofSize: 10)
            l.textColor = ChartView.color(v.rawValue)
            legend.addArrangedSubview(l)
        }
        legend.addArrangedSubview(NSView())

        detailBox.orientation = .vertical
        detailBox.alignment = .leading
        detailBox.spacing = 8
        detailBox.setViews([chart, legend, textScroll], in: .top)
        detailBox.isHidden = true
        fillWidth(detailBox)

        let hoursHead = titleRow(hoursTitle, hoursHint)
        let placesHead = titleRow(placesTitle, placesHint, control: unitSeg)

        // 縦に積むものはすべて幅いっぱい。alignment に .width は使えない
        // （縦スタックでは無効な値で、黙って .notAnAttribute になる。すると
        // 揃える制約が一切張られず、子は最小幅のまま右端に寄る）。
        // .leading で左端を揃え、幅は fillWidth で個別に張る。
        //
        // 上から「結論」→「いつ」→「どこ」。
        // 結論だけ読んで閉じてもよく、確かめたい人は下へ進める順にする。
        // ボタンを幅いっぱいに伸ばすと文字が中央に来て、無効なラベルに見える。左に寄せる。
        let toggleRow = NSStackView(views: [detailToggle, NSView()])
        toggleRow.orientation = .horizontal

        let stack = NSStackView(views: [bar, verdict, hoursHead, hourStrip,
                                        placesHead, placeScroll,
                                        toggleRow, detailBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        fillWidth(stack)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // 子の幅をスタックに合わせた以上、横幅を押し広げるものが無くなる。
            // 下限を置かないと折り返しラベルが縦に伸びきって、窓ごと細長く潰れる。
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 820),
            verdict.heightAnchor.constraint(equalToConstant: 92),
            hourStrip.heightAnchor.constraint(equalToConstant: 154),
            // スクロールの中身は、自分で clip view に留めないと位置も幅も決まらない。
            // 高さだけは行の積み上げに任せる（それがスクロール量になる）。
            placeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            placeStack.topAnchor.constraint(equalTo: placeScroll.contentView.topAnchor),
            placeStack.leadingAnchor.constraint(equalTo: placeScroll.contentView.leadingAnchor),
            placeStack.widthAnchor.constraint(equalTo: placeScroll.contentView.widthAnchor),
            // 直値の高さを required にすると、詳細を開いた瞬間に窓が
            // 画面より高くなって下が欠ける。譲れる形にして、狭い画面では縮める。
            chart.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])
        // 好みの高さを制約で書くと、優先度を下げても fittingSize に入ってしまい、
        // 詳細を開いた瞬間に窓が画面より高くなる（下が欠けて縮められない）。
        // 下限だけを制約にして、余った高さは「伸びやすさ」の順で配る。
        chart.setContentHuggingPriority(.init(250), for: .vertical)
        textScroll.setContentHuggingPriority(.init(249), for: .vertical)
        placeScroll.setContentHuggingPriority(.init(251), for: .vertical)

        // 横に並べるものが縦幅を押し広げないようにする
        for v in [bar, hoursHead, placesHead, toggleRow] as [NSView] {
            v.setContentHuggingPriority(.defaultHigh, for: .vertical)
        }
        verdict.setContentHuggingPriority(.defaultHigh, for: .vertical)
        hourStrip.setContentHuggingPriority(.defaultHigh, for: .vertical)
        detailToggle.setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    /// 縦スタックの子を、余白を除いた幅いっぱいに広げる。
    private func fillWidth(_ stack: NSStackView) {
        let inset = stack.edgeInsets.left + stack.edgeInsets.right
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
        }
    }

    @objc private func toggleDetail() {
        showsDetail.toggle()
        if showsDetail { renderDetail() }
        detailBox.isHidden = !showsDetail
        detailToggle.title = showsDetail
            ? "▾ 詳しい情報を閉じる"
            : "▸ 詳しく見る（グラフと生のレポート）"
    }

    @objc private func reloadAction() { reload() }

    @objc private func unitChanged() {
        grouping = unitSeg.selectedSegment == 1 ? .network : .ap
        selectedKey = nil          // 単位が変われば鍵の意味も変わる
        render()
    }

    @objc private func clearSelection() {
        selectedKey = nil; selectedHour = nil; render()
    }

    private func selectHour(_ h: Int?) { selectedHour = h; render() }
    private func select(_ key: String) {
        selectedKey = (selectedKey == key) ? nil : key
        render()
    }

    /// カーソルが指している時間の説明。見出しの右に出して、画面が飛び跳ねないようにする。
    private func showHint(_ t: String?) {
        hoursHint.stringValue = t ?? defaultHint
    }

    /// カーソルを合わせている時間の内訳だけを出す。操作の説明は書かない。
    private var defaultHint: String {
        selectedHour.map { "\($0)時台" } ?? ""
    }

    /// 読み込みは裏で行う。30日ぶんは10万件を超え、main で回すと数秒固まる。
    /// 途中で期間を切り替えたときに古い結果で上書きしないよう、世代で弾く。
    private var loadGeneration = 0

    func reload() {
        let days = ranges[max(0, rangePop.indexOfSelectedItem)].1
        loadGeneration += 1
        let generation = loadGeneration
        if current.isEmpty {
            verdict.set(score: nil, bad: nil, level: .offline, lines: ["記録を読み込んでいます…"])
        }
        let log = self.log
        DispatchQueue.global(qos: .userInitiated).async {
            let cal = Calendar.current
            var all: [Sample] = []
            for d in 0..<days {
                guard let date = cal.date(byAdding: .day, value: -d, to: Date()) else { continue }
                all.append(contentsOf: log.load(date: date))
            }
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                self.apply(all)
            }
        }
    }

    /// 記録を受け取って描き直す。動作確認から実データ無しで呼べるように分けてある。
    func apply(_ all: [Sample]) {
        current = Sample.representative(all.sorted { $0.at < $1.at })
        selectedHour = nil; selectedKey = nil
        render()
    }

    /// 上の帯と下の行を、同じ選択状態から一度に描き直す。
    /// 別々に更新すると、片方だけ古い状態が残って話が食い違う。
    /// 集計の結果。作るのは重いので、まとめて作ってから一度に描く。
    private struct Computed {
        var places: [PlaceSummary]
        var rows: [PlaceSummary]
        var hours: [HourSummary]
        var focus: ([Sample], [TimeInterval])
    }

    /// 描き直しの世代。裏で作っている間に選択が変わったら、古い結果は捨てる。
    private var renderGeneration = 0

    /// この件数を超えたら裏で集計する。
    /// 30日ぶんは10万件を超え、選択のたびに全部やり直すと操作が引っかかる。
    /// 少ないうちに裏へ回すと、描き直しが1拍遅れて見えるだけで損。
    private static let asyncThreshold = 20_000

    /// 上の帯と下の行を、同じ選択状態から一度に描き直す。
    /// 別々に更新すると、片方だけ古い状態が残って話が食い違う。
    private func render() {
        renderGeneration += 1
        let generation = renderGeneration
        let samples = current
        let grouping = self.grouping
        let hour = selectedHour
        let key = selectedKey
        let days = ranges[max(0, rangePop.indexOfSelectedItem)].1

        // 文字だけの更新は待たせない
        hoursTitle.stringValue = days > 1
            ? "時間帯ごとの調子（\(days)日ぶんの合計）" : "時間ごとの調子"
        hoursHint.stringValue = defaultHint
        placesTitle.stringValue = hour.map { "\($0)時台につないでいた先" }
            ?? "つないでいた先を比べる"
        clearButton.isHidden = key == nil && hour == nil

        let work = { HistoryWindowController.compute(samples, grouping: grouping,
                                                     hour: hour, key: key) }
        if samples.count < HistoryWindowController.asyncThreshold {
            show(work(), days: days)
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let c = work()
                DispatchQueue.main.async {
                    guard generation == self.renderGeneration else { return }
                    self.show(c, days: days)
                }
            }
        }
    }

    /// 画面に触らない集計。裏でも同じものを作れるように分けてある。
    private static func compute(_ samples: [Sample], grouping: PlaceGrouping,
                                hour: Int?, key: String?) -> Computed {
        // 代表秒数は全部の集計の土台になる。中で sort が走るので一度だけ求めて配って回る。
        let durs = Sample.durations(samples)
        let places = PlaceReport.summaries(samples, by: grouping, durations: durs)

        // 下の行は「選んだ時間だけ」に切り替わる。
        // 帯は1日を見渡すものなので常に全時間ぶんを描き、選択外を薄くする（消さない）。
        let cal = Calendar.current
        let table = hour.map { h in
            slice(samples, durs) { cal.component(.hour, from: $0.at) == h }
        } ?? (samples, durs)

        // 結論・グラフ・書き出しは、いま画面が見せている範囲と同じものを見る。
        // ここがずれると、12時台を選んで書き出したのに丸1日分が出る。
        var focus = table
        if let key, places.contains(where: { $0.key == key }) {
            focus = slice(table.0, table.1) {
                (grouping == .ap ? $0.bssid : $0.ssid) == key
            }
        }
        return Computed(places: places,
                        rows: PlaceReport.summaries(table.0, by: grouping, durations: table.1),
                        hours: HourReport.hours(samples, by: grouping, durations: durs),
                        focus: focus)
    }

    private func show(_ c: Computed, days: Int) {
        places = c.places
        if selectedKey != nil, !places.contains(where: { $0.key == selectedKey }) {
            selectedKey = nil
            clearButton.isHidden = selectedHour == nil
        }
        rows = c.rows

        hourStrip.places = places
        hourStrip.hours = c.hours
        hourStrip.days = days
        hourStrip.selectedKey = selectedKey
        hourStrip.selectedHour = selectedHour

        renderRows()
        renderVerdict(c.focus.0, c.focus.1, days: days)
        detailSamples = c.focus.0
        if showsDetail { renderDetail() }
    }

    /// 標本とその代表秒数を、対にしたまま絞り込む。
    private static func slice(_ s: [Sample], _ d: [TimeInterval],
                              _ keep: (Sample) -> Bool) -> ([Sample], [TimeInterval]) {
        var os: [Sample] = [], od: [TimeInterval] = []
        for (i, x) in s.enumerated() where keep(x) { os.append(x); od.append(d[i]) }
        return (os, od)
    }


    private func renderRows() {
        placeStack.arrangedSubviews.forEach {
            placeStack.removeArrangedSubview($0); $0.removeFromSuperview()
        }
        guard !rows.isEmpty else {
            // なぜ空なのかを書く。効いている条件を並べないと、壊れたのかと思われる。
            let cond = [selectedHour.map { "\($0)時台" },
                        selectedKey.flatMap { k in places.first { $0.key == k }?.name }]
                .compactMap { $0 }.joined(separator: " ・ ")
            let t = NSTextField(wrappingLabelWithString: current.isEmpty || cond.isEmpty
                ? "この期間の記録がまだありません。しばらく使うと、つないでいた先がここに並びます。\n"
                    + "APに呼び名を付けておくと、会議室の名前で並びます。"
                : "\(cond)の記録はありません。")
            t.font = .systemFont(ofSize: 12)
            t.textColor = .secondaryLabelColor
            placeStack.addArrangedSubview(t)
            return
        }
        for p in rows {
            let row = CompareRow(p, accent: Palette.id(p.key, in: places),
                                 selected: p.key == selectedKey)
            row.onClick = { [weak self] in self?.select(p.key) }
            row.translatesAutoresizingMaskIntoConstraints = false
            placeStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: placeStack.widthAnchor),
                row.heightAnchor.constraint(equalToConstant: 72),
            ])
        }
    }

    /// 折りたたんだ中身は、開くまで作らない。
    /// レポート本文の組み立ては記録の量に比例して重く、畳んだままなら誰も見ない。
    private func renderDetail() {
        chart.samples = SampleLog.downsample(detailSamples, maxCount: 4000)
        text.string = log.report(samples: detailSamples, title: reportTitle,
                                 alreadyFiltered: true)
    }

    /// 書き出しに、いま何で絞っているのかを残す。受け取った人が範囲を誤解しないため。
    private var reportTitle: String {
        var t = ranges[max(0, rangePop.indexOfSelectedItem)].0
        if let h = selectedHour { t += " \(h)時台" }
        if let n = selectedKey.flatMap({ k in places.first { $0.key == k }?.name }) { t += " / \(n)" }
        return t
    }

    /// いちばん上の結論。数字を並べる前に、まず言い切る。
    private func renderVerdict(_ s: [Sample], _ d: [TimeInterval], days: Int) {
        guard !s.isEmpty else {
            verdict.set(score: nil, bad: nil, level: .offline, lines: ["まだ記録がありません。"])
            return
        }
        // つながっていなかった時間は「調子」ではないので、点数の集計から外す。
        var scores: [(Double, TimeInterval)] = []
        var connected: TimeInterval = 0
        var badSeconds: TimeInterval = 0
        var byVerdict: [Verdict: TimeInterval] = [:]
        for (i, x) in s.enumerated() where x.associated && x.scoreVerdict != .offline {
            scores.append((Double(x.score), d[i]))
            connected += d[i]
            let v = x.scoreVerdict ?? .ok
            if v.isProblem { badSeconds += d[i]; byVerdict[v, default: 0] += d[i] }
        }
        guard connected > 0, let mid = PlaceReport.quantile(scores, 0.5) else {
            verdict.set(score: nil, bad: nil, level: .offline,
                        lines: ["この範囲には、つながっていた記録がありません。"])
            return
        }
        let low = PlaceReport.quantile(scores, 0.10)

        let where_ = [selectedHour.map { "\($0)時台" },
                      selectedKey.flatMap { k in places.first { $0.key == k }?.name }]
            .compactMap { $0 }.joined(separator: "・")
        let head = where_.isEmpty
            ? ranges[max(0, rangePop.indexOfSelectedItem)].0
            : "\(ranges[max(0, rangePop.indexOfSelectedItem)].0)の \(where_)"
        var lines = ["\(head)は \(PlaceReport.spanWord(connected))つないで、"
                     + (badSeconds < 30 ? "崩れた時間はありませんでした。"
                        : "そのうち \(PlaceReport.spanWord(badSeconds)) は崩れていました。")]

        // 2行目に「いつ・どこ・なぜ」を1文で。打ち手の長文はレポート側に置く。
        let hours = HourReport.hours(s, by: grouping, durations: d)
        var second: [String] = []
        if let w = HourReport.worst(hours, days: days) {
            // 過半数を占めていない先を名指しすると、行き来していただけの場所を犯人にする。
            let top = w.byKey.max { $0.value < $1.value }
            let who = (top.map { $0.value > w.seconds * 0.5 } ?? false)
                ? top.flatMap { pair in places.first { $0.key == pair.key }?.name } : nil
            second.append("いちばん悪かったのは \(w.hour)時台"
                + (who.map { "の \($0)" } ?? "") + "（\(w.score)点）")
        }
        if let top = byVerdict.max(by: { $0.value < $1.value }), top.value > connected * 0.1 {
            second.append("多くは「\(top.key.plainCause)」時間")
        }
        if !second.isEmpty { lines.append(second.joined(separator: "、") + "。") }

        verdict.set(score: Int(mid.rounded()), bad: low.map { Int($0.rounded()) },
                    level: Palette.level(score: Int(mid.rounded()),
                                         badRatio: badSeconds / connected),
                    lines: lines)
    }

    @objc private func exportReport() {
        let p = NSSavePanel()
        let f = SampleLog.dayFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        p.nameFieldStringValue = "wifi-report-\(f.string(from: Date())).txt"
        // 畳んだままでも書き出せるように、ここで組み立てる
        let body = text.string.isEmpty
            ? log.report(samples: detailSamples, title: reportTitle, alreadyFiltered: true)
            : text.string
        guard let window else { return }
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let url = p.url else { return }
            do {
                try body.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // 黙って消えると、渡したつもりのファイルが無い状態になる
                let a = NSAlert()
                a.messageText = "書き出せませんでした"
                a.informativeText = error.localizedDescription
                a.beginSheetModal(for: window)
            }
        }
    }
}
