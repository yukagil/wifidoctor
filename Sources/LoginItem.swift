import Foundation
import ServiceManagement

/// ログイン時の自動起動。
/// SMAppService（システム設定 > ログイン項目 に出る正規の方法）を第一候補にし、
/// アドホック署名などで登録が拒否された場合に LaunchAgent へ退避する。
enum LoginItem {

    private static let agentID = "dev.yukagil.wifidoctor"
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentID).plist")
    }

    /// 起動対象は「今動いている自分自身」の .app。
    private static var appURL: URL {
        Bundle.main.bundleURL
    }
    private static var execPath: String {
        Bundle.main.executableURL?.path ?? appURL.path
    }

    /// SMAppService は register() が成功しても「ユーザー承認待ち」で止まることがある。
    /// その状態を黙って「有効」と表示すると、実際には起動せず嘘になるので区別する。
    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled:          return "有効"
        case .requiresApproval: return "承認待ち（システム設定 > 一般 > ログイン項目 で許可）"
        case .notRegistered:
            // 署名が無いと登録自体ができない。理由を出さないと、
            // 入れたのに効かない状態のまま放置される。
            return "登録できません（署名されたアプリでないと自動起動を設定できません）"
        case .notFound:         return "未登録"
        @unknown default:       return "不明"
        }
    }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// 有効化/無効化。成功可否と、どちらの方式になったかを返す。
    ///
    /// 登録に失敗しても LaunchAgent は書かない。
    /// 署名が無いと `SMAppService.register()` は必ず失敗するので、
    /// そこで plist を書くと「未署名のバイナリが自分で永続化する」形になり、
    /// 端末の監視から見て侵入後の常駐と区別が付かない。
    /// システム設定に出ないので、利用者も情シスも止められない。
    @discardableResult
    static func set(_ on: Bool) -> (ok: Bool, method: String) {
        if on {
            do {
                try SMAppService.mainApp.register()
                removeAgent()                       // 以前の版が書いたものを片付ける
                return (true, "ログイン項目")
            } catch {
                removeAgent()
                return (false, "")
            }
        } else {
            try? SMAppService.mainApp.unregister()
            removeAgent()
            return (true, "")
        }
    }

    private static func removeAgent() {
        try? FileManager.default.removeItem(at: agentURL)
    }

    /// ~/Applications 以外から動いていると、フォルダを動かした時点で自動起動が壊れる。
    static var isInStableLocation: Bool {
        let apps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path
        return appURL.path.hasPrefix(apps) || appURL.path.hasPrefix("/Applications")
    }
}
