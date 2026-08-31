import AppKit

/// メニューバーの猫。調子がそのまま猫の元気さになる。
///
///   快調 → 走る / ふつう → 歩く / 悪い → 座り込む / 切断 → 寝る
///
/// 数字は読まないと分からないが、猫は視界の隅でも分かる。
/// 「今どうなのか」を、目を向けずに受け取れるようにするための絵。
enum CatPose: Int, CaseIterable {
    case run, walk, sit, sleep

    static func of(level: Level, associated: Bool, measuring: Bool) -> CatPose {
        guard associated else { return .sleep }
        if measuring { return .walk }
        switch level {
        case .good: return .run
        case .fair: return .walk
        case .bad: return .sit
        case .offline: return .sleep
        }
    }

    /// ひと駆けの1秒あたりの駒数。元気なほど速い。
    var fps: Double {
        switch self {
        case .run: return 10
        case .walk: return 6
        case .sit: return 2
        case .sleep: return 1.5
        }
    }

    /// ひと駆けで見せる駒数。だいたい1.6〜2秒で止まる。
    ///
    /// 常時動かすと、状態バーの絵の描き直しだけで CPU を 4% ほど使う
    /// （10fps で実測）。このアプリは「Macが忙しい」を見つける道具なので、
    /// 自分が忙しさの原因になってはいけない。測り終えた合図のときだけ走らせる。
    var burst: Int {
        switch self {
        case .run: return 16
        case .walk: return 10
        case .sit: return 4
        case .sleep: return 3
        }
    }

    var spoken: String {
        switch self {
        case .run: return "快調です"
        case .walk: return "ふつうです"
        case .sit: return "調子が悪いです"
        case .sleep: return "つながっていません"
        }
    }
}

enum CatGlyph {
    /// 動いている間に回す駒。
    static let frameCount = 4
    /// 止まっているときの駒。走りの途中で固まると脚が開いたままになるので、
    /// 静止用に脚をそろえた1枚を別に持つ。
    static let restIndex = 4
    /// メニューバーに収まる高さ。22pt の帯に対して、これ以上大きいと窮屈になる。
    static let height: CGFloat = 14

    /// 駒は姿勢ごとに4枚しかない。毎回描き直すと、動かしている間ずっと
    /// ベジェを引き続けることになるので、一度描いたら使い回す。
    private static var cache: [Int: [NSImage]] = [:]
    private static let lock = NSLock()

    static func image(_ frame: Int, _ pose: CatPose) -> NSImage {
        lock.lock(); defer { lock.unlock() }
        let frames: [NSImage]
        if let f = cache[pose.rawValue] { frames = f } else {
            frames = (0...restIndex).map { draw($0, pose, h: height) }
            cache[pose.rawValue] = frames
        }
        return frames[frame == restIndex ? restIndex : frame % frameCount]
    }

    /// 止まっている猫。
    static func still(_ pose: CatPose) -> NSImage { image(restIndex, pose) }

    /// 右を向いた猫。高さ14pt・幅20pt の升目で描き、あとは倍率で伸ばす。
    static func draw(_ frame: Int, _ pose: CatPose, h: CGFloat) -> NSImage {
        let u = h / 14.0
        let rest = frame == restIndex      // 脚をそろえて立つ／落ち着いた姿勢
        let img = NSImage(size: NSSize(width: 20 * u, height: h))
        img.lockFocus()
        NSColor.black.setFill(); NSColor.black.setStroke()
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * u, y: y * u) }
        func stroke(_ path: NSBezierPath, _ w: CGFloat) {
            path.lineWidth = w * u
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        func head(_ cx: CGFloat, _ cy: CGFloat, r: CGFloat = 2.7) {
            NSBezierPath(ovalIn: NSRect(x: cx * u - r * u, y: cy * u - r * u,
                                        width: r * 2 * u, height: r * 2 * u)).fill()
            for dx in [-1.5, 0.5] as [CGFloat] {          // 耳
                let e = NSBezierPath()
                e.move(to: p(cx + dx - 0.5, cy + 1.6))
                e.line(to: p(cx + dx + 0.2, cy + 3.4))
                e.line(to: p(cx + dx + 1.1, cy + 1.4))
                e.close(); e.fill()
            }
        }

        switch pose {
        case .run, .walk:
            let bob: CGFloat = rest ? 0
                : (pose == .run ? [0, 0.9, 0.3, 0.9][frame % 4]
                                : [0, 0.35, 0, 0.35][frame % 4])
            let bodyY = 4.6 + bob
            // 脚。前後で位相をずらすと歩いて見える
            let amp: CGFloat = pose == .run ? 1.6 : 1.0
            let phase: [[CGFloat]] = [[-1, 1, 1, -1], [1, -1, -1, 1],
                                      [-0.5, 0.5, 0.5, -0.5], [0.5, -0.5, -0.5, 0.5]]
            let s = rest ? [0, 0, 0, 0] : phase[frame % 4].map { $0 * amp }
            for (i, x) in ([5.2, 6.4, 11.0, 12.2] as [CGFloat]).enumerated() {
                let leg = NSBezierPath()
                leg.move(to: p(x, bodyY + 0.6))
                leg.line(to: p(x + s[i] * 0.5, bodyY - 1.6))
                leg.line(to: p(x + s[i], 0.8))
                stroke(leg, 1.5)
            }
            // 止まっているときは、しっぽの高さで元気さを出す。
            // 静止の絵が走りと歩きで同じだと、見分けがつくのが数字の色だけになる。
            let lift: CGFloat = rest ? (pose == .run ? 2.6 : 0.5)
                                     : [1.2, 2.2, 1.6, 2.2][frame % 4]
            let tail = NSBezierPath()
            tail.move(to: p(4.6, bodyY + 0.8))
            tail.curve(to: p(0.9, bodyY + lift + 1.4),
                       controlPoint1: p(3.0, bodyY + lift), controlPoint2: p(1.4, bodyY + lift))
            stroke(tail, 1.4)
            NSBezierPath(ovalIn: NSRect(x: 4.2 * u, y: (bodyY - 0.4) * u,
                                        width: 9.4 * u, height: 4.4 * u)).fill()
            let neck = NSBezierPath()
            neck.move(to: p(11.6, bodyY + 1.6)); neck.line(to: p(14.4, bodyY + 2.9))
            stroke(neck, 3.0)
            head(14.4, bodyY + 2.9)

        case .sit:
            // 尻を落として座り、しっぽの先だけ振る
            let tip: CGFloat = rest ? 0 : [0, 0.7, 0, -0.7][frame % 4]
            let tail = NSBezierPath()
            tail.move(to: p(4.4, 2.2))
            tail.curve(to: p(13.4, 1.2 + tip),
                       controlPoint1: p(4.0, 0.6), controlPoint2: p(10.0, 0.4))
            stroke(tail, 1.4)
            let body = NSBezierPath()
            body.move(to: p(4.2, 1.0))
            body.curve(to: p(9.2, 8.2), controlPoint1: p(2.6, 6.0), controlPoint2: p(6.0, 8.4))
            body.curve(to: p(12.6, 3.0), controlPoint1: p(11.6, 8.0), controlPoint2: p(12.6, 6.0))
            body.line(to: p(12.6, 1.0))
            body.close(); body.fill()
            for x in [10.8, 12.2] as [CGFloat] {          // 前脚
                let leg = NSBezierPath()
                leg.move(to: p(x, 4.4)); leg.line(to: p(x + 0.3, 0.9))
                stroke(leg, 1.5)
            }
            head(12.2, 8.6)

        case .sleep:
            // 丸くなって寝る。息で少しふくらむ
            let breathe: CGFloat = rest ? 0.2 : [0, 0.25, 0.4, 0.25][frame % 4]
            NSBezierPath(ovalIn: NSRect(x: 2.6 * u, y: 0.8 * u,
                                        width: 11.0 * u, height: (6.2 + breathe) * u)).fill()
            let tail = NSBezierPath()
            tail.move(to: p(3.4, 2.4))
            tail.curve(to: p(12.4, 1.6), controlPoint1: p(2.0, 0.2), controlPoint2: p(8.0, 0.2))
            stroke(tail, 1.4)
            head(11.4, 4.6 + breathe, r: 2.5)
            for i in 0..<2 {                              // zzz
                let rise: CGFloat = rest ? 0.5 : [0, 0.5, 1.0, 0.5][(frame + i) % 4]
                let sz: CGFloat = i == 0 ? 3.4 : 4.6
                NSAttributedString(string: "z", attributes: [
                    .font: NSFont.systemFont(ofSize: sz * u, weight: .bold),
                    .foregroundColor: NSColor.black])
                    .draw(at: p(14.2 + CGFloat(i) * 1.4, 7.2 + CGFloat(i) * 2.0 + rise))
            }
        }
        img.unlockFocus()
        // テンプレートにしておくと、明るい帯でも暗い帯でも勝手に反転する
        img.isTemplate = true
        img.accessibilityDescription = "Wi-Fi: \(pose.spoken)"
        return img
    }
}
