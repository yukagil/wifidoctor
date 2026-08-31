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
    /// 利用者が通知を拒否したか。拒否されているなら代替手段でも出さない。
    /// osascript 経由の通知は別アプリの権限で出るため、拒否した設定を素通りしてしまう。
    private var denied = false
    /// テスト時に実際の通知を出さずに検証するための差し替え口。
    var deliver: ((String, String) -> Void)?

    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async { self.useUNC = ok; self.denied = !ok }
        }
    }

    /// - Parameter actionable: 利用者が自分で改善できる状態かどうか。
    ///   回線側の問題など「知らせても打つ手がない」ものは通知しない。
    ///   通知は行動を促すためのものなので、行動できないなら出す意味がない。
    /// 通知に出すのは画面と同じ言い回しだけ。点数や dBm は前面に出さない。
    func observe(verdict: Verdict, score: Int, actionable: Bool) {
        _ = score
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
            // 通知はアプリを開かなくても届く唯一の画面。ここだけ専門語のままだと、
            // 画面用に用意した平易な言い回しが全部無駄になる。
            // 点数は前面に出さない方針（画面では段階だけを見せている）。
            // 通知は最も前面なので、ここだけ生の数値を出すのは筋が通らない。
            send(title: Phrase.headline(verdict), body: Phrase.notice(verdict))
        } else if verdict == .ok, let was = notifiedProblem, sustained >= requiredDuration {
            notifiedProblem = nil
            // 見出しは「Wi-Fiが混み合っています」のような文なので、
            // そのまま「〜は解消しました」に繋ぐと日本語が壊れる。
            send(title: "Wi-Fiが元に戻りました",
                 body: "\(was.plainCause)状態は解消しました。")
        }
    }

    private func send(title: String, body: String) {
        if let deliver { deliver(title, body); return }
        if useUNC {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        } else if !denied, Bundle.main.bundleIdentifier == nil {
            // 通知の仕組みが使えない開発時だけの代替手段。
            // 拒否された場合に使うと、別アプリの権限で出るため設定を素通りしてしまう。
            // AppleScript の文字列に入れるので、引用符と円記号の両方を落とす。
            let esc: (String) -> String = {
                $0.replacingOccurrences(of: "\\", with: "")
                    .replacingOccurrences(of: "\"", with: "'")
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
            try? p.run()
        }
    }
}
