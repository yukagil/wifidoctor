import Foundation

/// 設定の読み書き口。
///
/// 実体は `UserDefaults` だが、テストのときだけメモリ上の置き場所に差し替える。
/// 記録ファイルと同じで、テストが本物に触れられる構造そのものが誤り。
/// 一度、保持期間のテストが実際の記録を1日ぶん消している。
protocol SettingsStore {
    func bool(forKey: String) -> Bool
    func object(forKey: String) -> Any?
    func dictionary(forKey: String) -> [String: Any]?
    func set(_ value: Any?, forKey: String)
    func removeObject(forKey: String)
}

extension UserDefaults: SettingsStore {}

/// テスト用。ファイルを作らないので、後始末も要らないし残骸も出ない。
/// （`UserDefaults(suiteName:)` を使っていたときは、消しても終了時に
///   書き戻されて ~/Library/Preferences に溜まり続けた）
final class MemorySettings: SettingsStore {
    private var values: [String: Any] = [:]
    func bool(forKey k: String) -> Bool { values[k] as? Bool ?? false }
    func object(forKey k: String) -> Any? { values[k] }
    func dictionary(forKey k: String) -> [String: Any]? { values[k] as? [String: Any] }
    func set(_ value: Any?, forKey k: String) { values[k] = value }
    func removeObject(forKey k: String) { values.removeValue(forKey: k) }
}

enum Settings {
    private(set) static var store: SettingsStore = UserDefaults.standard

    /// 動作確認用の置き場所へ切り替える。テストの最初に必ず呼ぶ。
    static func useTemporaryStore() {
        store = MemorySettings()
    }

    /// 本物の設定を使っていないこと。書き換える側のテストはこれを確かめてから動く。
    static var isTemporary: Bool { !(store is UserDefaults) }

    /// 窓の位置の保存名。テスト中は保存させない（利用者が調整したサイズを潰すため）。
    static func windowAutosaveName(_ base: String) -> String? {
        isTemporary ? nil : base
    }
}
