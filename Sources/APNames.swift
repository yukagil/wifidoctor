import Foundation

/// アクセスポイントに人間が覚えられる名前を付ける。
/// `B14170` では会議室と結びつかず、レポートを情シスに渡しても伝わらない。
/// 一度付ければ以後ずっと効くので、移動が多いほど価値が出る。
enum APNames {
    private static let key = "apNames"

    static func all() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func name(for bssid: String?) -> String? {
        guard let b = bssid, let n = all()[b], !n.isEmpty else { return nil }
        return n
    }

    static func set(_ name: String, for bssid: String) {
        var d = all()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { d.removeValue(forKey: bssid) } else { d[bssid] = trimmed }
        UserDefaults.standard.set(d, forKey: key)
    }

    /// 区切りを外した16進の末尾3オクテット。
    /// `41:70` のような表記は時刻に見えて紛らわしいので使わない。
    static func shortID(_ bssid: String) -> String {
        bssid.split(separator: ":").suffix(3).joined().uppercased()
    }

    /// 画面とレポートに出す表記。名前があれば名前を優先する。
    static func label(for bssid: String?) -> String? {
        guard let b = bssid else { return nil }
        return name(for: b) ?? "AP \(shortID(b))"
    }
}
