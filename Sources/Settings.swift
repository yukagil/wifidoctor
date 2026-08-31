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
        cleanUpTemporaryStores()   // 自分が前に作ったぶんを孤児にしない
        removeStale()              // 落ちて残ったぶん
        let name = testPrefix + UUID().uuidString
        store = UserDefaults(suiteName: name) ?? .standard
        temporaryName = name
        return name
    }

    /// 途中で落ちると後始末が走らないので、十分に古いものだけを消す。
    /// 「残っているもの全部」を消すと、同時に走っている別のテストのものを壊す。
    private static func removeStale(olderThan: TimeInterval = 600) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return
        }
        let now = Date()
        for f in files where f.hasPrefix(testPrefix) && f.hasSuffix(".plist") {
            let url = dir.appendingPathComponent(f)
            let at = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            guard now.timeIntervalSince(at) > olderThan else { continue }
            UserDefaults.standard.removePersistentDomain(forName: String(f.dropLast(6)))
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 自分が作ったぶんだけを片付ける。
    /// 起動時に他のぶんまで消すと、テストを2つ走らせたときに使用中のものを消す。
    /// 消し残りが無いことをファイルの数で確かめるのは、書き戻しと競合して当てにならない。
    @discardableResult
    static func cleanUpTemporaryStores() -> Bool {
        guard let name = temporaryName else { return false }
        store = .standard
        temporaryName = nil
        let d = UserDefaults.standard
        d.removePersistentDomain(forName: name)
        d.synchronize()
        let f = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: f)
        return true
    }

    /// 本物の設定を使っていないこと。書き換える側のテストはこれを確かめてから動く。
    static var isTemporary: Bool { store !== UserDefaults.standard }

    /// 窓の位置の保存名。テスト中は保存させない（利用者が調整したサイズを潰すため）。
    static func windowAutosaveName(_ base: String) -> String? {
        isTemporary ? nil : base
    }
}
