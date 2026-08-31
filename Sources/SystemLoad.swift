import Foundation

/// このMac自身の負荷。
///
/// 「Wi-Fiが遅い」と感じても、原因が回線とは限らない。
///  - 自分の通信で回線を埋めている（大きな転送・クラウド同期）
///  - CPUやメモリが逼迫していて、通信は正常なのに動作が重い
/// これらを見ないと、正常な回線を「遅い」と誤診断する。
struct SystemLoad {
    var loadPerCore: Double = 0
    var cpuPercent: Double = 0

    /// macOS が持っているメモリ圧レベル。Activity Monitor の色と同じ根拠。
    /// 1 = normal, 2 = warning, 4 = critical
    var memoryPressureLevel: Int = 1

    /// 実際にスワップを読み書きしている量。
    /// スワップの「使用量」ではなく、この「出入り」が体感の重さに直結する。
    var swapInMBps: Double = 0
    var swapOutMBps: Double = 0

    var freeMemoryMB: Double = 0
    var compressedMB: Double = 0
    var swapUsedMB: Double = 0
    var swapTotalMB: Double = 0
    var swapUsedRatio: Double = 0

    var topCPU: [ProcUsage] = []
    var topMemory: [ProcUsage] = []

    /// CPUが詰まっているか。使用率で見る。
    /// 実行待ち（ロードアベレージ）は、メモリ待ちでも跳ね上がるためCPUの指標にしない。
    var cpuBusy: Bool { cpuPercent >= 85 }

    /// メモリが逼迫しているか。
    ///
    /// スワップの使用量では判定しない。macOS は空きメモリを遊ばせない設計で、
    /// 圧縮とスワップを積極的に使う。使用量が多くても正常なことが普通にある
    /// （実測でスワップ91%・メモリ圧 warning・書き出し0という状態を確認）。
    /// macOS 自身のメモリ圧レベルと、実際の読み書きの発生で判断する。
    var memoryTight: Bool {
        if memoryPressureLevel >= 4 { return true }              // critical
        return memoryPressureLevel >= 2 && swapOutMBps >= 1      // 逼迫していて実際に書き出している
    }

    var busy: Bool { cpuBusy || memoryTight }

    var memoryWord: String {
        switch memoryPressureLevel {
        case 4: return "逼迫"
        case 2: return swapOutMBps >= 1 ? "やや逼迫" : "余裕あり"
        default: return "余裕"
        }
    }

    /// メーター用（0-1）。色と長さを同じ根拠から出す。
    var cpuGauge: Double { min(1, cpuPercent / 100) }
    var memoryGauge: Double {
        switch memoryPressureLevel {
        case 4: return 0.95
        case 2: return swapOutMBps >= 1 ? 0.75 : 0.5
        default: return 0.25
        }
    }

    var reason: String {
        var parts: [String] = []
        if cpuBusy { parts.append(String(format: "CPU使用率 %.0f%%", cpuPercent)) }
        if memoryTight {
            parts.append(memoryPressureLevel >= 4
                ? "メモリ圧 critical"
                : String(format: "メモリ待ちが発生（書き出し %.0fMB/秒）", swapOutMBps))
        }
        return parts.joined(separator: " / ")
    }

    /// 何をすれば改善するか。名指しできないと手の打ちようがない。
    var suggestions: [String] {
        var out: [String] = []
        if memoryTight, let top = topMemory.first {
            let size = top.memMB >= 1024
                ? String(format: "%.1fGB", top.memMB / 1024)
                : String(format: "%.0fMB", top.memMB)
            out.append("「\(top.name)」を終了すると \(size) 空きます")
            if topMemory.count > 1 {
                out.append("使っていないアプリやブラウザのタブを閉じてください")
            }
        }
        if cpuBusy, let top = topCPU.first {
            out.append(String(format: "「%@」がCPUを %.0f%% 使っています", top.name, top.cpu))
        }
        return out
    }

    // 前回のCPUチックとスワップ回数。差分を取るために保持する。
    // 前回値は2つの経路（5秒ごとの計測と、パネルを開いたときの即時更新）から
    // 同時に読み書きされる。ARCを伴わない値なので落ちはしないが、差分が壊れて
    // CPU使用率が実態とかけ離れ、「Macの負荷が高い」が誤って出る。
    private static let lock = NSLock()
    private static var prevCPU: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private static var prevSwap: (inC: UInt64, outC: UInt64, at: Date)?

    /// - Parameter includeProcesses: アプリ一覧まで取るか。
    ///   ps は40msほどかかるので、5秒ごとの計測では省いて画面を開くときだけ取る。
    static func read(includeProcesses: Bool = false) -> SystemLoad {
        // 前回値との差分を取る処理なので、2本が同時に入ると差分が壊れる。
        // 重い部分（プロセス一覧）は外に出してあるので、ここは短時間で抜ける。
        lock.lock()
        defer { lock.unlock() }
        var s = SystemLoad()

        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) > 0 {
            s.loadPerCore = loads[0] / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        }

        // CPU使用率はチックの差分から出す。ps の合計は概算にしかならない。
        var cpuInfo = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuOK = withUnsafeMutablePointer(to: &cpuInfo) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        if cpuOK == KERN_SUCCESS {
            let cur = (user: cpuInfo.cpu_ticks.0, system: cpuInfo.cpu_ticks.1,
                       idle: cpuInfo.cpu_ticks.2, nice: cpuInfo.cpu_ticks.3)
            if let p = prevCPU {
                let du = Double(cur.user &- p.user), ds = Double(cur.system &- p.system)
                let di = Double(cur.idle &- p.idle), dn = Double(cur.nice &- p.nice)
                let total = du + ds + di + dn
                if total > 0 { s.cpuPercent = (du + ds + dn) / total * 100 }
            }
            prevCPU = cur
        }

        if let level = sysctlInt("kern.memorystatus_vm_pressure_level") { s.memoryPressureLevel = level }

        var xsw = xsw_usage()
        var xswSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &xswSize, nil, 0) == 0, xsw.xsu_total > 0 {
            s.swapUsedRatio = Double(xsw.xsu_used) / Double(xsw.xsu_total)
            s.swapUsedMB = Double(xsw.xsu_used) / 1_048_576
            s.swapTotalMB = Double(xsw.xsu_total) / 1_048_576
        }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if ok == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            s.freeMemoryMB = Double(stats.free_count) * page / 1_048_576
            s.compressedMB = Double(stats.compressor_page_count) * page / 1_048_576

            let now = Date()
            if let p = prevSwap {
                let dt = now.timeIntervalSince(p.at)
                if dt > 0.5 {
                    s.swapInMBps = Double(stats.swapins &- p.inC) * page / 1_048_576 / dt
                    s.swapOutMBps = Double(stats.swapouts &- p.outC) * page / 1_048_576 / dt
                }
            }
            prevSwap = (stats.swapins, stats.swapouts, now)
        }

        if includeProcesses {
            // ps を起動する重い処理。差分の計算とは無関係なので錠の外で行う。
            lock.unlock()
            let procs = ProcessUsage.read()
            lock.lock()
            s.topCPU = Array(procs.cpu.prefix(5))
            s.topMemory = Array(procs.memory.prefix(5))
        }
        return s
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }
}

/// 資源を使っているアプリ。
/// 「逼迫している」とだけ言われても対処できないので、必ず名前まで出す。
struct ProcUsage: Identifiable {
    var id: String { name }
    var name: String
    var cpu: Double      // %（Activity Monitor と同じ、コア合算の値）
    var memMB: Double
}

enum ProcessUsage {

    /// 実行ファイルのパスからアプリ名を取り出す。
    /// ヘルパープロセスは親アプリにまとめる。
    /// `/Applications/Slack.app/.../Slack Helper (Renderer)` は「Slack」として数える。
    /// 分けて出すと一覧がヘルパーだらけになり、何を閉じればよいか分からない。
    static func appName(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if let first = parts.first(where: { $0.hasSuffix(".app") }) {
            return String(first.dropLast(4))
        }
        return parts.last.map(String.init) ?? path
    }

    static func read() -> (cpu: [ProcUsage], memory: [ProcUsage], cpuPercent: Double) {
        parse(NetProbe.run("/bin/ps", ["-Ao", "pcpu,rss,comm", "-r"], timeout: 5))
    }

    /// ps の出力解析。実際に走らせずに検証できるよう分離してある。
    static func parse(_ out: String) -> (cpu: [ProcUsage], memory: [ProcUsage], cpuPercent: Double) {
        var byApp: [String: (cpu: Double, mem: Double)] = [:]
        var totalCPU = 0.0

        for line in out.split(separator: "\n").dropFirst() {   // 1行目は見出し
            let t = line.trimmingCharacters(in: .whitespaces)
            let f = t.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let cpu = Double(f[0]), let rssKB = Double(f[1]) else { continue }
            let name = appName(String(f[2]))
            var e = byApp[name] ?? (0, 0)
            e.cpu += cpu
            e.mem += rssKB / 1024
            byApp[name] = e
            totalCPU += cpu
        }

        let all = byApp.map { ProcUsage(name: $0.key, cpu: $0.value.cpu, memMB: $0.value.mem) }
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        return (cpu: all.sorted { $0.cpu > $1.cpu }.filter { $0.cpu >= 1 },
                memory: all.sorted { $0.memMB > $1.memMB }.filter { $0.memMB >= 50 },
                cpuPercent: min(100, totalCPU / cores))
    }
}

/// 通信量の多いプロセス。回線を埋めている犯人を名指しするために使う。
/// nettop は1〜2秒かかるので、必要になった時だけ呼ぶ。
enum TopTalkers {
    struct Entry {
        var name: String
        var mbps: Double
    }

    static func read(seconds: Int = 2) -> [Entry] {
        let out = NetProbe.run("/usr/bin/nettop",
                               ["-P", "-L", "\(seconds)", "-x", "-J", "bytes_in,bytes_out"],
                               timeout: Double(seconds) + 8)
        return parse(out, seconds: seconds)
    }

    /// nettop の出力解析。実際に走らせずに検証できるよう分離してある。
    /// 同じプロセスが複数回現れるので、最後に出た値（最新の累計）を採る。
    static func parse(_ out: String, seconds: Int) -> [Entry] {
        var latest: [String: (inB: Double, outB: Double)] = [:]
        var first: [String: (inB: Double, outB: Double)] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3 else { continue }
            let raw = String(f[0])
            guard let i = Double(f[1]), let o = Double(f[2]) else { continue }
            // "Microsoft Teams.46298" のように末尾にPIDが付く
            let name = raw.contains(".")
                ? String(raw[raw.startIndex..<raw.lastIndex(of: ".")!]) : raw
            if first[name] == nil { first[name] = (i, o) }
            let prev = latest[name] ?? (0, 0)
            latest[name] = (max(prev.inB, i), max(prev.outB, o))
        }

        let span = Double(max(1, seconds - 1))
        var out2: [Entry] = []
        for (name, last) in latest {
            let f0 = first[name] ?? (0, 0)
            let bytes = max(0, (last.inB - f0.inB) + (last.outB - f0.outB))
            let mbps = bytes * 8 / span / 1_000_000
            if mbps >= 0.5 { out2.append(Entry(name: name, mbps: mbps)) }
        }
        return out2.sorted { $0.mbps > $1.mbps }
    }
}
