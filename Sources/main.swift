import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = MenuController()
    func applicationDidFinishLaunching(_ n: Notification) {
        controller.start()
    }
}

// 動作確認用: GUI を起動せずに自動起動の登録状態だけを出す
if CommandLine.arguments.contains("--status") {
    print("version:     \(Build.version)")
    print("bundle:      \(Bundle.main.bundleURL.path)")
    print("login item:  \(LoginItem.statusText)")
    print("stable path: \(LoginItem.isInStableLocation)")
    // ホットキーが他アプリと衝突していると登録に失敗する。黙って効かなくなるので確認できるようにする。
    let hk = HotKey(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | optionKey)) {}
    print("hotkey ⌥⌘W: \(hk != nil ? "登録できる" : "登録失敗（他アプリと衝突）")")
    print("gateway:     \(NetProbe.defaultGateway(interface: LinkSampler.interfaceName) ?? "見つからない")")
    print("interface:   \(LinkSampler.interfaceName)")
    print("log dir:     \(SampleLog.dir.path)")
    exit(0)
}

// 動作確認用: 情シスへ返す「いまの状況」の文面をそのまま出す。
// 画面のボタンと同じ組み立てを使うが、値は記録の最新1件と今のリンクから取る
// （常駐して測っていないので、この経路では測定中の値までは出せない）。
if CommandLine.arguments.contains("--itstatus") {
    let log = SampleLog()
    let today = log.load(date: Date())
    var i = ITStatus.Input()
    i.appVersion = Build.version
    i.os = Host.os
    i.model = Host.model
    i.mac = LinkSampler.hardwareAddress
    let link = LinkSampler.read()
    i.associated = link.associated
    i.ssid = link.ssid; i.bssid = link.bssid
    i.channel = link.channel; i.band = link.band; i.width = link.width
    i.rssi = link.rssi; i.noise = link.noise; i.txRate = link.txRate; i.phy = link.phy
    if let last = today.last {
        i.verdict = last.scoreVerdict ?? .measuring
        i.score = last.score
        i.gwRTT = last.gwRTT; i.gwJitter = last.gwJitter; i.gwLoss = last.gwLoss
        i.wanRTT = last.netRTT; i.dnsMS = last.dnsMS
    }
    i.recent = today
    print(ITStatus.text(i))
    exit(0)
}

// 動作確認用: 実効速度テストだけを走らせて生の結果を出す（回線を約20秒占有する）
if CommandLine.arguments.contains("--speedtest") {
    let r = NetProbe.speedTest()
    print("down: \(r.downMbps.map { String(format: "%.1f Mbps", $0) } ?? "取得失敗")")
    print("up:   \(r.upMbps.map { String(format: "%.1f Mbps", $0) } ?? "取得失敗")")
    print("rpm:  \(r.rpm.map { String(format: "%.0f", $0) } ?? "取得失敗")")
    exit(r.ok ? 0 : 1)
}

// 動作確認用: スキャン結果と切替候補の判定内訳をそのまま出す
if CommandLine.arguments.contains("--scan") {
    let sem = DispatchSemaphore(value: 0)
    let link = LinkSampler.read()
    print("現在: ssid=\(link.ssid ?? "<nil>") rssi=\(link.rssi) ch\(link.channel) band=\(link.band)")
    let known = NetworkSwitcher.preferredNetworks()
    print("既知ネットワーク: \(known.count)件")

    let sm = ScanManager()
    sm.scan(current: link) { aps in
        print("--- スキャン結果 \(aps.count)件 ---")
        for a in aps {
            print(String(format: "  %-24@ %4d dBm  ch%-4d %dGHz %@",
                         (a.ssid ?? "<nil>") as NSString, a.rssi, a.channel, a.band,
                         a.secure ? "要PW" : "オープン"))
        }
        let cands = NetworkSwitcher.candidates(scan: aps, current: link, known: known)
        print("--- 候補 \(cands.count)件 ---")
        for c in cands { print("  \(c.ssid)  \(c.rssi)dBm ch\(c.channel) 同ch\(c.crowding)台  \(c.reason)") }
        sem.signal()
    }
    // scan は main キューへコールバックするのでランループを回す
    while sem.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

// 動作確認用: つなぎ直しに実際どれだけかかるかを測る（数秒通信が切れる）
if CommandLine.arguments.contains("--roamtest") {
    let sem = DispatchSemaphore(value: 0)
    Roamer.forceRoam(target: nil, current: nil, progress: { print("  \($0)") }, done: { r in
        print(String(format: "結果: %@ / %@ / %.1f秒", r.ok ? "成功" : "失敗", r.method, r.seconds))
        if !r.message.isEmpty { print("  \(r.message)") }
        sem.signal()
    })
    while sem.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    exit(0)
}

/// テストが使った一時的な記録フォルダは、最後に一度だけ片付ける。
/// 途中で片付けると、以降のテストが本物のデータを触る。
/// 設定はメモリ上なので、プロセスが終われば消える。
func finishTests(_ code: Int32) -> Never {
    SampleLog.cleanUpTemporaryDirectory()
    exit(code)
}

if CommandLine.arguments.contains("--test") {
    let a = SelfTest.run()
    print("")
    let b = UITest.run()
    finishTests(Int32(a + b == 0 ? 0 : 1))
}

if CommandLine.arguments.contains("--uitest") {
    finishTests(Int32(UITest.run()))
}

if CommandLine.arguments.contains("--selftest") {
    finishTests(Int32(SelfTest.run()))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // Dockに出さないメニューバー常駐
let delegate = AppDelegate()
app.delegate = delegate
app.run()
