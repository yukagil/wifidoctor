import SwiftUI

/// パネルの寸法。文字が切れないだけの幅を確保する。
enum PanelMetrics {
    static let width: CGFloat = 386
    /// スコアの枠。3桁（100点）が入るだけの幅が要る。
    static let scoreWidth: CGFloat = 46
    /// ヘッダーの文章に使える幅（左右余白・アイコン・スコアを除いた残り）
    static let headerTextWidth: CGFloat = width - 32 - 40 - 11 - 6 - scoreWidth
}

// MARK: - 経路図

/// パソコン →(無線)→ Wi-Fi機器 →(回線)→ インターネット を横一列に描き、
/// 詰まっている区間を赤く名指しする。数値を読めなくても原因の位置が分かることが目的。
struct PathDiagram: View {
    let snap: Snapshot

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(snap.nodes.enumerated()), id: \.element.id) { idx, node in
                    NodeChip(node: node)
                    if idx < snap.segments.count {
                        SegmentBar(seg: snap.segments[idx])
                    }
                }
            }
        }
    }
}

private struct NodeChip: View {
    let node: PathNode
    /// 正常か異常かで色の濃さを変える。色そのものは正常時も残す（状態が一目で分かるため）。
    private var normal: Bool { node.level == .good }

    var body: some View {
        VStack(spacing: 4) {
            // 正常なノードは無彩色にする。全部に色を塗ると色が情報を持たなくなり、
            // どこが問題なのか読み取れなくなるため。
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(node.level.tint.opacity(normal ? 0.13 : 0.20))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(node.level.tint.opacity(normal ? 0.32 : 0.55), lineWidth: 1)
                Image(systemName: node.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(node.level.textTint)
            }
            .frame(width: 46, height: 40)

            Text(node.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(node.caption ?? " ")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 66, height: 68, alignment: .top)
    }
}

private struct SegmentBar: View {
    let seg: PathSegment

    /// 色は常に出す。原因の区間は「太さ」と「濃さ」と「ラベル」で差をつける。
    private var barColor: Color {
        seg.level.tint.opacity(seg.culprit ? 1.0 : 0.55)
    }
    private var wordColor: Color { seg.level.textTint }

    var body: some View {
        VStack(spacing: 3) {
            // 原因の区間だけラベルを立てる。常時出すと視線が散る。
            Text(seg.culprit ? "ここが原因" : " ")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(seg.level.textTint)
                .lineLimit(1)

            ZStack {
                Capsule()
                    .fill(barColor)
                    .frame(height: seg.culprit ? 6 : 3)
                if seg.culprit {
                    // 詰まりを点で表現する
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(.white.opacity(0.9)).frame(width: 3, height: 3)
                        }
                    }
                }
            }
            .frame(height: 8)

            Text(seg.word)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(wordColor)
                .lineLimit(1)
            Text(seg.value)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 44)
        .padding(.top, 12)
    }
}

// MARK: - 直近1時間のミニグラフ

struct MiniTrend: View {
    let samples: [Sample]

    private let barH: CGFloat = 14
    private let axisH: CGFloat = 12
    /// 表示する時間帯。深夜は働かないので既定では映さず、
    /// 日中の解像度に幅を回す。ただし記録があれば必ず映す（黙って隠さない）。
    private let defaultStartHour = 6

    private func window(now: Date) -> (start: Date, end: Date, startHour: Int) {
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: now)
        var startHour = defaultStartHour
        if let first = samples.first?.at {
            let h = cal.component(.hour, from: first)
            if h < startHour { startHour = h }      // 深夜の記録があるなら隠さない
        }
        let start = midnight.addingTimeInterval(TimeInterval(startHour) * 3600)
        let end = midnight.addingTimeInterval(24 * 3600)
        return (start, end, startHour)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("今日の調子")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            // 横軸は常に 0:00〜24:00 で固定する。記録のある時間だけが塗られ、
            // 目盛りの位置が日によってズレないので、予定と突き合わせて読める。
            Canvas { ctx, size in
                let now = Date()
                let w = window(now: now)
                let start = w.start
                let span = w.end.timeIntervalSince(w.start)

                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: barH),
                              cornerRadius: 4),
                         with: .color(.primary.opacity(0.09)))

                func x(_ d: Date) -> CGFloat {
                    CGFloat(min(1, max(0, d.timeIntervalSince(start) / span))) * size.width
                }

                // 1日ぶんは最大17000点になるので列ごとに集約する。
                // 集約時は「その時間帯で最も悪かった状態」を採る（短時間の悪化を消さないため）。
                let colW: CGFloat = 2
                let cols = max(1, Int(size.width / colW))
                var worstScore = [Int](repeating: Int.max, count: cols)
                var worstVerdict = [String?](repeating: nil, count: cols)

                for s in samples {
                    let t = s.at.timeIntervalSince(start) / span
                    guard t >= 0, t <= 1 else { continue }
                    let c = min(cols - 1, max(0, Int(t * Double(cols))))
                    if s.score < worstScore[c] {
                        worstScore[c] = s.score
                        worstVerdict[c] = s.verdict
                    }
                }

                for c in 0..<cols {
                    guard let v = worstVerdict[c] else { continue }   // 記録が無い時間は塗らない
                    let lv = Phrase.level(score: worstScore[c], verdict: Verdict(rawValue: v) ?? .ok)
                    ctx.fill(Path(CGRect(x: CGFloat(c) * colW, y: 0,
                                         width: colW + 0.5, height: barH)),
                             with: .color(lv.tint))
                }

                // 3時間ごとの目盛り
                var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
                for h in stride(from: w.startHour + 3, through: 21, by: 3) {
                    comps.hour = h; comps.minute = 0
                    guard let tick = Calendar.current.date(from: comps) else { continue }
                    let tx = x(tick)
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: tx, y: 0))
                        p.addLine(to: CGPoint(x: tx, y: barH))
                    }, with: .color(.primary.opacity(0.22)), lineWidth: 0.5)

                    // 「今」の目印と重なる目盛りラベルは出さない
                    if h % 6 == 0, abs(tx - x(now)) > 14 {
                        var text = ctx.resolve(Text("\(h)").font(.system(size: 8)))
                        text.shading = .color(.secondary)
                        ctx.draw(text, at: CGPoint(x: tx, y: barH + 6), anchor: .center)
                    }
                }

                // 「今」の位置。固定軸なので、どこまで進んだかを示す印が要る。
                let nx = x(now)
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: nx, y: -1))
                    p.addLine(to: CGPoint(x: nx, y: barH + 1))
                }, with: .color(.primary), lineWidth: 1.5)
                var nowLabel = ctx.resolve(Text("今").font(.system(size: 8, weight: .bold)))
                nowLabel.shading = .color(.primary)
                ctx.draw(nowLabel,
                         at: CGPoint(x: min(max(6, nx), size.width - 6), y: barH + 6),
                         anchor: .center)
            }
            .frame(height: barH + axisH)

            HStack(spacing: 0) {
                Text("\(window(now: Date()).startHour):00")
                    .font(.system(size: 8.5)).foregroundStyle(.secondary)
                Spacer()
                Text("24:00").font(.system(size: 8.5)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 大きなボタン

struct BigButtonStyle: ButtonStyle {
    var tint: Color
    var enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.75 : 1.0))
            )
            .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - ホーム

struct HomeView: View {
    @ObservedObject var app: AppState

    private var snap: Snapshot { app.snap }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // 位置情報が無いと、接続先の名前・場所ごとの比較・切替候補が全部死ぬ。
            // macOSは許可の確認を一度しか出さないので、断った人は自力で戻れない。
            // 色や絵では伝えられないので、ここだけは文と導線を置く。
            if snap.locationDenied {
                Button(action: { app.openLocationSettings() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "location.slash")
                            .font(.system(size: 11))
                        Text("位置情報の許可が無いため、接続先を識別できません")
                            .font(.system(size: 11))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(Level.fair.textTint)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Level.fair.tint.opacity(0.12))
                }
                .buttonStyle(.plain)
            }

            // 状態の一言 + スコア
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    Circle().fill(snap.level.tint.opacity(0.15))
                    Image(systemName: Level.symbol(for: snap.level, measuring: snap.measuring))
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(snap.level.textTint)
                }
                .frame(width: 40, height: 40)

                // 文字数で高さが変わるとパネル全体がガタつくので、常に2行ぶん確保する
                VStack(alignment: .leading, spacing: 2) {
                    Text(snap.headline)
                        .font(.system(size: 15.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)   // 切るより縮めて全部見せる
                        // 縮小されると行の高さも変わるので、枠は固定しておく
                        .frame(height: 20, alignment: .leading)
                    // 操作の結果もここに出す。別枠を立てると画面が重くなる。
                    Text(app.flash ?? snap.subline)
                        .font(.system(size: 11.5))
                        .foregroundStyle(app.flash != nil ? Color.accentColor : Color.secondary)
                        .lineLimit(2)
                        .frame(height: 30, alignment: .topLeading)
                }
                Spacer(minLength: 6)

                // 再測定は常時自動で回っているので、目立たせず小さなアイコンに留める
                Button(action: { app.quickScan() }) {
                    if app.busy != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .disabled(app.busy != nil)
                .help(app.hotKeyOn ? "今すぐ測り直す（⌥⌘W）" : "今すぐ測り直す")

                // 総合スコア。細かい指標を見なくても良し悪しの度合いが分かる。
                VStack(spacing: 0) {
                    Text(snap.level == .offline ? "--" : "\(snap.score)")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(snap.level.textTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)   // 100点でも切らない
                        .frame(height: 26)
                    Text("スコア")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: PanelMetrics.scoreWidth)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 14)

            PathDiagram(snap: snap)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            // 今どのAPに繋がっているかは、遠いAPを掴んでいないかの判断に直結する。
            // 機器IDの末尾まで出すと、移動前後で同じAPかどうかが分かる。
            if let net = snap.network {
                // 名前を付ける入口はここ。表示している場所でそのまま直せるのが分かりやすい。
                Button(action: { app.reloadNamedAPs(); app.page = .naming }) {
                HStack(spacing: 5) {
                    Image(systemName: "wifi")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(net)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    if let ap = snap.apShort {
                        Text("・\(ap)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(snap.apNamed ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    if let since = snap.apSince {
                        Text("・\(Phrase.durationWord(since))接続中")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "pencil.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tint)
                    Spacer(minLength: 0)
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(snap.apNamed ? "呼び名を変える" : "この機器に呼び名を付ける")
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }

            // Macの状態も切り分けの片側。開かないと見えないのでは使えないので常時出す。
            Button(action: { app.page = .mac }) {
                HStack(spacing: 5) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 9))
                        .foregroundStyle(snap.macWarn ? Level.fair.textTint : Color.secondary)
                    Text(snap.macLine)
                        .font(.system(size: 9.5))
                        .foregroundStyle(snap.macWarn ? Level.fair.textTint : Color.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .frame(height: 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("このMacの負荷を見る")
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // 数値の目安が分からなくても判断できるよう、「で、何ができるか」を出す。
            // 常時判定できる2つ（遅延・ゆらぎ・損失で決まるもの）だけをここに置く。
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ForEach(snap.capabilities.filter { !$0.needsSpeedTest }.prefix(2)) { c in
                        CapabilityChip(c: c)
                    }
                }
                // 何を根拠に言っているかを隠さない。会議の品質は帯域ではなく
                // 遅延・ゆらぎ・損失で決まるので、そこを明示する。
                Text(snap.capabilities.first?.basis ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 12, alignment: .topLeading)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            Button(action: { app.openHistory?() }) {
                MiniTrend(samples: app.recentForDisplay)
            }
            .buttonStyle(.plain)
            .help("クリックすると推移のグラフを開きます")
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            // 打つ手があるときだけボタンを出す。
            // 手が無いときに「できることはありません」と書いても、読む人は何も得ない。
            if snap.primary != .none {
                VStack(spacing: 6) {
                    Button(action: { app.runPrimary() }) {
                        HStack(spacing: 7) {
                            if app.busy != nil {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: snap.primary.icon)
                            }
                            Text(app.busy ?? snap.primary.title)
                        }
                    }
                    .buttonStyle(BigButtonStyle(tint: .accentColor, enabled: app.busy == nil))
                    .disabled(app.busy != nil)

                    // VPN中につなぎ直すと、Wi-Fiだけでなく VPN のセッションも切れる。
                    // 押す前に知らせないと、会議や作業の途中で落ちる。
                    Text(snap.primary == .reconnect && snap.vpn != nil
                         ? "数秒だけ通信が切れます。VPNもつなぎ直しになります"
                         : snap.primary.caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(height: 24, alignment: .top)
                }
                .frame(height: 74)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Divider()

            HStack(spacing: 12) {
                FooterLink(title: "推移", icon: "chart.xyaxis.line") { app.openHistory?() }
                FooterLink(title: "詳細", icon: "list.bullet") { app.page = .detail }
                FooterLink(title: "速度", icon: "speedometer") {
                    app.reloadSpeedHistory(); app.page = .speedtest
                }
                FooterLink(title: "設定", icon: "gearshape") { app.page = .settings }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .frame(width: PanelMetrics.width)
    }
}

/// 乗り換え先の一覧。混雑しているときの本命の導線。
/// 「おすすめ」と「その他」を分けて、候補を隠さずに優先度だけ示す。
struct SwitchingView: View {
    @ObservedObject var app: AppState

    private var recommended: [NetworkCandidate] { app.snap.candidates.filter { $0.recommended } }
    private var others: [NetworkCandidate] { app.snap.candidates.filter { !$0.recommended } }

    var body: some View {
        SubPage(title: "別のWi-Fiに切り替える", back: { app.page = .home }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {

                    if app.snap.candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(app.snap.locationDenied
                                 ? "位置情報の許可が無いため、近くのWi-Fiを調べられません"
                                 : "切り替えられる回線が見つかりません")
                                .font(.system(size: 12, weight: .medium))
                            Text(app.snap.locationDenied
                                 ? "システム設定 > プライバシーとセキュリティ > 位置情報サービス で許可してください。"
                                 : "iPhoneのテザリング、または有線接続がもっとも確実です。席を移すのも有効です。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
                    }

                    if !recommended.isEmpty {
                        SectionLabel("おすすめ", note: "今より空いている / 電波が強い")
                        ForEach(recommended) { c in
                            CandidateRow(c: c, busy: app.busy != nil) { app.switchTo(c) }
                        }
                    }

                    if !others.isEmpty {
                        SectionLabel("この場所で見えているその他のWi-Fi",
                                     note: "今より良くなるとは限りません")
                        ForEach(others) { c in
                            CandidateRow(c: c, busy: app.busy != nil) { app.switchTo(c) }
                        }
                    }

                    Text("一覧は直近10分間に見えたWi-Fiを合算しています。電波は常に揺れるため、切り替えても改善しないことがあります。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let b = app.busy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(b).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if let f = app.flash {
                        Text(f).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 400)
        }
    }
}

private struct SectionLabel: View {
    let title: String
    let note: String
    init(_ t: String, note: String) { title = t; self.note = note }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(note).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }
}

private struct CandidateRow: View {
    let c: NetworkCandidate
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: { if c.connectable { action() } }) {
            HStack(spacing: 9) {
                Image(systemName: c.connectable ? "wifi" : "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(c.connectable ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.ssid)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(c.connectable
                         ? "\(c.reason) ・ \(c.band)GHz ch\(c.channel)"
                         : "パスワードが必要（メニューバーのWi-Fiから接続）")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Phrase.signalWord(c.rssi))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("\(c.rssi) dBm")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                if c.connectable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            .opacity(c.connectable ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(busy || !c.connectable)
    }
}

/// 「ビデオ会議: 安定して使えます」のような、行動に直結する目安。
struct CapabilityChip: View {
    let c: Capability

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: c.icon)
                .font(.system(size: 11))
                .foregroundStyle(c.level.textTint)
            VStack(alignment: .leading, spacing: 0) {
                Text(c.name)
                    .font(.system(size: 10, weight: .semibold))
                Text(c.note)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(height: 22, alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(c.level.tint.opacity(0.13)))
        .help("\(c.name)：\(c.note)\n根拠 \(c.basis)")
    }
}

private struct FooterLink: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(title).font(.system(size: 12))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// MARK: - 詳細 / 設定

struct SubPage<Content: View>: View {
    let title: String
    let back: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: back) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("戻る").font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                Spacer()
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
            content
        }
        .frame(width: PanelMetrics.width)
    }
}

/// 詳細系のページで共通に使う行。
/// ページごとに作りを変えると、同じ「詳細」なのに見え方が違って読み替えが要る。
/// 見出し・行・区切りをここに集約して、構造を必ず揃える。
struct InfoRow: View {
    let label: String
    let value: String
    var note: String?
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(warn ? Level.fair.textTint : Color.primary)
                    .multilineTextAlignment(.trailing)
            }
            if let note {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

struct InfoHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoLink: View {
    let title: String
    var icon: String = "chevron.right"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11.5))
                Spacer()
                Image(systemName: icon).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}

struct DetailView: View {
    @ObservedObject var app: AppState

    var body: some View {
        SubPage(title: "詳細", back: { app.page = .home }) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(app.snap.details) { row in
                    InfoRow(label: row.label, value: row.value, note: row.note, warn: row.warn)
                    Divider().opacity(0.4)
                }

                InfoLink(title: app.snap.apNamed
                         ? "この機器の呼び名を変える" : "この機器に呼び名を付ける") {
                    app.reloadNamedAPs(); app.page = .naming
                }
                Divider().opacity(0.4)

                // この回線で何ができるか
                VStack(alignment: .leading, spacing: 6) {
                    Text("この回線でできること")
                        .font(.system(size: 11.5, weight: .semibold))
                    ForEach(app.snap.capabilities) { c in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 7) {
                                Image(systemName: c.icon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(c.level.tint)
                                    .frame(width: 16)
                                Text(c.name)
                                    .font(.system(size: 11))
                                Spacer()
                                Text(c.note)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(c.needsSpeedTest ? .tertiary : .secondary)
                            }
                            Text(c.basis)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 23)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)

                Divider().padding(.top, 10)

                VStack(spacing: 7) {
                    Button(action: { app.exportReport() }) {
                        Label("レポートを書き出す", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity)
                    }
                    Text("情シスに相談するときは、このレポートを添えると原因が伝わります")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppState
    var openLogFolder: () -> Void
    var quit: () -> Void

    var body: some View {
        SubPage(title: "設定", back: { app.page = .home }) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("調子が悪くなったら通知する", isOn: $app.notifyOn)
                Toggle("ログイン時に自動で起動する", isOn: $app.loginOn)
                if !app.loginStatus.isEmpty && app.loginStatus != "有効" && app.loginOn {
                    Text(app.loginStatus)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Level.fair.textTint)
                }
                Toggle("⌥⌘W で呼び出す", isOn: $app.hotKeyOn)
                Text("入れると、他のアプリの ⌥⌘W（すべてのウインドウを閉じる）が効かなくなります")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("メニューバーの表示を最小にする", isOn: $app.compactBar)
                Text("メニューバーが混雑していてアイコンが隠れるときに使ってください")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Button(action: openLogFolder) {
                    Label("記録フォルダを開く", systemImage: "folder")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                }
                Button(action: quit) {
                    Label("WiFiDoctor を終了", systemImage: "power")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
            .padding(16)
        }
    }
}

/// スピードテスト。回線を占有する独立した機能なので、専用画面に切り出す。
struct SpeedTestView: View {
    @ObservedObject var app: AppState

    var body: some View {
        SubPage(title: "スピードテスト", back: { app.page = .home }) {
            VStack(alignment: .leading, spacing: 12) {

                Text("回線を約20秒間全力で使い、実際に出る速度を測ります。常時は測りません。測定そのものが帯域を食って、かえって遅くなるためです。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let r = app.speed, r.ok {
                    HStack(spacing: 8) {
                        SpeedCard(icon: "arrow.down", label: "下り（受信）", mbps: r.downMbps,
                                  word: r.downMbps.map(Phrase.downWord))
                        SpeedCard(icon: "arrow.up", label: "上り（送信）", mbps: r.upMbps,
                                  word: r.upMbps.map(Phrase.upWord))
                    }
                    if let rpm = r.rpm {
                        HStack {
                            Image(systemName: "gauge.medium")
                                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                            Text("混雑時の詰まりにくさ").font(.system(size: 11))
                            Spacer()
                            Text(String(format: "%.0f RPM", rpm))
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    if let at = app.speedAt {
                        Text(DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .short)
                             + " 時点の測定結果")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }

                Button(action: { app.runSpeedTest() }) {
                    HStack(spacing: 7) {
                        if app.busy != nil {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "speedometer")
                        }
                        Text(app.busy ?? (app.speed == nil ? "測定を開始" : "もう一度測る"))
                    }
                }
                .buttonStyle(BigButtonStyle(tint: .accentColor, enabled: app.busy == nil))
                .disabled(app.busy != nil)

                Text("測定中は通信が重くなります。会議中や大きな転送中は避けてください。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let f = app.flash {
                    Text(f).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !app.speedHistory.isEmpty {
                    Divider()
                    Text("これまでの測定")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(app.speedHistory) { h in
                        HStack(spacing: 6) {
                            Text(DateFormatter.localizedString(from: h.at,
                                                               dateStyle: .short, timeStyle: .short))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Text(h.ssid.isEmpty ? "-" : h.ssid)
                                .font(.system(size: 9.5))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(String(format: "↓%.0f ↑%.0f Mbps", max(0, h.down), max(0, h.up)))
                                .font(.system(size: 9.5, weight: .medium))
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

private struct SpeedCard: View {
    let icon: String
    let label: String
    let mbps: Double?
    let word: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tint)
                Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(mbps.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Mbps").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(word ?? "-")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.055)))
    }
}

/// APの呼び名を付ける画面。
/// `B14170` のままでは会議室と結びつかず、履歴もレポートも人間に読めない。
struct NamingView: View {
    @ObservedObject var app: AppState

    var body: some View {
        SubPage(title: "APの呼び名", back: { app.page = .home }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("いま接続している機器")
                            .font(.system(size: 11.5, weight: .semibold))
                        if let full = app.snap.apFull {
                            HStack(spacing: 6) {
                                TextField("例: 3F会議室A", text: $app.apNameDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                                    .onSubmit { app.commitAPName() }
                                Button("保存") { app.commitAPName() }
                                    .font(.system(size: 11))
                            }
                            Text("\(app.snap.network ?? "-") ・ \(full)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(app.snap.locationDenied
                                 ? "位置情報の許可が無いため、どのAPかを識別できません"
                                 : "接続していないため名前を付けられません")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("会議室ごとに名前を付けておくと、履歴グラフのAP切替や情シスへ渡す"
                         + "レポートに場所がそのまま出ます。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !app.namedAPs.isEmpty {
                        Divider()
                        Text("付けた名前（\(app.namedAPs.count)）")
                            .font(.system(size: 11, weight: .semibold))
                        ForEach(app.namedAPs, id: \.bssid) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.bssid == app.snap.apFull
                                      ? "wifi" : "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 10))
                                    .foregroundStyle(item.bssid == app.snap.apFull
                                                     ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Text(item.bssid)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Button(action: { app.removeAPName(item.bssid) }) {
                                    Image(systemName: "trash").font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("この名前を削除")
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(Color.primary.opacity(0.05)))
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 420)
        }
    }
}

/// このMacの負荷。
/// 「詳細」と同じ行構造にそろえている。同じ性格の画面で作りが違うと、
/// 読むたびに見方を切り替えることになる。
struct MacView: View {
    @ObservedObject var app: AppState

    var body: some View {
        let l = app.load
        return SubPage(title: "このMac", back: { app.page = .home }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    InfoRow(label: "CPU",
                            value: String(format: "%.0f%%", l.cpuPercent),
                            note: String(format: "実行待ち コアあたり %.1f。"
                                         + "実行待ちはメモリ待ちでも上がるため、CPUの判断には使いません",
                                         l.loadPerCore),
                            warn: l.cpuBusy)
                    Divider().opacity(0.4)

                    InfoRow(label: "メモリ",
                            value: l.memoryWord,
                            note: String(format: "空き %.0fMB / 圧縮 %.0fMB / スワップ %.1fGB",
                                         l.freeMemoryMB, l.compressedMB, l.swapUsedMB / 1024),
                            warn: l.memoryTight)
                    Divider().opacity(0.4)

                    if l.swapInMBps >= 0.5 || l.swapOutMBps >= 0.5 {
                        InfoRow(label: "スワップの出入り",
                                value: String(format: "読み %.0f / 書き %.0f MB秒",
                                              l.swapInMBps, l.swapOutMBps),
                                note: "書き出しが続いているときだけメモリの取り合いが起きています",
                                warn: l.swapOutMBps >= 1)
                        Divider().opacity(0.4)
                    }

                    InfoRow(label: "このMacの通信量",
                            value: String(format: "%.1f Mbps", app.ownMbps),
                            note: "自分が流している量。多いと回線が詰まります",
                            warn: app.ownMbps >= 8)
                    Divider().opacity(0.4)

                    // 改善案。状態を知っても手が分からなければ意味がない。
                    let tips = app.macSuggestions
                    if !tips.isEmpty {
                        InfoHeader(text: "改善するには")
                        ForEach(Array(tips.enumerated()), id: \.offset) { _, t in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tint)
                                    .padding(.top, 1)
                                Text(t)
                                    .font(.system(size: 11))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                        Divider().opacity(0.4).padding(.top, 6)
                    } else {
                        InfoRow(label: "総合",
                                value: "余裕あり",
                                note: "回線が遅く感じる場合、原因はMac側ではありません")
                        Divider().opacity(0.4)
                    }

                    if !app.topTalkers.isEmpty {
                        InfoHeader(text: "通信しているアプリ")
                        ForEach(Array(app.topTalkers.enumerated()), id: \.offset) { _, t in
                            InfoRow(label: t.name, value: String(format: "%.0f Mbps", t.mbps))
                        }
                        Divider().opacity(0.4)
                    }

                    InfoHeader(text: "CPUを使っているアプリ")
                    if l.topCPU.isEmpty {
                        InfoRow(label: "計測中です", value: "")
                    } else {
                        ForEach(l.topCPU) { p in
                            InfoRow(label: p.name, value: String(format: "%.0f%%", p.cpu))
                        }
                    }
                    Divider().opacity(0.4)

                    InfoHeader(text: "メモリを使っているアプリ")
                    if l.topMemory.isEmpty {
                        InfoRow(label: "計測中です", value: "")
                    } else {
                        ForEach(l.topMemory) { p in
                            InfoRow(label: p.name,
                                    value: p.memMB >= 1024
                                        ? String(format: "%.1f GB", p.memMB / 1024)
                                        : String(format: "%.0f MB", p.memMB))
                        }
                    }
                    Divider().opacity(0.4)

                    Text("スワップの使用量が多くても、それだけでは問題ではありません。"
                         + "macOSは空きメモリを遊ばせず、圧縮とスワップを積極的に使う設計です。"
                         + "実際に効くのはメモリ圧のレベルと、スワップへの書き出しが続いているか"
                         + "どうかです。ヘルパープロセスは親アプリにまとめて数えています。")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
            .frame(maxHeight: 440)
        }
    }
}

// MARK: - ルート

struct RootView: View {
    @ObservedObject var app: AppState
    var openHistory: () -> Void
    var openLogFolder: () -> Void
    var quit: () -> Void

    var body: some View {
        Group {
            switch app.page {
            case .home:     HomeView(app: app)
            case .detail:   DetailView(app: app)
            case .settings: SettingsView(app: app, openLogFolder: openLogFolder, quit: quit)
            case .switching: SwitchingView(app: app)
            case .speedtest: SpeedTestView(app: app)
            case .naming:    NamingView(app: app)
            case .mac:       MacView(app: app)
            }
        }
        // 既定の半透明マテリアルだと壁紙が透けて文字が読めなくなるので不透明にする
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
