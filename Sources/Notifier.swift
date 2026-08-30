import Foundation
import UserNotifications
import AppKit

/// 劣化の通知。うるさいと必ず切られるので、抑制を強めにかける:
///  - 同じ状態が connectedRuns 回続いて初めて出す(瞬間的なスパイクは無視)
///  - 同じ原因は cooldown 秒に1回まで
///  - 回復したときだけ「復旧」を1回出す
final class Notifier {
    var enabled = true
    /// 同じ原因を再通知するまでの間隔。短いと単に鬱陶しくなる。
    private let cooldown: TimeInterval = 900
    /// 同じ状態がこれだけ続いたら通知する。
    /// 計測間隔が状況で変わるようになったので、回数ではなく時間で判断する。
    private let requiredDuration: TimeInterval = 30
    /// テスト用の時計。
    var now: () -> Date = { Date() }

    private var lastSentAt: [Verdict: Date] = [:]
    private var runVerdict: Verdict = .ok
    private var runStartedAt: Date?
    private var notifiedProblem: Verdict?
    private var useUNC = false
    /// テスト時に実際の通知を出さずに検証するための差し替え口。
    var deliver: ((String, String) -> Void)?

    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async { self.useUNC = ok }
        }
    }

    /// - Parameter actionable: 利用者が自分で改善できる状態かどうか。
    ///   回線側の問題など「知らせても打つ手がない」ものは通知しない。
    ///   通知は行動を促すためのものなので、行動できないなら出す意味がない。
    func observe(verdict: Verdict, score: Int, actionable: Bool, detail: String) {
        guard enabled else { return }
        let t = now()
        if verdict != runVerdict { runVerdict = verdict; runStartedAt = t }
        let sustained = t.timeIntervalSince(runStartedAt ?? t)

        if verdict.isProblem {
            guard actionable else { return }
            guard sustained >= requiredDuration else { return }
            if let last = lastSentAt[verdict], t.timeIntervalSince(last) < cooldown { return }
            lastSentAt[verdict] = t
            notifiedProblem = verdict
            send(title: "Wi-Fi \(verdict.label)（\(score)点）", body: detail)
        } else if verdict == .ok, let was = notifiedProblem, sustained >= requiredDuration {
            notifiedProblem = nil
            send(title: "Wi-Fi 復旧（\(score)点）", body: "「\(was.label)」は解消しました。")
        }
    }

    private func send(title: String, body: String) {
        if let deliver { deliver(title, body); return }
        if useUNC {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        } else {
            // 通知の許可が取れない環境向けのフォールバック
            let esc: (String) -> String = { $0.replacingOccurrences(of: "\"", with: "'") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
            try? p.run()
        }
    }
}
