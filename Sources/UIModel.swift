import Foundation
import SwiftUI
import AppKit

// MARK: - 表示用スナップショット

/// 画面に出す4段階。数値(0-100)は専門的すぎるので、前面ではこの段階だけを使う。
enum Level {
    case good, fair, bad, offline

    /// 塗り・アイコン用の色。
    var tint: Color {
        switch self {
        case .good: return Level.adaptive(.systemGreen)
        case .fair: return Level.adaptive(.systemOrange)
        case .bad: return Level.adaptive(.systemRed)
        case .offline: return .secondary
        }
    }

    /// 文字用の色。systemGreen/Orange はライトモードの白背景だと明るすぎて読めないので、
    /// ライトのときだけ暗く寄せる。ダークモードでは明るいままにする。
    var textTint: Color {
        switch self {
        case .good: return Level.adaptive(.systemGreen, darken: 0.34)
        case .fair: return Level.adaptive(.systemOrange, darken: 0.34)
        case .bad: return Level.adaptive(.systemRed, darken: 0.22)
        case .offline: return .secondary
        }
    }

    private static func adaptive(_ base: NSColor, darken: CGFloat = 0.10) -> Color {
        Color(nsColor: Level.adaptiveNS(base, darken: darken))
    }

    /// AppKit 側でも同じ色を使えるようにする。履歴ウインドウは手描きなので、
    /// ここを通さないと白背景に明るい橙や緑をそのまま置くことになり、
    /// コントラストが 2:1 前後まで落ちて本文として読めなくなる。
    static func adaptiveNS(_ base: NSColor, darken: CGFloat = 0.10) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if isDark { return base }
            return base.blended(withFraction: darken, of: .black) ?? base
        }
    }

    /// 文字に使う色（AppKit）。SwiftUI の `textTint` と同じ濃さにする。
    var nsTextTint: NSColor {
        switch self {
        case .good: return Level.adaptiveNS(.systemGreen, darken: 0.34)
        case .fair: return Level.adaptiveNS(.systemOrange, darken: 0.34)
        case .bad: return Level.adaptiveNS(.systemRed, darken: 0.22)
        case .offline: return .secondaryLabelColor
        }
    }
    /// 測定中は「まだ分からない」であって「切れている」ではない。
    /// 起動直後に斜線入りのWi-Fiが出ると、繋がっているのに壊れて見える。
    static func symbol(for level: Level, measuring: Bool) -> String {
        measuring ? "wifi" : level.symbol
    }

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .fair: return "exclamationmark.circle.fill"
        case .bad: return "exclamationmark.triangle.fill"
        case .offline: return "wifi.slash"
        }
    }
}

/// 「この回線で実際に何ができるか」。数値の目安が分からない人向けの翻訳層。
struct Capability: Identifiable {
    // 2秒ごとに作り直されるので、UUID だと SwiftUI が毎回捨てて作り直す。
    // 中身が同じなら同じ id になるようにする。
    var id: String { "\(icon)/\(name)" }
    var icon: String
    var name: String
    var level: Level
    var note: String
    var basis: String = ""            // 何を根拠にこう言っているか
    var needsSpeedTest: Bool = false
}

/// 過去のスピードテスト1件。
struct SpeedRecord: Identifiable {
    var id: Date { at }
    var at: Date
    var down: Double
    var up: Double
    var ssid: String
}

/// 乗り換え候補のWi-Fi。
struct NetworkCandidate: Identifiable {
    var id: String { ssid }
    var ssid: String
    var rssi: Int
    var band: Int
    var channel: Int
    var crowding: Int
    var reason: String
    var recommended: Bool   // 今より良くなりそうか
    var connectable: Bool   // 既知 or オープン＝ワンタップで繋げるか
}

/// 主ボタンが何をするか。原因によって「効く手」が違うので、ボタン自体を差し替える。
enum PrimaryAction: CaseIterable {
    case reconnect        // 遠いAPを掴んでいる → 掴み直す
    case switchNetwork    // 混雑 → 別の回線へ逃がす
    case report           // 自分では直せない → 情シスへ渡す材料を作る
    case none             // 正常 → 押させるものが無い

    var title: String {
        switch self {
        case .reconnect:     return "つなぎ直す"
        case .switchNetwork: return "別のWi-Fiに切り替える"
        case .report:        return "レポートを書き出す"
        case .none:          return ""
        }
    }
    var icon: String {
        switch self {
        case .reconnect:     return "arrow.triangle.2.circlepath"
        case .switchNetwork: return "arrow.left.arrow.right"
        case .report:        return "square.and.arrow.up"
        case .none:          return ""
        }
    }
    var caption: String {
        switch self {
        case .reconnect:     return "数秒だけ通信が切れます。会議中は注意してください"
        case .switchNetwork: return "混雑はつなぎ直しでは直りません。空いている回線へ移ります"
        case .report:        return "パソコン側の問題ではありません。情シスへ渡す材料を作ります"
        case .none:          return ""
        }
    }
}

/// 経路図の1点（パソコン / Wi-Fi機器 / インターネット）。
struct PathNode: Identifiable {
    var id: String { title }
    var icon: String
    var title: String
    var caption: String?
    var level: Level
}

/// 経路図の1区間。ここが「どこで詰まっているか」を絵で示す本体。
struct PathSegment: Identifiable {
    var id: String { "\(word)/\(value)" }
    var word: String        // 「速い」「やや遅い」など
    var value: String       // 「7 ミリ秒」
    var level: Level
    var culprit: Bool       // ここが原因、と名指しする区間
}

/// 画面が必要とする情報だけを、専門用語を落とした形で持つ。
struct Snapshot {
    var nodes: [PathNode] = []
    var segments: [PathSegment] = []
    var level: Level = .offline
    var score: Int = 0
    var headline: String = "確認中…"
    var subline: String = ""
    var hint: String?              // 次に取るべき行動（1文）
    var network: String?           // SSID
    var apShort: String?           // 表示名（付けていなければ短縮ID）
    var apNamed = false            // 利用者が名前を付けているか
    var apFull: String?
    var apSince: Date?             // このAPを掴んでからの起点
    var capabilities: [Capability] = []
    var primary: PrimaryAction = .none
    var candidates: [NetworkCandidate] = []
    /// この場所で使える物理APの台数。1台なら混雑は構造的で、切替では直らない。
    var usableAPs: Int = 0
    var vpn: String?
    /// 位置情報を断られている。SSID/BSSID が読めず、場所の機能が全部死ぬ。
    var locationDenied = false
    /// まだ一度も測れていない。「切れている」とは違う。
    var measuring = false
    /// スキャンはできるのに、どのWi-Fiかの名前が取れない。
    /// 署名に wifi-info の権限が無いとこうなる。切替候補が構造的に空になる。
    var scanNamesUnavailable = false
    /// このMacの状態を1行で。切り分けの片側なので常時見えている必要がある。
    var macLine: String = ""
    var macWarn = false
    var details: [DetailRow] = []

    static let placeholder = Snapshot()
}

struct DetailRow: Identifiable {
    var id: String { label }
    var label: String
    var value: String
    var note: String?              // 平易な補足
    var warn: Bool = false
}

// MARK: - 技術値 → 平易な日本語

enum Phrase {

    /// 記録をまとめたときの良し悪し。
    ///
    /// 点数だけで決めると、判定が「問題あり」だった時間が長くても
    /// 「快適」と名乗ってしまう（点数と判定は別のしきい値で動いている）。
    /// その瞬間の判定を使う `level(score:verdict:)` と辻褄が合うように、
    /// 崩れていた時間の割合も効かせる。
    static func level(score: Int, badRatio: Double) -> Level {
        if score >= 80 && badRatio < 0.25 { return .good }
        if score >= 60 { return .fair }
        return .bad
    }

    static func level(score: Int, verdict: Verdict) -> Level {
        if verdict == .offline { return .offline }
        if verdict == .measuring { return .offline }   // 数値を出さず「--」にする
        if verdict == .macBusy { return .fair }        // 回線ではなくMac側の注意
        if verdict == .noInternet { return .bad }
        if verdict == .ok && score >= 80 { return .good }
        return score >= 60 ? .fair : .bad
    }

    /// 切り替え画面で候補が無いときの言い分け。
    /// 「見つからない」「名前が読めない」「許可が無い」は別のことで、
    /// 取り違えると事実と違うことを言う。
    static func noCandidates(locationDenied: Bool,
                             namesUnavailable: Bool) -> (title: String, body: String) {
        if locationDenied {
            return ("位置情報の許可が無いため、近くのWi-Fiを調べられません", "")
        }
        if namesUnavailable {
            return ("近くのWi-Fiは見えていますが、名前が読めません",
                    "このアプリの署名では、周りのWi-Fiの名前を取得できません。手動での切り替えをお使いください。")
        }
        return ("切り替えられる回線が見つかりません",
                "iPhoneのテザリング、または有線接続がもっとも確実です。席を移すのも有効です。")
    }

    /// 呼び名を付けられないときの理由。接続中に「接続していない」と言わない。
    static func cannotName(locationDenied: Bool) -> String {
        locationDenied ? "位置情報の許可が無いため、どのAPかを識別できません"
                       : "接続していないため名前を付けられません"
    }

    /// 通知の本文。
    ///
    /// 通知は「自分で直せる状態」のときだけ出る。画面用の `hint` は
    /// ポップオーバーのボタンが見えている前提の文なので、単独で届くと噛み合わない
    /// （空いている回線がある時にだけ届く通知が「無ければ席を移せ」と言う）。
    static func notice(_ v: Verdict) -> String {
        switch v {
        case .sticky:      return "近くに強いWi-Fiがあります。［つなぎ直す］で切り替わります"
        case .congested:   return "空いている別のWi-Fiがあります。［別のWi-Fiに切り替える］で移れます"
        case .weak:        return "Wi-Fi機器から遠すぎます。近づくのがいちばん効きます"
        case .selfTraffic: return "このMac自身の通信で埋まっています。転送を止めると戻ります"
        default:           return hint(v) ?? ""
        }
    }

    /// 「何が起きているか」を専門用語なしで言い切る。
    static func headline(_ v: Verdict) -> String {
        switch v {
        case .ok:        return "快適につながっています"
        case .congested: return "Wi-Fiが混み合っています"
        case .sticky:    return "遠いWi-Fiにつながったままです"
        case .weak:      return "電波が弱い場所です"
        case .isp:       return "インターネット側が不安定です"
        case .dns:       return "サイトの表示が遅くなっています"
        case .selfTraffic: return "このMacが回線を使っています"
        case .macBusy:   return "Macが重くなっています"
        case .measuring: return "接続を確認しています"
        case .noInternet: return "インターネットに出られません"
        case .offline:   return "Wi-Fiにつながっていません"
        }
    }

    /// 正常時のリード文。固定文にすると「できること」判定と食い違うので、
    /// 必ず同じ判定結果から組み立てる。
    /// 正常時のリード文。
    /// 「ビデオ会議」「画面共有」の可否はチップ側が担当しているので、
    /// ここで同じことを言うと画面上に同じ情報が二度出る。状態そのものを述べる。
    static func okSubline(_ caps: [Capability]) -> String {
        let meeting = caps.first { $0.name == "ビデオ会議" }?.level ?? .good
        let share   = caps.first { $0.name == "画面共有" }?.level ?? .good
        switch (meeting, share) {
        case (.good, .good): return "遅延もゆらぎも小さく、安定しています"
        case (.good, _):     return "おおむね安定していますが、少しゆらぎがあります"
        default:             return "つながっていますが、やや不安定です"
        }
    }

    /// 「それが自分にとってどういう意味か」。原因の説明ではなく体感で書く。
    static func subline(_ v: Verdict) -> String {
        switch v {
        case .ok:        return "遅延もゆらぎも小さく、安定しています"
        case .congested: return "同じ電波を大勢が使っていて、順番待ちが起きています"
        case .sticky:    return "移動する前の場所のWi-Fiにつながり続けています"
        case .weak:      return "Wi-Fiの機器から遠く、電波が届きにくくなっています"
        case .isp:       return "Wi-Fi機器までは正常です。その先で遅延が出ています"
        case .dns:       return "つながってはいますが、ページの表示が遅くなります"
        case .selfTraffic: return "大きな転送や同期が回線を占有しています"
        case .macBusy:   return "回線は正常です。Mac側の負荷で遅く感じています"
        case .measuring: return "つながったばかりです。数秒で分かります"
        case .noInternet: return "Wi-Fiにはつながっていますが、外に出られていません"
        case .offline:   return "Wi-Fiがオフになっているか、接続に失敗しています"
        }
    }

    /// 次にやること。ボタンで解決できないときだけ出す。
    /// 逃げ場が無い場所では、切替や掴み直しを勧めても意味がない。
    /// 「直らない理由」を伝えるほうが役に立つ。
    /// 状況によってリード文を差し替える。
    /// 別枠のヒントを出すと画面が重くなるので、説明はリード文1か所に集約する。
    static func sublineForPlace(_ v: Verdict, usableAPs: Int, vpn: String?,
                                caps: [Capability]) -> String {
        // 0台は「1台しかない」ではなく「まだ数えていない」。
        // スキャン前に構造的な混雑だと言い切ると、後で覆る。
        if v == .congested, usableAPs == 1 {
            return "この場所はWi-Fi機器1台のみ。混雑は構造的で、つなぎ直しでは解消しません"
        }
        // VPN 中に経路をWi-Fi側へ限定できていないと、「自分→Wi-Fi機器」の値に
        // トンネルの往復が乗る。混雑の誤判定になるので、断定しない。
        if v == .congested, vpn != nil, !NetProbe.gatewayScoped {
            return "VPN経由のため、この値にはVPNの往復も含まれます。混雑とは限りません"
        }
        if (v == .isp || v == .dns), vpn != nil {
            return "VPN経由のため、この遅延にはVPNの往復も含まれます"
        }
        return v == .ok ? okSubline(caps) : subline(v)
    }

    static func hint(_ v: Verdict) -> String? {
        switch v {
        case .ok:        return nil
        case .congested: return "空いている回線がなければ、席を移すか有線・テザリングが確実です"
        case .sticky:    return "［つなぎ直す］で近くの強いWi-Fiに切り替わります"
        case .weak:      return "Wi-Fi機器に近い席へ移動してみてください"
        case .isp:       return "パソコン側でできることはありません。続くようなら［詳細］からレポートを書き出して情シスへ渡してください"
        case .dns:       return "続くようなら情シスに相談してください"
        case .selfTraffic: return "転送や同期が終わるまで待つか、一時停止してください"
        case .macBusy:   return "重いアプリを閉じると改善することがあります"
        case .measuring: return nil
        case .noInternet: return "サインインが必要なWi-Fiかもしれません。ブラウザで任意のページを開いてみてください"
        case .offline:   return "メニューバーからWi-Fiをオンにしてください"
        }
    }

    /// 原因ごとに「実際に効く手」を主ボタンに割り当てる。
    /// 混雑につなぎ直しを勧めると同じ混んだAPに戻るだけなので、そこは切替へ回す。
    static func primary(for v: Verdict, hasAlternatives: Bool) -> PrimaryAction {
        switch v {
        case .ok:                   return .none
        case .sticky, .weak:        return .reconnect
        case .offline:              return .reconnect
        case .congested:            return hasAlternatives ? .switchNetwork : .reconnect
        // 回線側の問題は自分では直せない。大きなボタンで何かを促すのは誤り。
        // レポート書き出しは詳細画面に小さく置いてある。
        case .isp, .dns:            return .none
        case .noInternet:           return .reconnect
        case .selfTraffic:          return .none
        case .macBusy:              return .none
        case .measuring:            return .none
        }
    }

    /// 遅延をミリ秒ではなく体感で言い換える。
    static func latencyWord(_ ms: Double?) -> String {
        guard let ms else { return "測定中" }
        switch ms {
        case ..<5:   return "とても速い"
        case ..<12:  return "速い"
        case ..<25:  return "やや遅い"
        case ..<50:  return "遅い"
        default:     return "とても遅い"
        }
    }

    /// その区間を「ここが原因」と名指ししてよいか。
    /// 判定と対応する区間であること、かつその区間自体が悪く見えていることの両方が要る。
    /// 緑で「速い」と出ている区間に原因ラベルを出すのは、単なる誤りになる。
    static func isCulprit(verdict: Verdict, hop: Int, level: Level) -> Bool {
        guard level != .good, level != .offline else { return false }
        switch hop {
        case 0: return [.congested, .sticky, .weak].contains(verdict)
        case 1: return [.isp, .dns, .noInternet].contains(verdict)
        default: return false
        }
    }

    /// 区間に出す語。色（level）と同じ根拠から導くことで、
    /// 「速い のにオレンジ」のような食い違いを構造的に起こせなくする。
    static func segWord(level: Level, ms: Double?, jitter: Double?, loss: Double?,
                        fairMS: Double) -> String {
        switch level {
        case .offline: return "-"
        case .good:
            guard let ms else { return "測定中" }
            return ms < fairMS / 2 ? "とても速い" : "速い"
        case .fair, .bad:
            // 色が悪い理由をそのまま語にする
            if (loss ?? 0) > 1 { return level == .bad ? "よく落ちる" : "たまに落ちる" }
            if (jitter ?? 0) > 6 { return level == .bad ? "ゆらぎ大" : "ゆらぎあり" }
            return level == .bad ? "遅い" : "やや遅い"
        }
    }

    /// 区間の健全度。しきい値は判定ロジック(Scorer)と揃えてある。
    static func segLevel(ms: Double?, jitter: Double?, loss: Double?,
                         badMS: Double, fairMS: Double) -> Level {
        guard let ms else { return .fair }
        if (loss ?? 0) > 5 || ms > badMS || (jitter ?? 0) > 15 { return .bad }
        if (loss ?? 0) > 1 || ms > fairMS || (jitter ?? 0) > 6 { return .fair }
        return .good
    }

    // MARK: - 「何ができるか」への翻訳

    /// 会議の品質を決めるのは平均速度ではなく、遅延・ゆらぎ・損失。
    /// なのでスピードテスト無しでも常時判定できる。
    static func meetingLevel(rtt: Double?, jitter: Double?, loss: Double?) -> Level {
        guard let rtt else { return .offline }
        let l = loss ?? 0
        let j = jitter ?? 0
        if l > 3 || j > 40 || rtt > 200 { return .bad }
        if l > 1 || j > 20 || rtt > 100 { return .fair }
        return .good
    }

    static func capabilities(rtt: Double?, jitter: Double?, loss: Double?,
                             down: Double?, up: Double?,
                             peakRx: Double? = nil, peakTx: Double? = nil,
                             bloat: Double? = nil) -> [Capability] {
        var out: [Capability] = []

        func fmt(_ v: Double?, _ unit: String) -> String {
            guard let v else { return "測定中" }
            return String(format: "%.0f%@", v, unit)
        }
        let basisLine = "遅延 \(fmt(rtt, "ms")) / ゆらぎ \(fmt(jitter, "ms")) / 損失 \(fmt(loss, "%"))"

        // --- 安定性で決まるもの（常時計測できる）---
        var m = meetingLevel(rtt: rtt, jitter: jitter, loss: loss)
        var mBasis = basisLine

        // バッファブロート: 回線が空いているときは綺麗でも、誰かが大きな転送を始めた
        // 途端に遅延が跳ねる回線がある。アイドル時のpingだけ見ていると見逃すので、
        // 実際に通信が流れている時間帯のRTTと比較して検出する。
        if let b = bloat, b > 25 {
            m = b > 80 ? .bad : (m == .good ? .fair : m)
            mBasis += String(format: " / 混雑時に +%.0fms 悪化", b)
        }
        // 帯域が判明していて、かつ会議に足りない場合は安定性が良くても降格させる。
        // pingは通るのに映像が出ない、という穴を塞ぐため。
        if let d = down, let u = up, d < 2 || u < 1 {
            m = .bad
            mBasis = basisLine + " / 帯域不足（下り \(fmt(d, "Mbps")) 上り \(fmt(u, "Mbps"))）"
        }
        out.append(Capability(
            icon: "video.fill", name: "ビデオ会議",
            level: m,
            note: {
                switch m {
                case .good: return "安定して使えます"
                case .fair: return "たまに音声や映像が乱れます"
                case .bad:  return "途切れやすい状態です"
                case .offline: return "計測中"
                }
            }(),
            basis: mBasis + (down == nil ? "（帯域は未測定）" : "")))

        var shareLevel: Level = {
            guard let rtt else { return .offline }
            let l = loss ?? 0, j = jitter ?? 0
            if l > 2 || j > 25 || rtt > 150 { return .bad }
            if l > 0.5 || j > 12 || rtt > 80 { return .fair }
            return .good
        }()
        var sBasis = basisLine
        if let b = bloat, b > 25 {
            shareLevel = b > 60 ? .bad : (shareLevel == .good ? .fair : shareLevel)
            sBasis += String(format: " / 混雑時に +%.0fms 悪化", b)
        }
        if let u = up, u < 2 {
            shareLevel = .bad
            sBasis = basisLine + " / 上りが不足（\(fmt(u, "Mbps"))）"
        }
        out.append(Capability(
            icon: "rectangle.on.rectangle", name: "画面共有",
            level: shareLevel,
            note: {
                switch shareLevel {
                case .good: return "そのまま共有できます"
                case .fair: return "相手側でカクつくことがあります"
                case .bad:  return "共有は避けたほうが無難です"
                case .offline: return "計測中"
                }
            }(),
            basis: sBasis + (up == nil ? "（上り帯域は未測定）" : "")))

        // --- 実測スループットが要るもの ---
        if let d = down {
            let lv: Level = d >= 10 ? .good : (d >= 3 ? .fair : .bad)
            out.append(Capability(
                icon: "play.rectangle.fill", name: "動画視聴",
                level: lv,
                note: d >= 25 ? "4K動画も快適です"
                     : d >= 10 ? "HD動画が快適に見られます"
                     : d >= 5  ? "HD動画は見られます"
                     : d >= 2  ? "画質が落ちることがあります"
                               : "動画には足りません",
                basis: "下り \(fmt(d, "Mbps"))"))
        } else if let p = peakRx, p >= 8 {
            // 実際にこれだけ流れた実績があるということは、帯域は最低でもこれ以上ある。
            // 上限は分からないが「足りている」ことの証明にはなる。
            let lv: Level = p >= 25 ? .good : .fair
            out.append(Capability(
                icon: "play.rectangle.fill", name: "動画視聴",
                level: lv,
                note: p >= 25 ? "HD以上を再生できる実績があります" : "HD動画は見られそうです",
                basis: String(format: "今日 実際に %.0f Mbps 流れた実績あり（上限は未測定）", p)))
        } else {
            out.append(Capability(
                icon: "play.rectangle.fill", name: "動画視聴",
                level: .offline, note: "スピードテストで分かります",
                basis: "大きな通信の実績がまだありません", needsSpeedTest: true))
        }

        if let u = up {
            let lv: Level = u >= 5 ? .good : (u >= 1.5 ? .fair : .bad)
            out.append(Capability(
                icon: "arrow.up.doc.fill", name: "大きなファイルの送信",
                level: lv,
                note: u >= 10 ? "余裕をもって送れます"
                     : u >= 5  ? "問題なく送れます"
                     : u >= 1.5 ? "時間がかかります"
                                : "送信には厳しい速度です",
                basis: "上り \(fmt(u, "Mbps"))"))
        } else if let p = peakTx, p >= 4 {
            let lv: Level = p >= 10 ? .good : .fair
            out.append(Capability(
                icon: "arrow.up.doc.fill", name: "大きなファイルの送信",
                level: lv,
                note: p >= 10 ? "問題なく送れる実績があります" : "送れますが時間がかかります",
                basis: String(format: "今日 実際に %.0f Mbps 送れた実績あり（上限は未測定）", p)))
        } else {
            out.append(Capability(
                icon: "arrow.up.doc.fill", name: "大きなファイルの送信",
                level: .offline, note: "スピードテストで分かります",
                basis: "大きな送信の実績がまだありません", needsSpeedTest: true))
        }

        return out
    }

    /// 速度そのものの言い換え。
    static func downWord(_ mbps: Double) -> String {
        switch mbps {
        case 100...: return "非常に速い"
        case 25...:  return "速い"
        case 10...:  return "十分"
        case 3...:   return "やや遅い"
        default:     return "遅い"
        }
    }

    static func upWord(_ mbps: Double) -> String {
        switch mbps {
        case 30...: return "非常に速い"
        case 10...: return "速い"
        case 3...:  return "十分"
        case 1...:  return "やや遅い"
        default:    return "遅い"
        }
    }

    /// Macの状態を1行にまとめる。
    /// 逼迫しているときは「何が」まで出さないと、利用者は手の打ちようがない。
    static func macLine(load: SystemLoad, ownMbps: Double, topTalker: String?) -> String {
        var parts: [String] = []

        if load.memoryTight {
            parts.append("メモリ" + load.memoryWord)
            if let top = load.topMemory.first {
                parts.append(top.memMB >= 1024
                    ? String(format: "%@ %.1fGB", top.name, top.memMB / 1024)
                    : String(format: "%@ %.0fMB", top.name, top.memMB))
            }
        } else if load.cpuBusy {
            parts.append(String(format: "CPU %.0f%%", load.cpuPercent))
            if let top = load.topCPU.first {
                parts.append(String(format: "%@ %.0f%%", top.name, top.cpu))
            }
        } else {
            parts.append(String(format: "CPU %.0f%%", load.cpuPercent))
            parts.append("メモリ" + load.memoryWord)
        }

        if ownMbps >= 8 {
            parts.append(topTalker.map { String(format: "%@ %.0fMbps", $0, ownMbps) }
                         ?? String(format: "送受信 %.0fMbps", ownMbps))
        }
        return parts.joined(separator: " ・")
    }

    static func durationWord(_ since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        if s < 60 { return "\(s)秒" }
        if s < 3600 { return "\(s / 60)分" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)時間" : "\(h)時間\(m)分"
    }

    static func signalWord(_ dBm: Int) -> String {
        switch dBm {
        case (-60)...:   return "強い"
        case (-68)...:   return "ふつう"
        case (-75)...:   return "弱い"
        default:         return "とても弱い"
        }
    }
}

/// 表示用のバージョン。配った後に「どのビルドか」を聞けるようにしておく。
enum Build {
    static var version: String {
        let d = Bundle.main.infoDictionary
        let v = d?["CFBundleShortVersionString"] as? String ?? "?"
        return "WiFiDoctor \(v)"
    }
}
