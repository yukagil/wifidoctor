import Foundation
import CoreGraphics
import IOKit.ps

/// 電源の状態。バッテリー駆動中は計測を控えめにする。
/// ノートPCで一日中動かす前提なので、常時同じ頻度で叩くのは無駄が大きい。
enum PowerState {
    /// 画面が消えているか。
    ///
    /// 蓋を閉じていても macOS は15〜18分おきに短時間だけ起きる（dark wake / Power Nap）。
    /// そのタイミングでタイマーが発火すると、Wi-Fiが復帰しきる前の状態を
    /// 「未接続」として記録してしまい、平均スコアも帯グラフも汚れる。
    /// しかも低電力状態＋メンテナンス通信中の値なので、そもそも代表性がない。
    ///
    /// 外部ディスプレイを繋いだクラムシェル運用では主ディスプレイが生きているため、
    /// 正しく「使用中」と判定される。
    static func displayAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    static func onBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let state = d[kIOPSPowerSourceStateKey] as? String
            else { continue }
            return state == kIOPSBatteryPowerValue
        }
        // 電源に関する情報が取れないのはデスクトップ機。控える理由がない。
        return false
    }
}
