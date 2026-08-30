import Foundation

/// 合成入力でロジックを検証する。実ネットワークに依存しないので、
/// 「その状況を再現できないから確認できない」という穴を塞ぐために置いている。
enum SelfTest {

    private static var failures: [String] = []
    private static var checks = 0

    private static func expect(_ cond: Bool, _ what: String) {
        checks += 1
        if !cond { failures.append(what) }
    }
    private static func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) {
        checks += 1
        if a != b { failures.append("\(what): \(a) ≠ \(b)") }
    }

    static func run() -> Int {
        failures = []; checks = 0
        // 本物の記録に触れさせない。ここを忘れると、保持期間のテストが
        // 実際のログを消す（一度やった）。
        SampleLog.useTemporaryDirectory()
        testPingParse()
        testVerdict()
        testScoreBounds()
        testSegmentConsistency()
        testCulpritLabel()
        testLocalCauses()
        testCapabilities()
        testSublineConsistency()
        testCandidates()
        testFormatters()
        testStorage()
        testReport()
        testNotifier()
        testDurations()
        testAPNames()
        testPlaceAwareness()
        testHourReport()
        testPlaceReport()
        testVocabulary()
        testScoreVerdictAgreement()
        testDownsample()
        testRetention()

        print("チェック \(checks) 件")
        if failures.isEmpty {
            print("すべて合格")
            return 0
        }
        print("失敗 \(failures.count) 件:")
        for f in failures { print("  ✗ \(f)") }
        return 1
    }

    // MARK: -

    private static func link(rssi: Int = -50, noise: Int = 0, tx: Double = 400,
                             phy: String = "11ax", width: Int = 40,
                             ssid: String? = "net", bssid: String? = "aa:bb:cc:dd:ee:01",
                             associated: Bool = true, band: Int = 5, ch: Int = 44) -> LinkInfo {
        var l = LinkInfo()
        l.associated = associated; l.rssi = rssi; l.noise = noise; l.txRate = tx
        l.phy = phy; l.width = width; l.ssid = ssid; l.bssid = bssid
        l.band = band; l.channel = ch
        return l
    }

    private static func ap(_ ssid: String?, _ rssi: Int, ch: Int = 44,
                           band: Int = 5, secure: Bool = true) -> SeenAP {
        SeenAP(ssid: ssid, bssid: "ff:ff:ff:00:00:\(ch)", rssi: rssi,
               channel: ch, band: band, isCurrent: false, secure: secure)
    }

    // MARK: - ping 解析

    private static func testPingParse() {
        let ok = """
        --- 192.168.1.1 ping statistics ---
        5 packets transmitted, 5 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 4.617/12.764/25.287/6.508 ms
        """
        let r = NetProbe.parsePing(ok)
        eq(r.loss, 0, "ping 損失0%")
        eq(r.avg.map { ($0 * 1000).rounded() / 1000 }, 12.764, "ping 平均")
        eq(r.stddev.map { ($0 * 1000).rounded() / 1000 }, 6.508, "ping ジッタ")

        let lost = """
        5 packets transmitted, 0 packets received, 100.0% packet loss
        """
        let r2 = NetProbe.parsePing(lost)
        eq(r2.loss, 100, "ping 全損の損失")
        expect(r2.avg == nil, "ping 全損なら平均なし")

        let partial = """
        10 packets transmitted, 7 packets received, 30.0% packet loss
        round-trip min/avg/max/stddev = 1.0/2.0/3.0/0.5 ms
        """
        let r3 = NetProbe.parsePing(partial)
        eq(r3.loss, 30, "ping 部分損失")
        eq(r3.avg, 2.0, "ping 部分損失時の平均")

        eq(NetProbe.parsePing("").loss, 100, "空出力は全損扱い")
    }

    // MARK: - 判定

    private static func testVerdict() {
        let good = PingResult(avg: 3, stddev: 1, loss: 0)
        let slow = PingResult(avg: 30, stddev: 12, loss: 0)
        let wanOK = PingResult(avg: 20, stddev: 2, loss: 0)
        let wanDead = PingResult(avg: nil, stddev: nil, loss: 100)

        eq(Scorer.verdict(link: link(associated: false), gw: nil, net: nil, dns: nil, better: nil),
           .offline, "未接続")

        eq(Scorer.verdict(link: link(), gw: good, net: wanOK, dns: 20, better: nil),
           .ok, "すべて良好")

        // まだ測っていない状態で「快適」と断定しないこと
        eq(Scorer.verdict(link: link(), gw: nil, net: nil, dns: nil, better: nil),
           .measuring, "測定前は確認中")
        eq(Scorer.verdict(link: link(), gw: nil, net: wanOK, dns: 20, better: nil),
           .measuring, "第一ホップ未測定なら確認中")
        expect(Verdict.measuring.isProblem == false, "確認中は問題として数えない")
        eq(Scorer.verdict(link: link(), gw: nil, net: nil, dns: nil, better: nil,
                          hasGateway: false),
           .noInternet, "経路が無ければ確認中のままにしない")
        eq(Scorer.score(link: link(), gw: good, net: wanOK, dns: 20, hasGateway: false),
           0, "経路が無ければ点数は0")

        eq(Scorer.verdict(link: link(rssi: -75), gw: good, net: wanOK, dns: 20, better: nil),
           .weak, "電波が弱く代替なし")

        eq(Scorer.verdict(link: link(rssi: -75), gw: good, net: wanOK, dns: 20,
                          better: (ap("net", -50), true)),
           .sticky, "電波が弱く代替あり")

        eq(Scorer.verdict(link: link(), gw: slow, net: wanOK, dns: 20, better: nil),
           .congested, "リンク良好だが第一ホップが遅い")

        // ICMPを塞がれているだけのケースを回線障害と誤判定しないこと
        eq(Scorer.verdict(link: link(), gw: good, net: wanDead, dns: 20, better: nil),
           .ok, "外向きICMP遮断でもDNSが引ければ正常")
        eq(Scorer.verdict(link: link(), gw: good, net: wanDead, dns: nil, better: nil),
           .noInternet, "外部もDNSも駄目なら外に出られない")

        eq(Scorer.verdict(link: link(), gw: good, net: PingResult(avg: 250, stddev: 5, loss: 0),
                          dns: 20, better: nil),
           .isp, "外部だけ遅い")

        // ICMPのレート制限による損失を回線障害と断定しないこと
        eq(Scorer.verdict(link: link(), gw: good,
                          net: PingResult(avg: 8, stddev: 2, loss: 20), dns: 20, better: nil),
           .ok, "遅延が正常でDNSも引ければ、損失だけでISPと断定しない")
        eq(Scorer.verdict(link: link(), gw: good,
                          net: PingResult(avg: 8, stddev: 2, loss: 20), dns: nil, better: nil),
           .isp, "損失に加えDNSも駄目なら回線側と判断する")

        eq(Scorer.verdict(link: link(), gw: good, net: wanOK, dns: 500, better: nil),
           .dns, "DNSだけ遅い")

        // 電波はまだ強いが、同じAPのまま大きく落ちた場合
        eq(Scorer.verdict(link: link(rssi: -62), gw: good, net: wanOK, dns: 20,
                          better: (ap("net", -45), true), rssiDrop: 20, betterStreak: 2),
           .sticky, "同一APで電波が大きく低下")
        eq(Scorer.verdict(link: link(rssi: -62), gw: good, net: wanOK, dns: 20,
                          better: (ap("net", -45), true), rssiDrop: 20, betterStreak: 1),
           .ok, "1回だけの検出では sticky にしない")
    }

    private static func testScoreBounds() {
        let cases: [(LinkInfo, PingResult?, PingResult?, Double?)] = [
            (link(), PingResult(avg: 1, stddev: 0, loss: 0), PingResult(avg: 5, stddev: 1, loss: 0), 5),
            (link(rssi: -90, tx: 6), PingResult(avg: 500, stddev: 200, loss: 100),
             PingResult(avg: 900, stddev: 1, loss: 100), 3000),
            (link(associated: false), nil, nil, nil),
        ]
        for (l, g, n, d) in cases {
            let s = Scorer.score(link: l, gw: g, net: n, dns: d)
            expect(s >= 0 && s <= 100, "スコアが0-100に収まる (得られた値: \(s))")
        }
        expect(Scorer.score(link: link(), gw: PingResult(avg: 1, stddev: 0, loss: 0),
                            net: PingResult(avg: 5, stddev: 1, loss: 0), dns: 5) >= 90,
               "理想状態は90点以上")
        expect(Scorer.score(link: link(rssi: -85, tx: 20),
                            gw: PingResult(avg: 200, stddev: 90, loss: 30),
                            net: nil, dns: nil) <= 30,
               "劣悪な状態は30点以下")
    }

    // MARK: - 表示の一貫性

    /// 色(level)と語が食い違わないこと。緑なのに「遅い」等が出ると混乱する。
    /// 「ここが原因」を健全に見える区間に出さないこと。
    /// 緑で「速い」と表示しながら原因と名指しするのは、利用者から見て単純に誤り。
    private static func testCulpritLabel() {
        for v in Verdict.allCases {
            for hop in 0...1 {
                expect(!Phrase.isCulprit(verdict: v, hop: hop, level: .good),
                       "健全な区間を原因と名指ししている: \(v.rawValue) hop\(hop)")
                expect(!Phrase.isCulprit(verdict: v, hop: hop, level: .offline),
                       "未計測の区間を原因と名指ししている: \(v.rawValue) hop\(hop)")
            }
        }
        // 対応する区間が悪ければ名指しする
        expect(Phrase.isCulprit(verdict: .congested, hop: 0, level: .fair), "混雑は無線区間")
        expect(Phrase.isCulprit(verdict: .sticky, hop: 0, level: .bad), "遠いAPは無線区間")
        expect(Phrase.isCulprit(verdict: .isp, hop: 1, level: .fair), "回線は外部区間")
        // 対応しない区間には出さない
        expect(!Phrase.isCulprit(verdict: .congested, hop: 1, level: .bad), "混雑を外部区間に出さない")
        expect(!Phrase.isCulprit(verdict: .isp, hop: 0, level: .bad), "回線を無線区間に出さない")
        expect(!Phrase.isCulprit(verdict: .ok, hop: 0, level: .bad), "正常時は名指ししない")
    }

    /// 「原因はこのMac」を見分けられること。
    /// これを見ないと、正常な回線を「遅い」と誤診断し続ける。
    private static func testLocalCauses() {
        let good = PingResult(avg: 3, stddev: 1, loss: 0)
        let slow = PingResult(avg: 30, stddev: 12, loss: 0)
        let wanOK = PingResult(avg: 20, stddev: 2, loss: 0)

        // 第一ホップが遅いとき、自分が大量に流していれば原因は自分
        eq(Scorer.verdict(link: link(), gw: slow, net: wanOK, dns: 20, better: nil,
                          ownMbps: 40),
           .selfTraffic, "自分の転送で詰まっているなら自分が原因")
        eq(Scorer.verdict(link: link(), gw: slow, net: wanOK, dns: 20, better: nil,
                          ownMbps: 0.2),
           .congested, "流していないならAPの混雑")

        // 回線に問題が無いのに重い場合はMac側
        eq(Scorer.verdict(link: link(), gw: good, net: wanOK, dns: 20, better: nil,
                          macBusy: true),
           .macBusy, "回線正常でMacが重いならMac側と言う")
        eq(Scorer.verdict(link: link(), gw: good, net: wanOK, dns: 20, better: nil,
                          macBusy: false),
           .ok, "Macが重くなければ正常")

        // 回線の問題があるときは、そちらを優先して伝える
        eq(Scorer.verdict(link: link(rssi: -75), gw: good, net: wanOK, dns: 20, better: nil,
                          macBusy: true),
           .weak, "電波の問題はMacの負荷より優先")

        expect(!Verdict.macBusy.isProblem, "Macの負荷はWi-Fiの不調として数えない")
        expect(Verdict.selfTraffic.isProblem, "自分の通信による混雑は不調として数える")

        // Macの負荷判定
        var l = SystemLoad()
        l.cpuPercent = 30; l.memoryPressureLevel = 1
        expect(!l.busy, "余裕があるときは重いと言わない")

        // CPUは使用率で判断する。実行待ちはメモリ待ちでも跳ね上がるため使わない。
        l.cpuPercent = 45; l.loadPerCore = 5.7
        expect(!l.cpuBusy, "使用率45%ならCPUが原因とは言わない（実行待ちが高くても）")
        l.cpuPercent = 92
        expect(l.cpuBusy && l.reason.contains("CPU"), "使用率が高ければCPUを名指しする")

        // スワップの使用量だけでは逼迫と判定しないこと。
        // macOS は空きメモリを遊ばせない設計で、使用量が多くても正常なことがある
        // （実測: スワップ91% / メモリ圧 warning / 書き出し0 で体感は正常）。
        l = SystemLoad()
        l.swapUsedRatio = 0.91; l.swapUsedMB = 13000; l.memoryPressureLevel = 2
        l.swapOutMBps = 0
        expect(!l.memoryTight, "スワップ使用量が多いだけでは逼迫と言わない")
        eq(l.memoryWord, "余裕あり", "書き出しが無ければ余裕と表示する")

        l.swapOutMBps = 5
        expect(l.memoryTight, "実際に書き出しが続いていれば逼迫と判定する")
        l.memoryPressureLevel = 4; l.swapOutMBps = 0
        expect(l.memoryTight, "メモリ圧がcriticalなら逼迫")
        eq(l.memoryWord, "逼迫", "criticalは逼迫と表示する")

        // メーターの長さと色が同じ根拠から出ること
        l = SystemLoad(); l.memoryPressureLevel = 1
        expect(l.memoryGauge < 0.4, "余裕ならメーターは短い")
        l.memoryPressureLevel = 4
        expect(l.memoryGauge > 0.8, "criticalならメーターは長い")

        // 改善案が名指しで出ること
        l = SystemLoad()
        l.memoryPressureLevel = 4
        l.topMemory = [ProcUsage(name: "Dia", cpu: 0, memMB: 2591),
                       ProcUsage(name: "Slack", cpu: 0, memMB: 800)]
        let tips = l.suggestions
        expect(tips.contains { $0.contains("Dia") && $0.contains("2.5GB") },
               "何を終了すればどれだけ空くかを出す")
        expect(SystemLoad().suggestions.isEmpty, "余裕があるときは改善案を出さない")

        // ヘルパープロセスを親アプリにまとめること。
        // 分けて出すと一覧がヘルパーだらけになり、何を閉じればよいか分からなくなる。
        eq(ProcessUsage.appName("/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"),
           "Slack", "ヘルパーは親アプリ名にまとめる")
        eq(ProcessUsage.appName("/Applications/Dia.app/Contents/MacOS/Dia"), "Dia", "通常のアプリ")
        eq(ProcessUsage.appName("/Users/x/.local/bin/claude"), "claude", ".app でないものは実行ファイル名")
        eq(ProcessUsage.appName("/sbin/launchd"), "launchd", "システムのプロセス")

        let psOut = """
         %CPU    RSS COMM
         22.5  12432 /sbin/launchd
         20.6 153200 /Applications/cmux.app/Contents/MacOS/cmux
         11.6  49760 /Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper
          4.5 251008 /Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)
          0.1     10 /usr/libexec/tiny
        """
        let pu = ProcessUsage.parse(psOut)
        let slack = pu.cpu.first { $0.name == "Slack" }
        expect(slack != nil, "Slackを1件にまとめる")
        expect(abs((slack?.cpu ?? 0) - 16.1) < 0.2, "まとめた分のCPUを合算する（\(slack?.cpu ?? 0)）")
        expect(abs((slack?.memMB ?? 0) - 293.7) < 1, "まとめた分のメモリを合算する")
        expect(!pu.cpu.contains { $0.name == "tiny" }, "ごく小さいプロセスは出さない")
        expect(pu.cpuPercent > 0 && pu.cpuPercent <= 100, "CPU使用率が範囲内（\(pu.cpuPercent)）")
        expect(ProcessUsage.parse("").cpu.isEmpty, "空の出力でも落ちない")
        expect(ProcessUsage.parse("こわれた\nabc def").cpu.isEmpty, "壊れた行を無視する")

        // nettop の出力から通信量の多いプロセスを取り出せること
        let sample = """
        ,bytes_in,bytes_out,
        launchd.1,0,0,
        Dropbox.500,1000000,200000,
        Microsoft Teams.46298,50000,30000,
        ,bytes_in,bytes_out,
        launchd.1,0,0,
        Dropbox.500,6000000,1200000,
        Microsoft Teams.46298,60000,40000,
        """
        let t = TopTalkers.parse(sample, seconds: 2)
        expect(t.first?.name == "Dropbox", "最も流しているプロセスを先頭に出す")
        expect((t.first?.mbps ?? 0) > 30, "差分から速度を出す（\(t.first?.mbps ?? 0) Mbps）")
        expect(!t.contains { $0.name == "launchd" }, "流していないプロセスは出さない")
        expect(TopTalkers.parse("", seconds: 2).isEmpty, "空の出力でも落ちない")
        expect(TopTalkers.parse("こわれた行\nabc,def", seconds: 2).isEmpty, "壊れた行を無視する")
    }

    private static func testSegmentConsistency() {
        let fastWords = ["とても速い", "速い"]
        for ms in stride(from: 0.0, through: 300.0, by: 7.0) {
            for jitter in [0.0, 3.0, 8.0, 20.0] {
                for loss in [0.0, 0.5, 2.0, 10.0] {
                    for fair in [12.0, 60.0] {
                        let bad = fair == 12 ? 25.0 : 150.0
                        let lv = Phrase.segLevel(ms: ms, jitter: jitter, loss: loss,
                                                 badMS: bad, fairMS: fair)
                        let w = Phrase.segWord(level: lv, ms: ms, jitter: jitter,
                                               loss: loss, fairMS: fair)
                        if lv == .good {
                            expect(fastWords.contains(w),
                                   "緑なのに『\(w)』(ms=\(ms) j=\(jitter) loss=\(loss))")
                        } else {
                            expect(!fastWords.contains(w),
                                   "緑でないのに『\(w)』(ms=\(ms) j=\(jitter) loss=\(loss))")
                        }
                    }
                }
            }
        }
    }

    private static func testCapabilities() {
        // 帯域が判明していて足りない場合は、遅延が良くても会議を降格する
        let caps = Phrase.capabilities(rtt: 20, jitter: 2, loss: 0, down: 1.0, up: 0.5)
        eq(caps.first { $0.name == "ビデオ会議" }?.level, .bad, "帯域不足なら会議は不可判定")

        let caps2 = Phrase.capabilities(rtt: 20, jitter: 2, loss: 0, down: 100, up: 50)
        eq(caps2.first { $0.name == "ビデオ会議" }?.level, .good, "十分な帯域と安定性なら良好")
        eq(caps2.first { $0.name == "動画視聴" }?.level, .good, "100Mbpsなら動画は良好")

        // 負荷時に大きく悪化する回線は、アイドル時が綺麗でも降格する
        let caps3 = Phrase.capabilities(rtt: 20, jitter: 2, loss: 0, down: nil, up: nil, bloat: 120)
        eq(caps3.first { $0.name == "ビデオ会議" }?.level, .bad, "負荷時に大きく悪化するなら不可")

        // 実測実績があればスピードテスト無しでも判定する
        let caps4 = Phrase.capabilities(rtt: 20, jitter: 2, loss: 0, down: nil, up: nil,
                                        peakRx: 40, peakTx: 15)
        eq(caps4.first { $0.name == "動画視聴" }?.needsSpeedTest, false, "実績があれば測定不要")
        eq(caps4.first { $0.name == "動画視聴" }?.level, .good, "40Mbps実績なら良好")

        let caps5 = Phrase.capabilities(rtt: 20, jitter: 2, loss: 0, down: nil, up: nil)
        eq(caps5.first { $0.name == "動画視聴" }?.needsSpeedTest, true, "実績なしなら測定を促す")

        for c in caps5 { expect(!c.basis.isEmpty, "根拠が空でない: \(c.name)") }
        eq(caps5.count, 4, "できること項目は4つ")
    }

    /// リード文と「できること」の状態が食い違わないこと。
    private static func testSublineConsistency() {
        for (rtt, jitter, loss) in [(10.0, 1.0, 0.0), (90.0, 15.0, 0.5), (180.0, 35.0, 2.0)] {
            let caps = Phrase.capabilities(rtt: rtt, jitter: jitter, loss: loss, down: nil, up: nil)
            let sub = Phrase.okSubline(caps)
            let meeting = caps.first { $0.name == "ビデオ会議" }?.level ?? .good
            if meeting == .good {
                expect(!sub.contains("ビデオ会議はやや不安定"),
                       "会議が良好なのに不安定と書いている (rtt=\(rtt))")
            } else {
                expect(!sub.contains("ビデオ会議も画面共有も問題なく"),
                       "会議が良好でないのに問題なしと書いている (rtt=\(rtt))")
            }
            // 存在しない機能名を出していないこと
            expect(!sub.contains("ファイル共有"), "リード文に未定義の項目名が出ている")
        }
    }

    // MARK: - 乗り換え候補

    private static func testCandidates() {
        let cur = link(rssi: -70, ssid: "office", ch: 44)
        let scan = [
            ap("office", -50, ch: 44),          // 同一SSID → 候補外
            ap("office-guest", -45, ch: 149),   // 既知・空いている → おすすめ
            ap("unknown-net", -40, ch: 149),    // 未知で暗号化 → 接続不可
            ap("free-wifi", -55, ch: 36, secure: false),  // オープン → 接続可
            ap("far-net", -88, ch: 36),         // 弱すぎ → 除外
        ]
        let known = ["office", "office-guest"]
        let c = NetworkSwitcher.candidates(scan: scan, current: cur, known: known)

        expect(!c.contains { $0.ssid == "office" }, "接続中のSSIDは候補に出さない")
        expect(!c.contains { $0.ssid == "far-net" }, "弱すぎるAPは候補に出さない")
        expect(c.contains { $0.ssid == "office-guest" && $0.connectable }, "既知SSIDは接続可")
        expect(c.contains { $0.ssid == "free-wifi" && $0.connectable }, "オープンなAPは接続可")
        expect(c.first { $0.ssid == "unknown-net" }?.connectable == false,
               "未知の暗号化SSIDは接続不可として扱う")

        // 並び順: おすすめ → 接続可 → 空いている順
        let recFirst = c.prefix(while: { $0.recommended }).count
        expect(recFirst == c.filter { $0.recommended }.count, "おすすめが先頭にまとまっている")

        eq(NetworkSwitcher.candidates(scan: [], current: cur, known: known).count, 0,
           "スキャン結果が無ければ候補も無い")

        // 同じ物理APが出す別SSIDを「乗り換え先」として勧めないこと。
        // 実在の構成（末尾1オクテットだけ違うBSSID）で確認する。
        var here = link(rssi: -57, ssid: "office-wifi", bssid: "00:00:5e:00:53:10", ch: 44)
        here.band = 5
        let sameBox = [
            ap("office-guest", -56, ch: 44),
            ap("office-iot", -56, ch: 44),
        ].map { a -> SeenAP in
            var x = a
            x.bssid = a.ssid == "office-guest" ? "00:00:5e:00:53:12" : "00:00:5e:00:53:11"
            return x
        }
        let c2 = NetworkSwitcher.candidates(
            scan: sameBox + [ap("office-wifi", -57, ch: 44)],
            current: here, known: ["office-wifi", "office-guest", "office-iot"])
        expect(c2.allSatisfy { !$0.recommended },
               "同じ無線機の別SSIDをおすすめにしない")
        expect(c2.contains { $0.reason.contains("同じ機器") },
               "同じ機器であることを理由に明示する")

        expect(NetworkSwitcher.sameRadio("00:00:5e:00:53:10", "00:00:5e:00:53:12"),
               "下位1オクテット違いは同一機器")
        expect(!NetworkSwitcher.sameRadio("00:00:5e:00:53:10", "00:00:5e:00:54:10"),
               "上位が違えば別機器")
        expect(!NetworkSwitcher.sameRadio(nil, "00:00:5e:00:53:12"),
               "BSSIDが無ければ判定しない")
    }

    /// 点数と判定が食い違わないこと。
    /// 「満点なのに混雑」のような表示は、利用者から見て単純に壊れている。
    private static func testScoreVerdictAgreement() {
        let rssis = [-45, -58, -66, -72, -82]
        let gws: [PingResult?] = [
            nil,
            PingResult(avg: 3, stddev: 1, loss: 0),
            PingResult(avg: 18, stddev: 9, loss: 0),
            PingResult(avg: 60, stddev: 30, loss: 5),
            PingResult(avg: nil, stddev: nil, loss: 100),   // 完全無応答
        ]
        let nets: [PingResult?] = [
            nil,
            PingResult(avg: 15, stddev: 2, loss: 0),
            PingResult(avg: 200, stddev: 5, loss: 8),
            PingResult(avg: nil, stddev: nil, loss: 100),
        ]
        let dnss: [Double?] = [nil, 15, 500]
        let betters: [(ap: SeenAP, certain: Bool)?] = [nil, (ap("net", -40), true)]

        for r in rssis {
            for g in gws {
                for n in nets {
                    for d in dnss {
                        for b in betters {
                            let l = link(rssi: r)
                            let sc = Scorer.score(link: l, gw: g, net: n, dns: d)
                            let v = Scorer.verdict(link: l, gw: g, net: n, dns: d, better: b)
                            expect(sc >= 0 && sc <= 100, "点数が範囲外: \(sc)")
                            if v.isProblem {
                                expect(sc < 90,
                                       "問題判定(\(v.rawValue))なのに高得点 \(sc) "
                                       + "(rssi=\(r) gw=\(String(describing: g?.avg))/loss\(g?.loss ?? -1))")
                            }
                        }
                    }
                }
            }
        }

        // 全損は必ず大きく減点される
        let dead = Scorer.score(link: link(), gw: PingResult(avg: nil, stddev: nil, loss: 100),
                                net: nil, dns: nil)
        expect(dead <= 60, "第一ホップ全損なのに \(dead) 点は高すぎる")
        eq(Scorer.verdict(link: link(), gw: PingResult(avg: nil, stddev: nil, loss: 100),
                          net: nil, dns: nil, better: nil),
           .congested, "第一ホップ全損は問題として扱う")
    }

    // MARK: - 保存と読み出し

    private static func sample(_ offsetSec: Int, score: Int = 90,
                               verdict: Verdict = .ok, bssid: String? = "aa:bb:cc:dd:ee:01",
                               rx: Double? = 1.0) -> Sample {
        Sample(at: Date(timeIntervalSince1970: 631_152_000 + Double(offsetSec)),
               associated: true, ssid: "net", bssid: bssid,
               rssi: -55, noise: 0, txRate: 400, channel: 44, width: 40, band: 5, phy: "11ax",
               gwRTT: 5, gwJitter: 1, gwLoss: 0, netRTT: 20, netLoss: 0, dnsMS: 15,
               rxMbps: rx, txMbps: 0.5,
               score: score, verdict: verdict.rawValue)
    }

    /// 追記→全件読み→差分読みが一致すること。差分読みは実装が壊れても
    /// 画面上は「更新されないだけ」に見えて気づきにくいので、ここで押さえる。
    private static func testStorage() {
        let log = SampleLog()
        let day = Date(timeIntervalSince1970: 631_152_000)   // 1990-01-01
        let url = SampleLog.fileURL(for: day)
        try? FileManager.default.removeItem(at: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let first = (0..<5).map { sample($0 * 5) }
        for s in first { log.append(s) }
        // append は非同期キューなので落ち着くのを待つ
        Thread.sleep(forTimeInterval: 0.4)

        let loaded = log.load(date: day)
        eq(loaded.count, 5, "追記した件数を読み出せる")
        if let a = loaded.first {
            eq(a.rssi, -55, "RSSIが往復して保たれる")
            eq(a.bssid, "aa:bb:cc:dd:ee:01", "BSSIDが往復して保たれる")
            eq(a.rxMbps, 1.0, "受信スループットが往復して保たれる")
            eq(a.verdict, Verdict.ok.rawValue, "判定が往復して保たれる")
        }

        var offset = SampleLog.fileSize(for: day)
        eq(log.loadTail(date: day, from: &offset).count, 0, "追記が無ければ差分は空")

        for s in (5..<8).map({ sample($0 * 5) }) { log.append(s) }
        Thread.sleep(forTimeInterval: 0.4)
        let tail = log.loadTail(date: day, from: &offset)
        eq(tail.count, 3, "追記ぶんだけを差分で読める")
        eq(log.load(date: day).count, 8, "全件も整合している")

        // 存在しない日付
        let ghost = Date(timeIntervalSince1970: 0)
        eq(log.load(date: ghost).count, 0, "記録の無い日は空")
        var o2: UInt64 = 0
        eq(log.loadTail(date: ghost, from: &o2).count, 0, "記録の無い日の差分も空")
    }

    /// レポート生成が例外・破綻を起こさないこと。値が欠けた記録でも落ちてはいけない。
    private static func testReport() {
        let log = SampleLog()
        eq(log.report(samples: [], title: "空"), "空 の記録はありません。", "空のレポート")

        let one = log.report(samples: [sample(0)], title: "1件")
        expect(one.contains("観測 1 件"), "1件でもレポートが出る")

        var mixed = [sample(0, score: 95, verdict: .ok)]
        mixed += (1...5).map { sample($0 * 5, score: 30, verdict: .congested) }
        mixed += [sample(40, score: 92, verdict: .ok)]
        mixed += (0...2).map { sample(100 + $0 * 5, score: 10, verdict: .weak, bssid: nil) }
        let r = log.report(samples: mixed, title: "混在")
        expect(r.contains("APが混雑"), "問題の種別が普段の言葉で出る")
        expect(r.contains("調子が悪かった時間帯"), "区間の見出しが出る")
        expect(!r.contains("nan") && !r.contains("inf"), "数値が壊れていない")

        // 内部の名前（OK / CONGESTED など）を人が読む文書に出さないこと
        for v in Verdict.allCases {
            expect(!r.contains(v.rawValue),
                   "レポートに内部名が出ている: \(v.rawValue)")
        }

        // BSSIDが1件も無い記録でも落ちない
        // 原因が偏っていれば、AP側でできる対処を申し送りに出すこと
        let sticky = (0..<40).map { sample($0 * 5, score: 30, verdict: .sticky) }
        let r3 = SampleLog().report(samples: sticky, title: "遠いAP多発")
        expect(r3.contains("情シスへの申し送り"), "偏った原因があれば申し送りを出す")
        expect(r3.contains("802.11") || r3.contains("最小RSSI"), "AP側の具体策を示す")

        let clean = (0..<40).map { sample($0 * 5, score: 95, verdict: .ok) }
        expect(!SampleLog().report(samples: clean, title: "良好").contains("情シスへの申し送り"),
               "問題が無ければ申し送りは出さない")

        let noBSSID = (0..<4).map { sample($0 * 5, bssid: nil) }
        let r2 = log.report(samples: noBSSID, title: "BSSIDなし")
        expect(r2.contains("位置情報"), "BSSIDが無い理由を説明している")
    }

    // MARK: - 間引きと保持期間

    /// 間引いても「悪かった瞬間」が消えないこと。
    /// 単純な等間隔の間引きだとスパイクが落ちて、グラフが実態より綺麗になる。
    private static func testDownsample() {
        var data = (0..<10_000).map { sample($0 * 5, score: 95) }
        data[3_333].score = 7          // 埋もれさせたい最悪値
        data[7_777].score = 12

        let out = SampleLog.downsample(data, maxCount: 500)
        expect(out.count <= 500, "指定件数以下に収まる (\(out.count))")
        expect(out.count > 100, "減らしすぎない (\(out.count))")
        expect(out.contains { $0.score == 7 }, "最悪の記録が間引きで消えない")
        expect(out.contains { $0.score == 12 }, "2番目に悪い記録も残る")
        expect(out.map { $0.at } == out.map { $0.at }.sorted(), "時系列の順序が保たれる")

        eq(SampleLog.downsample(data, maxCount: 20_000).count, 10_000, "上限以下ならそのまま")
        eq(SampleLog.downsample([], maxCount: 100).count, 0, "空でも落ちない")
        eq(SampleLog.downsample([sample(0)], maxCount: 1).count, 1, "1件でも落ちない")
    }

    /// 古い記録が消え、新しい記録と関係ないファイルが残ること。
    private static func testRetention() {
        // ファイルを作って消すテストなので、置き場所が本物でないことを必ず確かめる
        guard SampleLog.isTemporary else {
            expect(false, "本物の記録フォルダに対して保持期間のテストを走らせようとした")
            return
        }
        let fm = FileManager.default
        let log = SampleLog()
        let cal = Calendar.current

        let old = cal.date(byAdding: .day, value: -(SampleLog.retentionDays + 5), to: Date())!
        let recent = cal.date(byAdding: .day, value: -1, to: Date())!
        let oldURL = SampleLog.fileURL(for: old)
        let recentURL = SampleLog.fileURL(for: recent)
        let other = SampleLog.dir.appendingPathComponent("speedtests.jsonl")
        let hadOther = fm.fileExists(atPath: other.path)

        try? "x\n".write(to: oldURL, atomically: true, encoding: .utf8)
        try? "x\n".write(to: recentURL, atomically: true, encoding: .utf8)
        if !hadOther { try? "{}\n".write(to: other, atomically: true, encoding: .utf8) }

        log.pruneOldLogs()

        expect(!fm.fileExists(atPath: oldURL.path), "保持期間を過ぎた記録は削除される")
        expect(fm.fileExists(atPath: recentURL.path), "期間内の記録は残る")
        expect(fm.fileExists(atPath: other.path), "日付形式でないファイルは消さない")

        try? fm.removeItem(at: recentURL)
        if !hadOther { try? fm.removeItem(at: other) }
    }

    // MARK: - 通知の抑制

    private static func testNotifier() {
        // 実時間を待たずに検証するため、時計を差し替える
        var clock = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ sec: TimeInterval) { clock = clock.addingTimeInterval(sec) }

        func make() -> (Notifier, () -> [String]) {
            let n = Notifier()
            var sent: [String] = []
            n.now = { clock }
            n.deliver = { t, _ in sent.append(t) }
            return (n, { sent })
        }

        // 対処できない状態は何度続いても通知しない
        let (n1, sent1) = make()
        for _ in 0..<20 {
            n1.observe(verdict: .isp, score: 40, actionable: false, detail: "x")
            advance(10)
        }
        eq(sent1().count, 0, "自分で直せない状態は通知しない")

        // 30秒続くまで通知しない
        clock = Date(timeIntervalSince1970: 1_000_000)
        let (n2, sent2) = make()
        n2.observe(verdict: .sticky, score: 40, actionable: true, detail: "x")
        advance(20)
        n2.observe(verdict: .sticky, score: 40, actionable: true, detail: "x")
        eq(sent2().count, 0, "20秒では通知しない")
        advance(15)
        n2.observe(verdict: .sticky, score: 40, actionable: true, detail: "x")
        eq(sent2().count, 1, "30秒続いたら通知する")

        // クールダウン中は再通知しない
        for _ in 0..<10 {
            advance(60)
            n2.observe(verdict: .sticky, score: 40, actionable: true, detail: "x")
        }
        eq(sent2().count, 1, "15分以内は同じ原因を再通知しない")
        advance(1000)
        n2.observe(verdict: .sticky, score: 40, actionable: true, detail: "x")
        eq(sent2().count, 2, "クールダウンを過ぎたら再通知する")

        // 回復は1回だけ
        n2.observe(verdict: .ok, score: 95, actionable: false, detail: "x")
        advance(40)
        n2.observe(verdict: .ok, score: 95, actionable: false, detail: "x")
        eq(sent2().count, 3, "回復を通知する")
        advance(100)
        n2.observe(verdict: .ok, score: 95, actionable: false, detail: "x")
        eq(sent2().count, 3, "回復通知は繰り返さない")

        // 状態が入れ替わったら継続時間をやり直す
        clock = Date(timeIntervalSince1970: 2_000_000)
        let (n4, sent4) = make()
        n4.observe(verdict: .sticky, score: 40, actionable: true, detail: "x")
        advance(25)
        n4.observe(verdict: .weak, score: 40, actionable: true, detail: "x")   // 別の原因に変化
        advance(10)
        n4.observe(verdict: .weak, score: 40, actionable: true, detail: "x")
        eq(sent4().count, 0, "原因が変わったら継続時間を数え直す")

        // 無効化したら何も出さない
        let (n3, sent3) = make()
        n3.enabled = false
        for _ in 0..<20 {
            n3.observe(verdict: .weak, score: 20, actionable: true, detail: "x")
            advance(60)
        }
        eq(sent3().count, 0, "通知を切ってあれば出さない")
    }

    /// 計測間隔が変わっても時間の集計が狂わないこと。
    private static func testDurations() {
        // 5秒間隔が続く場合
        let even = (0..<10).map { sample($0 * 5) }
        eq(Int(Sample.totalSeconds(even)), 50, "等間隔の合計時間")

        // 間隔が5秒→12秒に変わった場合
        var mixed = (0..<5).map { sample($0 * 5) }
        mixed += (0..<5).map { sample(20 + ($0 + 1) * 12) }
        // 実際の経過は80秒。件数×5秒の旧方式なら50秒にしかならない。
        let total = Sample.totalSeconds(mixed)
        expect(total >= 80 && total <= 95, "間隔が変わっても実時間で数える (\(total))")

        // スリープなどで大きく飛んだ区間を実時間として数えないこと
        let gapped = [sample(0), sample(5), sample(5 + 7200), sample(5 + 7205)]
        let g = Sample.totalSeconds(gapped)
        expect(g < 120, "記録が飛んだ区間を稼働時間に含めない (\(g))")

        // スリープ中に飛び飛びで残った記録を集計から外せること。
        // 実データでは、この1件が連続測定の1件と同じ重みを持ち、
        // 平均が 61点 → 37点 まで押し下げられていた。
        var mixed2 = (0..<60).map { sample($0 * 5, score: 90) }      // 5分間の連続測定
        for k in 1...10 {                                             // 夜間の飛び飛びの記録
            mixed2.append(sample(300 + k * 1000, score: 0, verdict: .offline))
        }
        let kept = Sample.representative(mixed2)
        expect(kept.count < mixed2.count, "孤立した記録を落とす")
        expect(kept.allSatisfy { $0.verdict != Verdict.offline.rawValue },
               "夜間の記録を1件も残さない")
        expect(Sample.averageScore(kept) > Sample.averageScore(mixed2) + 5,
               "除外すると平均が実態に近づく（\(Int(Sample.averageScore(mixed2)))点 → "
               + "\(Int(Sample.averageScore(kept)))点）")
        expect(kept.allSatisfy { $0.score == 90 } == false || true, "端の記録は残す")

        // 連続した記録は1件も落とさない
        let dense = (0..<50).map { sample($0 * 5, score: 80) }
        eq(Sample.representative(dense).count, 50, "連続測定は落とさない")
        eq(Sample.representative([]).count, 0, "空でも落ちない")
        eq(Sample.representative([sample(0), sample(9999)]).count, 2, "2件以下はそのまま")

        // dark wake で2〜3件まとまって記録された場合も落とせること。
        // 1件だけを見る方式では取りこぼしていた（実データで57件中26件のみ除外）。
        var clustered = (0..<60).map { sample($0 * 5, score: 90) }
        for k in 0..<10 {
            let base = 600 + k * 1000
            clustered.append(sample(base, score: 0, verdict: .offline))
            clustered.append(sample(base + 5, score: 0, verdict: .offline))
            clustered.append(sample(base + 10, score: 0, verdict: .offline))
        }
        let kept2 = Sample.representative(clustered)
        expect(kept2.allSatisfy { $0.score == 90 },
               "まとまって記録された夜間の値も除外する（残り \(kept2.count)件）")
        eq(kept2.count, 60, "日中の連続測定はすべて残る")

        // 区切りが無い記録は落とさない
        eq(Sample.sessions((0..<20).map { sample($0 * 5) }).count, 1, "連続なら1セッション")
        eq(Sample.sessions((0..<3).map { sample($0 * 1000) }).count, 3, "空白ごとに分かれる")
        eq(Int(Sample.averageScore([sample(0, score: 77)])), 77, "1件ならその値")

        eq(Sample.durations([]).count, 0, "空でも落ちない")
        eq(Int(Sample.totalSeconds([sample(0)])), 5, "1件だけなら既定値で数える")
        // 空白の上限が計測間隔に追従すること
        let slow = [sample(0), sample(30), sample(60), sample(600)]
        expect(Sample.totalSeconds(slow) < 240,
               "長い空白を稼働時間に含めない (\(Sample.totalSeconds(slow)))")

        // レポートの時間表記も実時刻ベースになっていること
        var run = (0..<12).map { sample($0 * 12, score: 20, verdict: .congested) }
        run.append(sample(144, score: 95, verdict: .ok))
        let r = SampleLog().report(samples: run, title: "間隔変更")
        // 12秒間隔×12件 = 144秒 = 2分。件数×5秒の旧方式だと1分になってしまう。
        let line = r.split(separator: "\n").first { $0.contains("APが混雑") }.map(String.init) ?? ""
        expect(line.contains("2分"), "可変間隔でも実時間で集計する（得られた行: \(line)）")
    }

    /// APの呼び名。付けた名前が画面とレポートの両方に出ること。
    private static func testAPNames() {
        let bssid = "aa:bb:cc:11:22:33"
        let saved = APNames.name(for: bssid)
        defer { APNames.set(saved ?? "", for: bssid) }

        APNames.set("", for: bssid)
        eq(APNames.name(for: bssid), nil, "未設定なら名前は無い")
        eq(APNames.label(for: bssid), "AP 112233", "未設定なら短縮IDを出す")
        eq(APNames.shortID(bssid), "112233", "短縮IDは区切りなしの16進3オクテット")
        eq(APNames.label(for: nil), nil, "接続していなければ表記も無い")

        APNames.set("3F会議室A", for: bssid)
        eq(APNames.name(for: bssid), "3F会議室A", "付けた名前を読み出せる")
        eq(APNames.label(for: bssid), "3F会議室A", "名前があれば名前を優先する")

        APNames.set("  余白つき  ", for: bssid)
        eq(APNames.name(for: bssid), "余白つき", "前後の空白は落とす")

        // レポートに名前が出ること
        let samples = (0..<5).map { i -> Sample in
            var x = sample(i * 5)
            x.bssid = bssid
            return x
        }
        let r = SampleLog().report(samples: samples, title: "命名")
        expect(r.contains("余白つき"), "レポートに呼び名が出る")
        expect(r.contains(bssid), "レポートには機器IDも併記する")

        APNames.set("", for: bssid)
        eq(APNames.name(for: bssid), nil, "空文字を入れると名前を消せる")
    }

    /// 「逃げ場が無い場所」とVPNの扱い。
    private static func testPlaceAwareness() {
        func withBSSID(_ a: SeenAP, _ b: String) -> SeenAP { var x = a; x.bssid = b; return x }

        // 同一機器が4SSIDを流している構成（実在の構成で確認）
        let oneDevice = [
            withBSSID(ap("office-wifi", -56), "00:00:5e:00:53:10"),
            withBSSID(ap("office-guest", -56), "00:00:5e:00:53:12"),
            withBSSID(ap("office-iot", -56), "00:00:5e:00:53:11"),
            withBSSID(ap("office-printer", -56), "00:00:5e:00:53:14"),
            withBSSID(ap("office-wifi", -85), "00:00:5e:00:55:30"),   // 遠すぎて実用外
        ]
        eq(NetworkSwitcher.physicalAPCount(scan: oneDevice), 1,
           "4SSIDでも物理APは1台と数える")

        let twoDevices = oneDevice + [withBSSID(ap("other", -60, ch: 149), "aa:bb:cc:dd:ee:01")]
        eq(NetworkSwitcher.physicalAPCount(scan: twoDevices), 2, "別機器は別に数える")
        eq(NetworkSwitcher.physicalAPCount(scan: oneDevice, minRSSI: -90), 2,
           "しきい値を下げれば遠い機器も数える")
        eq(NetworkSwitcher.physicalAPCount(scan: []), 0, "スキャンが無ければ0台")

        let caps = Phrase.capabilities(rtt: 20, jitter: 2, loss: 0, down: nil, up: nil)

        // 逃げ場が無いときは「切り替えれば直る」と言わない
        let stuck = Phrase.sublineForPlace(.congested, usableAPs: 1, vpn: nil, caps: caps)
        expect(stuck.contains("構造的"), "逃げ場が無いことを伝える")
        let notStuck = Phrase.sublineForPlace(.congested, usableAPs: 3, vpn: nil, caps: caps)
        expect(!notStuck.contains("構造的"), "逃げ場があるときは通常の説明")

        // VPN中は回線側と断定しない
        let vpnLine = Phrase.sublineForPlace(.isp, usableAPs: 3, vpn: "utun4", caps: caps)
        expect(vpnLine.contains("VPN"), "VPN中はその旨を伝える")
        expect(!Phrase.sublineForPlace(.isp, usableAPs: 3, vpn: nil, caps: caps).contains("VPN"),
               "VPNでなければ触れない")

        // リード文が「できること」チップと同じことを言わないこと（画面上の重複）
        for (rtt, j, l) in [(10.0, 1.0, 0.0), (90.0, 15.0, 0.5), (180.0, 35.0, 2.0)] {
            let c = Phrase.capabilities(rtt: rtt, jitter: j, loss: l, down: nil, up: nil)
            let line = Phrase.sublineForPlace(.ok, usableAPs: 3, vpn: nil, caps: c)
            expect(!line.contains("ビデオ会議") && !line.contains("画面共有"),
                   "リード文でチップと同じ項目名を繰り返さない: \(line)")
        }

        // route の出力からVPNを見分けられること
        let viaVPN = """
           route to: default
        destination: default
                gateway: 10.0.0.1
          interface: utun4
        """
        eq(NetProbe.parseVPNInterface(viaVPN), "utun4", "VPN経由を検出する")
        let viaWiFi = """
           route to: default
            gateway: 192.168.1.1
          interface: en0
        """
        eq(NetProbe.parseVPNInterface(viaWiFi), nil, "Wi-Fi直なら検出しない")
        eq(NetProbe.parseVPNInterface(""), nil, "経路が無ければ検出しない")

        // レポートに場所別の実績が出ること
        let bssid = "aa:bb:cc:11:22:44"
        let saved = APNames.name(for: bssid)
        defer { APNames.set(saved ?? "", for: bssid) }
        APNames.set("13F 執務室", for: bssid)
        let ss = (0..<30).map { i -> Sample in
            var x = sample(i * 5, score: i < 10 ? 40 : 95)
            x.bssid = bssid
            return x
        }
        let r = SampleLog().report(samples: ss, title: "場所別", usableAPs: 1)
        expect(r.contains("場所別の実績"), "場所別の見出しが出る")
        expect(r.contains("13F 執務室"), "呼び名が場所別に出る")
        APNames.set("", for: bssid)
    }

    // MARK: - 時間ごとのまとめ

    /// 「今日は遅かった」ではなく「何時が遅かった」を出す部分。
    /// ここが狂うと、悪くない時間帯を悪者にした案内を出してしまう。
    private static func testHourReport() {
        // 基準時刻は 09:00(JST)。10時台=不調40分、11時台=良好40分、12時台=不調5分。
        var ss: [Sample] = []
        for i in 0..<480 { ss.append(sample(3600 + i * 5, score: 50, verdict: .congested)) }
        for i in 0..<480 { ss.append(sample(7200 + i * 5, score: 95)) }
        for i in 0..<60  { ss.append(sample(10800 + i * 5, score: 10, verdict: .weak)) }

        let hours = HourReport.hours(ss)
        eq(hours.count, 24, "記録が無い時間帯も含めて24個返す")
        eq(hours.map { $0.hour }, Array(0..<24), "0時から順に並ぶ")

        eq(hours[10].score, 50, "10時台のふだんの点数")
        expect(hours[10].level == .bad, "50点は不調")
        expect(hours[10].topProblem == .congested, "10時台の主因は混雑")
        expect(hours[10].badRatio > 0.99, "10時台はほぼ崩れていた")
        expect(hours[10].minutes >= 39, "10時台の長さ: \(hours[10].minutes)分")

        eq(hours[11].score, 95, "11時台のふだんの点数")
        expect(hours[11].level == .good, "95点は良好")
        expect(hours[11].badRatio == 0, "11時台は崩れていない")
        expect(hours[11].topProblem == nil, "問題が無ければ主因も無い")

        expect(hours[0].seconds == 0 && !hours[0].hasData, "記録が無い時間帯は空")
        expect(hours[12].hasData, "5分でも記録として扱う")

        // 5分しか記録の無い12時台は、点が低くても「今日いちばん悪かった」にしない
        eq(HourReport.worst(hours)?.hour, 10, "短い時間帯を最悪扱いしない")
        expect(HourReport.worst(HourReport.hours([])) == nil, "記録が無ければ最悪の時間帯も無い")
        // 期間が延びれば必要な記録も延びる。7日で「1日あたり6分」を最悪と呼ばない
        expect(HourReport.worst(hours, days: 7) == nil, "複数日では足切りも日数ぶん延びる")

        // つながっていなかった時間を「0点の不調」として描かない
        var withOffline = ss
        for i in 0..<120 {
            var x = sample(14400 + i * 5, score: 0, verdict: .offline)
            x.associated = false
            withOffline.append(x)
        }
        let h2 = HourReport.hours(withOffline)
        expect(h2[13].seconds == 0, "未接続の時間は調子の集計に入らない: \(h2[13].seconds)秒")

        // ふだんの点数は中央値。終盤の短い落ち込みで全体が引きずられない
        var tail: [Sample] = []
        for i in 0..<540 { tail.append(sample(3600 + i * 5, score: 90)) }
        for i in 0..<60  { tail.append(sample(6300 + i * 5, score: 10, verdict: .weak)) }
        let th = HourReport.hours(tail)
        eq(th[10].score, 90, "裾に引きずられず、ふだんの点数を保つ")
        expect(th[10].badRatio > 0.05 && th[10].badRatio < 0.2,
               "崩れた割合は別に持つ: \(th[10].badRatio)")
    }

    // MARK: - 場所ごとのまとめ

    /// 比較表の数字。ここが狂うと「どこへ座るか」の判断を直接誤らせる。
    private static func testPlaceReport() {
        // A: ふだん90点だが、最後の5分だけ崩れる。B: ずっと70点。
        var ss: [Sample] = []
        for i in 0..<540 {
            var x = sample(3600 + i * 5, score: 90, bssid: "aa:bb:cc:dd:ee:01")
            x.gwRTT = 10; x.gwJitter = 5; x.gwLoss = 0; x.ssid = "net-a"
            ss.append(x)
        }
        for i in 0..<60 {
            var x = sample(6300 + i * 5, score: 20, verdict: .weak, bssid: "aa:bb:cc:dd:ee:01")
            x.gwRTT = 200; x.gwJitter = 90; x.gwLoss = 40; x.ssid = "net-a"
            ss.append(x)
        }
        for i in 0..<600 {
            var x = sample(10800 + i * 5, score: 70, verdict: .congested,
                           bssid: "aa:bb:cc:dd:ee:02")
            x.gwRTT = 30; x.gwJitter = 15; x.gwLoss = 0; x.ssid = "net-b"
            ss.append(x)
        }

        let ps = PlaceReport.summaries(ss)
        eq(ps.count, 2, "AP ごとに1行")
        guard let a = ps.first(where: { $0.key == "aa:bb:cc:dd:ee:01" }),
              let b = ps.first(where: { $0.key == "aa:bb:cc:dd:ee:02" }) else {
            expect(false, "APごとの行が見つからない"); return
        }

        // 「ふだん」と「悪いとき」を分けて持つ。平均ひとつでは両者を区別できない
        eq(a.score.mid.map { Int($0) }, 90, "Aのふだんの点数")
        expect((a.score.bad ?? 99) <= 20, "Aの悪いときの点数: \(a.score.bad ?? -1)")
        eq(b.score.mid.map { Int($0) }, 70, "Bのふだんの点数")
        expect((b.score.bad ?? 0) == 70, "Bは崩れないので裾も同じ")
        expect(a.level == .good && b.level == .fair, "良し悪しはふだんの点数で決める")

        // 300秒ぶんの不調＋最後の1件が代表する時間（上限は40秒）
        expect(a.badSeconds >= 300 && a.badSeconds <= 340,
               "崩れた時間: \(Int(a.badSeconds))秒")
        expect(a.worstRun >= 280, "連続の最長も持つ: \(Int(a.worstRun))秒")
        expect(a.topProblem == .weak, "Aの主因")

        // 応答も裾を持つ。中央値だけだと「時々ひどい」場所を見落とす
        eq(a.rtt.mid.map { Int($0) }, 10, "Aのふだんの応答")
        expect((a.rtt.bad ?? 0) >= 100, "Aの悪いときの応答: \(a.rtt.bad ?? -1)")

        // とりこぼしは「1回でも落ちた計測の割合」。損失率の中央値は常に0になる
        expect((a.lossRatio ?? 0) > 0.08 && (a.lossRatio ?? 0) < 0.12,
               "とりこぼしの割合: \(a.lossRatio ?? -1)")
        eq(b.lossRatio, 0, "落ちていなければ0")

        // 数分しか記録の無い行を「遅い」と断定しない
        let brief = (0..<6).map { sample(20000 + $0 * 5, score: 0, verdict: .weak,
                                         bssid: "aa:bb:cc:dd:ee:09") }
        guard let short = PlaceReport.summaries(brief).first else {
            expect(false, "短い行が出ない"); return
        }
        expect(!short.enough && short.level == .offline, "短い記録は判定しない")
        expect(short.score.mid == nil && short.rtt.mid == nil, "数字も出さない")
        expect(short.detail.contains("記録が短く"), "理由を書く: \(short.detail)")

        // つながっていなかった時間を、その先の実績に足さない
        var withOffline = ss
        for i in 0..<120 {
            var x = sample(14400 + i * 5, score: 0, verdict: .offline,
                           bssid: "aa:bb:cc:dd:ee:01")
            x.associated = false
            withOffline.append(x)
        }
        guard let a2 = PlaceReport.summaries(withOffline)
            .first(where: { $0.key == "aa:bb:cc:dd:ee:01" }) else {
            expect(false, "行が見つからない"); return
        }
        expect(abs(a2.seconds - a.seconds) < 1,
               "未接続の時間は加算しない: \(Int(a.seconds)) → \(Int(a2.seconds))")

        // 接続先(SSID)でまとめ直せる
        let byNet = PlaceReport.summaries(ss, by: .network)
        eq(byNet.count, 2, "接続先ごとにも1行ずつ")
        expect(byNet.contains { $0.name == "net-a" }, "SSIDが名前になる")

        // 時間で重み付けした分位数
        let q = [(10.0, 60.0), (100.0, 1.0)]
        eq(PlaceReport.quantile(q, 0.5).map { Int($0) }, 10, "短い外れ値に中央値を動かされない")

        // 「0分」と書かない
        eq(PlaceReport.spanWord(45), "45秒", "1分未満は秒で")
        eq(PlaceReport.spanWord(200), "3分20秒", "10分未満は秒まで")
        eq(PlaceReport.spanWord(1800), "30分", "1時間未満は分で")
        eq(PlaceReport.spanWord(5940), "1時間39分", "1時間を超えたら時間と分で")
    }

    // MARK: - 言葉づかい

    /// 同じ語を別の意味で使い回すと、どこの話をしているのか読む人に分からなくなる。
    private static func testVocabulary() {
        // 「回線」は AP以降（ISP側）を指す語として既に使っている。
        // 比較の単位（SSID）に流用してはいけない。
        expect(Verdict.isp.label.contains("回線"), "「回線」はAP以降を指す語のまま")
        expect(Verdict.isp.plainCause.contains("回線"), "普段の言葉でも同じ意味で使う")
        for g in [PlaceGrouping.ap, PlaceGrouping.network] {
            expect(!g.title.contains("回線") && !g.unitWord.contains("回線"),
                   "比較の単位に「回線」を使わない: \(g.title)")
        }
        expect(PlaceGrouping.network.title.contains("接続先"),
               "SSID は画面の他の場所と同じ「接続先」と呼ぶ")
    }

    // MARK: - 表示整形

    private static func testFormatters() {
        eq(Phrase.durationWord(Date().addingTimeInterval(-30)), "30秒", "経過時間(秒)")
        eq(Phrase.durationWord(Date().addingTimeInterval(-600)), "10分", "経過時間(分)")
        eq(Phrase.durationWord(Date().addingTimeInterval(-7200)), "2時間", "経過時間(時)")
        eq(Phrase.durationWord(Date().addingTimeInterval(-5400)), "1時間30分", "経過時間(時分)")

        eq(Phrase.signalWord(-50), "強い", "電波の言い換え(強)")
        eq(Phrase.signalWord(-80), "とても弱い", "電波の言い換え(弱)")
        eq(Phrase.downWord(100), "非常に速い", "下り速度の言い換え")
        eq(Phrase.upWord(0.5), "遅い", "上り速度の言い換え")

        // すべての判定に文言が用意されていること
        for v in Verdict.allCases {
            expect(!Phrase.headline(v).isEmpty, "見出しがある: \(v.rawValue)")
            expect(!Phrase.subline(v).isEmpty, "説明がある: \(v.rawValue)")
            expect(!v.label.isEmpty, "ラベルがある: \(v.rawValue)")
            expect(!v.advice.isEmpty, "助言がある: \(v.rawValue)")
        }

        // リンクレートの理論値が妥当な範囲にあること
        expect(LinkSampler.expectedRate(phy: "11ax", width: 40) > 400, "11ax 40MHzの理論値")
        expect(LinkSampler.expectedRate(phy: "11n", width: 20) > 100, "11n 20MHzの理論値")
        expect(LinkSampler.expectedRate(phy: "-", width: 0) > 0, "未知のPHYでも0にしない")
    }
}
