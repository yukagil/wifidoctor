// アプリアイコンを描いて Resources/WiFiDoctor.icns を作る。
//
//   swift Tools/make_icon.swift            # リポジトリ直下で実行
//
// 画像を手で描くとやり直しがきかないので、コードで持つ。
// 絵柄: 電波の弧を、脈を測る波形が横切る。「Wi-Fiを診ている」ことを1枚で出す。
import AppKit

/// 16/32px では弧を3本描くと潰れて灰色の塊になる。
/// 小さいときは弧を1本に減らし、線を太くし、波形は捨てる。
func draw(_ size: CGFloat, small: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size
    NSGraphicsContext.current?.imageInterpolation = .high

    // 地。斜めのグラデーションにして、白い背景でも暗い背景でも沈まないようにする
    let r = NSRect(x: s * 0.095, y: s * 0.11, width: s * 0.81, height: s * 0.81)
    let bg = NSGradient(colors: [
        NSColor(srgbRed: 0.35, green: 0.30, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.62, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.80, blue: 0.72, alpha: 1)])
    bg?.draw(in: NSBezierPath(roundedRect: r, xRadius: s * 0.22, yRadius: s * 0.22), angle: -55)

    let cx = r.midX
    let cy = r.minY + r.height * 0.255

    // 電波の弧。外側ほど薄くして、広がっていく感じを出す
    let radii: [CGFloat] = small ? [0.30] : [0.145, 0.245, 0.345]
    for (i, rad) in radii.enumerated() {
        let p = NSBezierPath()
        p.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: r.width * rad,
                    startAngle: 32, endAngle: 148)
        p.lineWidth = r.width * (small ? 0.15 : 0.075)
        p.lineCapStyle = .round
        NSColor.white.withAlphaComponent(small ? 1 : [1.0, 0.92, 0.78][i]).setStroke()
        p.stroke()
    }
    // 発信点
    NSColor.white.setFill()
    let dot = r.width * (small ? 0.10 : 0.052)
    NSBezierPath(ovalIn: NSRect(x: cx - dot, y: cy - dot, width: dot * 2, height: dot * 2)).fill()

    // 脈の波形。弧の上を横切らせて「測っている」ことを出す
    if !small {
        let y0 = r.minY + r.height * 0.755
        let w = r.width
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + w * 0.10, y: y0))
        p.line(to: NSPoint(x: r.minX + w * 0.34, y: y0))
        p.line(to: NSPoint(x: r.minX + w * 0.41, y: y0 + w * 0.135))
        p.line(to: NSPoint(x: r.minX + w * 0.50, y: y0 - w * 0.105))
        p.line(to: NSPoint(x: r.minX + w * 0.58, y: y0))
        p.line(to: NSPoint(x: r.maxX - w * 0.10, y: y0))
        p.lineWidth = w * 0.062
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        NSColor(srgbRed: 1.0, green: 0.85, blue: 0.30, alpha: 1).setStroke()
        p.stroke()
    }
    img.unlockFocus()
    return img
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let set = root.appendingPathComponent("build/WiFiDoctor.iconset")
try? fm.removeItem(at: set)
try fm.createDirectory(at: set, withIntermediateDirectories: true)

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                   ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let img = draw(CGFloat(px), small: px <= 32)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!
        .write(to: set.appendingPathComponent("\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/WiFiDoctor.icns").path]
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fputs("iconutil に失敗した\n", stderr); exit(1) }
print("==> Resources/WiFiDoctor.icns を書き出した")
