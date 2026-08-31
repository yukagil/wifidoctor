import Foundation

/// 設定の置き場所。
///
/// 記録ファイルと同じで、テストが本物に触れられる構造そのものが誤り。
/// 一度、保持期間のテストが実際の記録を1日ぶん消している。
/// 同じことが呼び名（`apNames`）や窓の位置でも起こりうるので、入口で差し替える。
enum Settings {
    private(set) static var store: UserDefaults = .standard

    /// 動作確認用の空の置き場所へ切り替える。テストの最初に必ず呼ぶ。
    @discardableResult
    static func useTemporaryStore() -> String {
        let name = "WiFiDoctorTest-\(UUID().uuidString)"
        store = UserDefaults(suiteName: name) ?? .standard
        return name
    }

    /// 本物の設定を使っていないこと。書き換える側のテストはこれを確かめてから動く。
    static var isTemporary: Bool { store !== UserDefaults.standard }

    /// 窓の位置の保存名。テスト中は保存させない（利用者が調整したサイズを潰すため）。
    static func windowAutosaveName(_ base: String) -> String? {
        isTemporary ? nil : base
    }
}
