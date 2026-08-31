import Foundation

/// ping / dig を実際に走らせてネットワーク層を測る。
/// 「自分〜AP」「AP〜インターネット」「DNS」を分けて測ることが切り分けの本体。
struct PingResult {
    var avg: Double?
    var stddev: Double?
    var loss: Double   // %
    var ok: Bool { avg != nil }
}

enum NetProbe {

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 12) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        // stderr を溜め込むとパイプが埋まって相手プロセスが止まり、こちらの読み取りも
        // 固まる。使わないので捨てる。
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }

        // タイムアウトしたら確実に殺す。放置するとサンプリングが詰まる。
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// デフォルトゲートウェイのIP。会議室を移動してもサブネットが変わりうるので毎回引き直す。
    ///
    /// インターフェースを指定できるようにしてあるのは VPN のため。
    /// フルトンネルVPN下では既定経路の相手がトンネルの対向になり、
    /// 「自分 → Wi-Fi機器」として測った値がインターネット越しの往復になる。
    /// 12ms の閾値をまず超えるので、混雑していなくても恒常的に「混雑」と誤診断していた。
    static func defaultGateway(interface: String? = nil) -> String? {
        gateway(interface: interface) { args in
            run("/sbin/route", args, timeout: 3)
        }
    }

    /// route の呼び出しを差し替えられる形。優先順そのものを検証できるようにしてある。
    /// インターフェース指定を先に試し、取れなければ全域の経路へ退避する。
    static func gateway(interface: String?, run: ([String]) -> String) -> String? {
        if let interface, !interface.isEmpty {
            let scoped = run(["-n", "get", "-ifscope", interface, "default"])
            if let ip = parseGateway(scoped) { return ip }
        }
        return parseGateway(run(["-n", "get", "default"]))
    }

    /// 実際に route を叩かずに検証できるよう分離してある。
    static func parseGateway(_ s: String) -> String? {
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                let ip = t.replacingOccurrences(of: "gateway:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return ip.isEmpty ? nil : ip
            }
        }
        return nil
    }

    static func ping(_ host: String, count: Int, interval: Double = 0.2) -> PingResult {
        let out = run("/sbin/ping",
                      ["-c", "\(count)", "-i", "\(interval)", "-W", "1500", "-q", host],
                      timeout: Double(count) * interval + 6)
        return parsePing(out)
    }

    /// ping の出力解析。実際に走らせずに検証できるよう独立させてある。
    static func parsePing(_ out: String) -> PingResult {
        var r = PingResult(avg: nil, stddev: nil, loss: 100)
        for line in out.split(separator: "\n") {
            if line.contains("packet loss"),
               let f = line.split(separator: ",").first(where: { $0.contains("packet loss") }) {
                let num = f.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "% packet loss", with: "")
                r.loss = Double(num) ?? 100
            }
            if line.contains("round-trip"), let rhs = line.split(separator: "=").last {
                let parts = rhs.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " ms", with: "")
                    .split(separator: "/")
                if parts.count >= 4 {
                    r.avg = Double(parts[1]); r.stddev = Double(parts[3])
                }
            }
        }
        return r
    }

    // MARK: - TCPによる代替計測

    /// ICMPを返さない機器は珍しくない。その場合 ping の損失100%が続き、
    /// 「ずっと混雑している」と誤判定してしまうので、TCPの接続時間で代替する。
    /// ポートが閉じていても RST が返れば往復時間は測れるので、開放ポートは不要。
    private static func tcpConnectMS(_ host: String, _ port: UInt16, timeout: Double) -> Double? {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let t0 = Date()
        var res: Int32 = -1
        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                res = connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if res == 0 { return Date().timeIntervalSince(t0) * 1000 }
        guard errno == EINPROGRESS else { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return nil }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        // 接続拒否(RST)でも相手は応答している。往復時間としては有効。
        guard err == 0 || err == ECONNREFUSED else { return nil }
        return Date().timeIntervalSince(t0) * 1000
    }

    /// その相手が応答を返すポートを1つ見つける。見つからなければ TCP でも測れない。
    static func findTCPPort(_ host: String) -> UInt16? {
        for p: UInt16 in [80, 443, 53, 22, 7] {
            if tcpConnectMS(host, p, timeout: 1.0) != nil { return p }
        }
        return nil
    }

    static func tcpPing(_ host: String, port: UInt16, count: Int) -> PingResult {
        var samples: [Double] = []
        for _ in 0..<count {
            if let ms = tcpConnectMS(host, port, timeout: 1.5) { samples.append(ms) }
            usleep(200_000)
        }
        var r = PingResult(avg: nil, stddev: nil, loss: 100)
        r.loss = Double(count - samples.count) / Double(count) * 100
        guard !samples.isEmpty else { return r }
        let avg = samples.reduce(0, +) / Double(samples.count)
        let varsum = samples.reduce(0) { $0 + ($1 - avg) * ($1 - avg) }
        r.avg = avg
        r.stddev = (varsum / Double(samples.count)).squareRoot()
        return r
    }

    /// 外部到達性は必ず2箇所へ測り、状態の良い方を採用する。
    /// 企業FWが特定宛先のICMPを絞っているだけなのに「回線障害」と誤判定するのを防ぐため。
    /// 公開IPへのICMPは相手側でレート制限されることがある。
    /// 速く撃つほど「自分が作った損失」を回線障害と誤認するので、間隔を空けて撃つ。
    static func probeWAN() -> PingResult {
        let a = ping("1.1.1.1", count: 6, interval: 0.4)
        let b = ping("8.8.8.8", count: 6, interval: 0.4)
        // 損失が少ない方 / 同率なら遅延が小さい方を「本当の外部品質」とみなす
        if a.loss != b.loss { return a.loss < b.loss ? a : b }
        return (a.avg ?? .infinity) <= (b.avg ?? .infinity) ? a : b
    }

    /// DNSの応答時間。
    ///
    /// サーバを明示すると、そこへの直接問い合わせが遮断されている環境で必ず失敗する
    /// （実測: `dig @8.8.8.8` は無応答なのに、OS経由なら30msで解決できた）。
    /// アプリが実際に体験する値を測りたいので、まずOSと同じ経路で測る。
    static func dnsMillis(server: String? = nil) -> Double? {
        if let ms = digMillis(server: nil) { return ms }
        if let s = server { return digMillis(server: s) }
        return nil
    }

    private static func digMillis(server: String?) -> Double? {
        var args = ["+tries=1", "+time=2", "+stats"]
        if let s = server { args.append("@\(s)") }
        args.append(contentsOf: ["www.google.com", "A"])
        let out = run("/usr/bin/dig", args, timeout: 6)
        for line in out.split(separator: "\n") where line.contains("Query time:") {
            let digits = line.filter { $0.isNumber }
            return Double(digits)
        }
        return nil
    }

    /// インターフェースの累積バイト数。差分を取れば、実際に流れている量が
    /// 何も追加で通信せずに分かる。スピードテストと違い回線を占有しない。
    struct IfCounters {
        var rx: UInt64
        var tx: UInt64
        var at: Date
    }

    static func counters(_ iface: String) -> IfCounters? {
        let out = run("/usr/sbin/netstat", ["-ibn"], timeout: 5)
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            // 総計は <Link#n> の行にだけ載る（アドレスファミリごとの行は部分値）
            guard f.count >= 10, f[0] == iface, f[2].hasPrefix("<Link") else { continue }
            guard let rx = UInt64(f[6]), let tx = UInt64(f[9]) else { continue }
            return IfCounters(rx: rx, tx: tx, at: Date())
        }
        return nil
    }

    /// 実効スループット。macOS 標準の networkQuality を使う。
    /// リンクを飽和させるので自動では絶対に走らせない（手動ボタン専用）。
    struct SpeedResult {
        var downMbps: Double?
        var upMbps: Double?
        var rpm: Double?        // Responsiveness (Round-trips Per Minute)。高いほど詰まりにくい
        var ok: Bool { downMbps != nil }
    }

    static func speedTest(seconds: Int = 20) -> SpeedResult {
        let iface = LinkSampler.interfaceName
        let out = run("/usr/bin/networkQuality",
                      ["-c", "-s", "-I", iface, "-M", "\(seconds)"],
                      timeout: Double(seconds) + 25)
        var r = SpeedResult()
        guard let data = out.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return r }

        // キー名はOSバージョンで揺れるため、候補を順に当たる
        func num(_ keys: [String]) -> Double? {
            for k in keys {
                if let v = j[k] as? Double { return v }
                if let v = j[k] as? Int { return Double(v) }
            }
            return nil
        }
        // スループットは bps で返る
        if let d = num(["dl_throughput", "downlink_throughput", "download_throughput"]) {
            r.downMbps = d / 1_000_000
        }
        if let u = num(["ul_throughput", "uplink_throughput", "upload_throughput"]) {
            r.upMbps = u / 1_000_000
        }
        r.rpm = num(["responsiveness", "dl_responsiveness", "base_rtt_responsiveness"])
        return r
    }

    /// VPNを通しているか。
    /// 通していると ping の往復にトンネルの遅延が乗るため、
    /// 「AP以降が遅い」と誤診断する。判定結果の信頼性に直結する。
    static func vpnInterface() -> String? {
        parseVPNInterface(run("/sbin/route", ["-n", "get", "default"], timeout: 3))
    }

    /// 実際に route を叩かずに検証できるよう分離してある。
    static func parseVPNInterface(_ s: String) -> String? {
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("interface:") else { continue }
            let iface = t.replacingOccurrences(of: "interface:", with: "")
                .trimmingCharacters(in: .whitespaces)
            // 既定の経路が物理インターフェース以外なら、そこを通されている
            if iface.hasPrefix("utun") || iface.hasPrefix("ipsec") || iface.hasPrefix("ppp") {
                return iface
            }
            return nil
        }
        return nil
    }

    /// システムに設定されている最初のDNSサーバ。
    static func primaryDNS() -> String? {
        let out = run("/usr/sbin/scutil", ["--dns"], timeout: 3)
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("nameserver[0]"), let v = t.split(separator: ":").last {
                return v.trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
