import Foundation

/// 設定の置き場所。
///
/// 記録ファイルと同じで、テストが本物に触れられる構造そのものが誤り。
/// 一度、保持期間のテストが実際の記録を1日ぶん消している。
/// 同じことが呼び名（`apNames`）や窓の位置でも起こりうるので、入口で差し替える。
enum Settings {
    private(set) static var store: UserDefaults = .standard

    private static let testPrefix = "WiFiDoctorTest-"
    private static var temporaryName: String?

    /// 動作確認用の空の置き場所へ切り替える。テストの最初に必ず呼ぶ。
    /// 使い終わったら消す。消さないと ~/Library/Preferences に溜まり続け、
    /// しかも README が案内する消し方では消えない。
    @discardableResult
    static func useTemporaryStore() -> String {
        cleanUpTemporaryStores()
        let name = testPrefix + UUID().uuidString
        store = UserDefaults(suiteName: name) ?? .standard
        temporaryName = name
        return name
    }

    /// 今回ぶんと、前回までの残骸をまとめて片付ける。
    static func cleanUpTemporaryStores() {
        let d = UserDefaults.standard
        if let name = temporaryName {
            d.removePersistentDomain(forName: name)
            temporaryName = nil
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return
        }
        for f in files where f.hasPrefix(testPrefix) && f.hasSuffix(".plist") {
            d.removePersistentDomain(forName: String(f.dropLast(6)))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    /// 本物の設定を使っていないこと。書き換える側のテストはこれを確かめてから動く。
    static var isTemporary: Bool { store !== UserDefaults.standard }

    /// 窓の位置の保存名。テスト中は保存させない（利用者が調整したサイズを潰すため）。
    static func windowAutosaveName(_ base: String) -> String? {
        isTemporary ? nil : base
    }
}
