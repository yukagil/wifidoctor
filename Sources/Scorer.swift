import Foundation

/// 観測値から 0-100 のスコアと「何が原因か」を決める。
/// 設計方針: レイヤを下から順に潰す。リンク層が悪ければそこで確定させ、
/// リンク層が健全なときだけ上位(AP以降/DNS)を疑う。
enum Scorer {

    static func score(link: LinkInfo, gw: PingResult?, net: PingResult?, dns: Double?,
                      hasGateway: Bool = true) -> Int {
        guard link.associated else { return 0 }
        guard hasGateway else { return 0 }
        var s = 100.0

        // --- 電波の強さ ---
        switch link.rssi {
        case ..<(-78): s -= 45
        case ..<(-73): s -= 32
        case ..<(-68): s -= 20
        case ..<(-63): s -= 9
        default: break
        }

        // --- SNR(ノイズ込みの実効品質) --- 計測できないときは減点しない
        if let snr = link.snr {
            switch snr {
            case ..<15: s -= 25
            case ..<22: s -= 14
            case ..<28: s -= 6
            default: break
            }
        }

        // --- リンクレートが理論値に対してどれだけ落ちているか ---
        let expected = LinkSampler.expectedRate(phy: link.phy, width: link.width)
        if expected > 0, link.txRate > 0 {
            let ratio = link.txRate / expected
            if ratio < 0.2 { s -= 18 } else if ratio < 0.35 { s -= 11 } else if ratio < 0.55 { s -= 5 }
        }

        // --- 自分〜AP の遅延(ここが本命の指標) ---
        // 損失の減点は avg の有無と独立させること。全損時は avg が nil になるので、
        // ここをネストさせると「完全に届いていないのに満点」という矛盾が起きる。
        if let g = gw {
            if let avg = g.avg {
                switch avg {
                case 40...: s -= 35
                case 20..<40: s -= 22
                case 10..<20: s -= 12
                case 5..<10: s -= 4
                default: break
                }
                if let j = g.stddev {
                    if j > 15 { s -= 15 } else if j > 8 { s -= 8 } else if j > 4 { s -= 3 }
                }
            }
            s -= min(45, g.loss * 1.5)
        }

        // --- AP以降 ---
        if let n = net, n.loss >= 100 {
            // 全く返らない場合、外向きICMPを塞ぐ企業FWの可能性がある。
            // DNSが引けていれば実際には通信できているので減点しない。
            // 引けないなら本当に外に出られていないので、大きく減点する。
            if dns == nil { s -= 70 }
        } else if let n = net {
            if let avg = n.avg, avg > 120 { s -= 12 } else if let avg = n.avg, avg > 60 { s -= 5 }
            // 損失はレート制限の可能性があるので重みを抑える
            s -= min(12, max(0, n.loss - 10) * 0.6)
        }

        // DNSが遅いとページが開かない体感になる。判定でも問題として扱う以上、
        // 点数にも同じ重みで反映させる（片方だけ良い表示になると矛盾する）。
        if let d = dns, d > 300 { s -= 25 } else if let d = dns, d > 120 { s -= 8 }

        return max(0, min(100, Int(s.rounded())))
    }

    static func verdict(link: LinkInfo,
                        gw: PingResult?, net: PingResult?, dns: Double?,
                        better: (ap: SeenAP, certain: Bool)?,
                        rssiDrop: Int = 0, betterStreak: Int = 0,
                        hasGateway: Bool = true,
                        ownMbps: Double = 0, macBusy: Bool = false) -> Verdict {
        guard link.associated else { return .offline }
        // 経路が無い＝どこにも出られない。ここを「確認中」にすると永久に測定中のままになる。
        guard hasGateway else { return .noInternet }
        // 一度も測れていない状態で「快適です」と言い切ってはいけない。
        // 再接続直後は測定値を捨てるので、必ずここを通る。
        guard gw != nil else { return .measuring }

        let gwBad = (gw?.avg ?? 0) > 12 || (gw?.stddev ?? 0) > 6 || (gw?.loss ?? 0) > 2
        let signalWeak = link.rssi < -68 || (link.snr.map { $0 < 22 } ?? false)

        // 1) リンクが弱い → 乗り換え先があるなら sticky、無ければ単に遠い
        if signalWeak {
            return better != nil ? .sticky : .weak
        }
        // 2) まだ弱くはないが、同じAPのまま電波が大きく落ちている＝そのAPから離れた。
        //    電波は揺らぐので、より良いAPが複数回続けて見えていることを条件に加える。
        if better != nil, rssiDrop >= 12, betterStreak >= 2 { return .sticky }
        // 3) 乗り換え先が明確に強く、かつ実際に遅い → sticky
        if let b = better, b.certain, gwBad { return .sticky }

        // 4) リンクは健全なのに第一ホップが遅い。
        //    ただし自分が大量に流していれば、混んでいるのは他人ではなく自分。
        //    大きな転送は少ない帯域でも待ち行列を作り、遅延を跳ね上げる。
        if gwBad, ownMbps >= 8 { return .selfTraffic }
        if gwBad { return .congested }

        // 4) 第一ホップは健全 → ここから先は自分の責任範囲外。
        //    ただし企業FWが外向きICMPを全部塞いでいることがある。その場合 loss=100 に
        //    なるが回線は正常なので、DNSが引けているかどうかで裏を取る。
        if let n = net, n.loss >= 100 {
            // DNSが引けていれば外へは出られている＝ICMPを塞がれているだけ。
            // 引けないなら本当に外に出られていない。
            guard dns != nil else { return .noInternet }
        } else if let n = net {
            // 公開IPへのICMPはレート制限で落ちることがあるため、損失だけでは断定しない。
            // 遅延が明確に大きいか、損失に加えてDNSも劣化している場合に限る。
            let slow = (n.avg ?? 0) > 120
            let lossy = n.loss > 15 && (dns == nil || (dns ?? 0) > 300)
            if slow || lossy { return .isp }
        }
        if let d = dns, d > 300 { return .dns }

        // 5) 回線に問題が見当たらないのに体感が悪いなら、Mac側を疑う。
        //    ここを見ないと「正常です」と言い切って利用者の実感と食い違う。
        if macBusy { return .macBusy }

        return .ok
    }
}
