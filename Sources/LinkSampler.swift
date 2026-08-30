import Foundation
import CoreWLAN

/// CoreWLAN からリンク層の状態を読む。権限不要な値(RSSI/noise/txRate/channel)は常に取れる。
/// SSID/BSSID だけは位置情報の許可が要るため nil になりうる。
struct LinkInfo {
    var associated = false
    var ssid: String?
    var bssid: String?
    var rssi = 0
    var noise = 0
    var txRate: Double = 0
    var channel = 0
    var width = 0
    var band = 0
    var phy = "-"

    /// CoreWLAN の noiseMeasurement() は状況により 0 を返す（＝計測不能）。
    /// 0 を素直に使うと SNR が -59dB などとなり「電波が弱い」と誤判定するため、
    /// 有効かどうかを必ず明示的に判定する。
    var noiseValid: Bool { noise < 0 }
    var snr: Int? { noiseValid ? rssi - noise : nil }
}

enum LinkSampler {
    static var interfaceName: String { CWWiFiClient.shared().interface()?.interfaceName ?? "en0" }

    /// CoreWLAN が 0 を返したときのフォールバック値。system_profiler から拾う。
    /// ノイズフロアは秒単位では変化しないので、数十秒古い値でも判定には十分。
    private static var fallbackNoise: Int = 0
    private static var fallbackAt: Date?

    private static var lastAttempt: Date?

    /// system_profiler は1回5秒ほどかかる。必要なときだけ、かつ2分に1回までに制限する。
    /// （macOS 26 では OS 自体が noise を返さない場面が多く、その場合は取得を諦めて
    ///   RSSI・リンクレート・第一ホップ遅延で判定する）
    static func refreshNoiseFallback() {
        if let at = fallbackAt, Date().timeIntervalSince(at) < 300 { return }   // まだ有効な値がある
        if let at = lastAttempt, Date().timeIntervalSince(at) < 120 { return }  // 直近に試して失敗した
        lastAttempt = Date()
        let out = NetProbe.run("/usr/sbin/system_profiler", ["SPAirPortDataType"], timeout: 10)
        for line in out.split(separator: "\n") where line.contains("Signal / Noise:") {
            // 例: "Signal / Noise: -71 dBm / -96 dBm"
            let nums = line.split(separator: "/").compactMap { part -> Int? in
                let t = part.replacingOccurrences(of: "dBm", with: "").trimmingCharacters(in: .whitespaces)
                return Int(t)
            }
            if let n = nums.last, n < 0 {
                fallbackNoise = n
                fallbackAt = Date()
            }
            break
        }
    }

    static func read() -> LinkInfo {
        var l = LinkInfo()
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { return l }
        l.rssi   = i.rssiValue()
        l.noise  = i.noiseMeasurement()
        if l.noise >= 0, let at = fallbackAt, Date().timeIntervalSince(at) < 300 {
            l.noise = fallbackNoise
        }
        l.txRate = i.transmitRate()
        l.ssid   = i.ssid()
        l.bssid  = i.bssid()
        l.phy    = phyName(i.activePHYMode())
        if let ch = i.wlanChannel() {
            l.channel = ch.channelNumber
            l.width   = widthMHz(ch.channelWidth)
            l.band    = bandOf(ch)
        }
        // rssi==0 かつ channel==0 は未アソシエート
        l.associated = l.channel != 0 && l.rssi != 0
        return l
    }

    static func phyName(_ m: CWPHYMode) -> String {
        switch m {
        case .mode11a: return "11a"; case .mode11b: return "11b"; case .mode11g: return "11g"
        case .mode11n: return "11n"; case .mode11ac: return "11ac"; case .mode11ax: return "11ax"
        default: return "-"
        }
    }

    static func widthMHz(_ w: CWChannelWidth) -> Int {
        switch w {
        case .width20MHz: return 20; case .width40MHz: return 40
        case .width80MHz: return 80; case .width160MHz: return 160
        default: return 0
        }
    }

    static func bandOf(_ ch: CWChannel) -> Int {
        switch ch.channelBand {
        case .band2GHz: return 2
        case .band5GHz: return 5
        case .band6GHz: return 6
        default: return ch.channelNumber <= 14 ? 2 : 5
        }
    }

    /// この PHY/幅/ストリーム数で理論上出せる概算リンクレート(Mbps)。
    /// 「電波は良いのにレートが低い」= 干渉/レート下げ を見抜くための基準値。
    static func expectedRate(phy: String, width: Int) -> Double {
        let w = width == 0 ? 20 : width
        switch phy {
        case "11ax": return Double(w) * 14.4   // 2ss 概算: 20MHz≈288, 40≈576, 80≈1200
        case "11ac": return Double(w) * 10.8
        case "11n":  return Double(w) * 7.2
        default:     return 54
        }
    }
}
