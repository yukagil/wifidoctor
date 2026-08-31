import Foundation
import CoreWLAN

/// つなぎ直し。手動ボタン専用（自動では走らせない）。
///
/// 速さについて、実測で分かったこと（macOS 26）:
///  - `CWInterface.associate` は -3900 (tmpErr) で拒否される。切断済みでも同じ。
///    `networksetup -setairportnetwork` も同じエラーになる。
///    つまりサードパーティのアプリからAPを指定して張り替えることはできない。
///  - `disassociate()` は0.2秒で切れるが、macOSは意図的な切断とみなして
///    自動再接続しない。切りっぱなしになるので単独では使えない。
///  - 結局、確実なのはWi-Fiの電源を入れ直す方法だけ。
///
/// そこで、通る可能性のある associate は一応試し（失敗しても0.1秒程度）、
/// 駄目なら電源の入れ直しに落とす。待ち時間は詰められるだけ詰めてある。
enum Roamer {

    struct Result {
        var ok: Bool
        var seconds: Double
        var method: String
        var message: String
    }

    /// Wi-Fi を切っている最中であることの目印。
    /// 落ちてもここが残るので、次の起動で入れ直せる。
    private static var markURL: URL { SampleLog.dir.appendingPathComponent("roaming.marker") }

    static func markPowerOff(_ iface: String) {
        try? iface.write(to: markURL, atomically: true, encoding: .utf8)
    }
    static func clearPowerOffMark() {
        try? FileManager.default.removeItem(at: markURL)
    }

    /// 起動時に呼ぶ。前回つなぎ直しの途中で落ちていたら、Wi-Fi を戻す。
    static func restoreIfInterrupted() {
        // このファイルは利用者権限で書ける場所にある。中身をそのまま
        // networksetup の引数へ渡さない（インターフェース名の形だけを受け付ける）。
        guard let raw = try? String(contentsOf: markURL, encoding: .utf8) else { return }
        let iface = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard iface.count <= 16,
              iface.range(of: "^[a-z]{2,5}[0-9]{1,3}$", options: .regularExpression) != nil else {
            clearPowerOffMark()
            return
        }
        clearPowerOffMark()
        DispatchQueue.global().async {
            _ = NetProbe.run("/usr/sbin/networksetup", ["-setairportpower", iface, "on"], timeout: 8)
        }
    }

    static func forceRoam(target: CWNetwork?,
                          current: CWNetwork?,
                          progress: @escaping (String) -> Void,
                          done: @escaping (Result) -> Void) {
        let iface = LinkSampler.interfaceName
        let t0 = Date()

        DispatchQueue.global().async {
            func report(_ s: String) { DispatchQueue.main.async { progress(s) } }
            func finish(_ ok: Bool, _ method: String, _ msg: String) {
                let r = Result(ok: ok, seconds: Date().timeIntervalSince(t0),
                               method: method, message: msg)
                DispatchQueue.main.async { done(r) }
            }

            // 1) 目的のAPへ直接張り替える
            if let t = target, let i = CWWiFiClient.shared().interface() {
                report("近くのAPへ切り替えています…")
                do {
                    try i.associate(to: t, password: nil)
                    if waitAssociated(8) { finish(true, "直接切替", ""); return }
                } catch {
                    // 次の手段へ落ちる
                }
            }

            _ = current   // 同じSSIDへの張り替えも -3900 になるため試さない

            // 2) 電源の入れ直し。確実だが数秒切れる。
            //    切る時間は最小限でよい。長く空けても掴み直す先が良くなるわけではない。
            report("Wi-Fiを入れ直しています…")
            // 切ってから入れ直すまでの間に落ちると、利用者のWi-Fiが切れたまま残る。
            // プロセスと一緒に死なない目印をディスクに置き、次の起動で戻す。
            Roamer.markPowerOff(iface)
            defer { Roamer.clearPowerOffMark() }
            _ = NetProbe.run("/usr/sbin/networksetup", ["-setairportpower", iface, "off"], timeout: 8)
            Thread.sleep(forTimeInterval: 0.4)
            _ = NetProbe.run("/usr/sbin/networksetup", ["-setairportpower", iface, "on"], timeout: 8)

            var ok = waitAssociated(20)
            if !ok {
                // 電波が落ちたままだと通信手段を失う。必ずもう一度入れ直す。
                report("再接続を試しています…")
                _ = NetProbe.run("/usr/sbin/networksetup", ["-setairportpower", iface, "on"], timeout: 8)
                ok = waitAssociated(15)
            }
            // 電波がつながっても、住所(DHCP)が下りるまで通信は戻らない。
            // 利用者が知りたいのは「使えるようになるまで」なので、そこまで待って計る。
            if ok {
                report("通信の再開を待っています…")
                _ = waitUsable(10)
            }
            finish(ok, "入れ直し", ok ? "" : "再接続できませんでした。Wi-Fiの状態を確認してください")
        }
    }

    /// 実際に通信が通るまで待つ。リンクが張れただけでは、まだ使えない。
    private static func waitUsable(_ seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let gw = NetProbe.defaultGateway(interface: LinkSampler.interfaceName),
               NetProbe.ping(gw, count: 1, interval: 0.2).loss < 100 { return true }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return false
    }

    private static func waitAssociated(_ seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if LinkSampler.read().associated { return true }
            Thread.sleep(forTimeInterval: 0.1)   // 速さを測りたいので細かく見る
        }
        return false
    }
}
