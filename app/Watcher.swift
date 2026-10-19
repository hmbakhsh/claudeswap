// Background mode (`switcher --watch`), run by the auto-switch LaunchAgent.
// Runs `cswap auto --json` as a child and turns its events into notifications:
// a switch happened, every account is past the threshold, or an account needs signing in again.
import AppKit
import UserNotifications

let signInCheckSeconds: TimeInterval = 300
let signInNotifiedKey = "signInNotified"

enum Watcher {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = WatcherDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class WatcherDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var child: Process?
    private var buffer = Data()
    private var threshold = Double(defaultThreshold)
    private var allHighNotified = false
    private var exhaustedNotified = false
    private var timer: Timer?
    private var updateTimer: Timer?
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // launchd stops us with SIGTERM; take cswap down with us.
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { [weak self] in
            self?.child?.terminate()
            exit(0)
        }
        sigterm?.resume()

        // `switcher --watch --test-notify`: check notifications work on this Mac, then quit.
        if CommandLine.arguments.contains("--test-notify") {
            notify("ClaudeSwap notifications are on", "You'll hear from it when it switches accounts")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            return
        }
        startAuto()
        Task { await checkSignIns() }
        timer = Timer.scheduledTimer(withTimeInterval: signInCheckSeconds, repeats: true) { [weak self] _ in
            Task { await self?.checkSignIns() }
        }
        Task { await update() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateCheckSeconds, repeats: true) { [weak self] _ in
            Task { await self?.update() }
        }
    }

    /// Installs a new version quietly. Skipped while the app is open: it updates itself, and brew would quit it.
    /// Afterwards we exit and launchd's KeepAlive starts the new notifier.
    private func update() async {
        guard let v = await Updater.newer(),
              NSRunningApplication.runningApplications(withBundleIdentifier: mainAppID).isEmpty else { return }
        guard await Shell.run(Updater.command(reopen: false)).code == 0 else { return }
        notify("ClaudeSwap updated to \(v)", "Nothing to do on your end")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.child?.terminate()
            exit(0)
        }
    }

    private func startAuto() {
        Shell.log("watcher: starting cswap auto")
        let p = Shell.process("exec cswap auto --json")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Shell.logHandle()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        // launchd's KeepAlive restarts us (and so cswap) if it ever exits.
        p.terminationHandler = { p in
            Shell.log("watcher: cswap auto exited (\(p.terminationStatus))")
            exit(p.terminationStatus == 0 ? 1 : p.terminationStatus)
        }
        do { try p.run() } catch {
            Shell.log("watcher: couldn't start cswap auto: \(error)")
            exit(1)
        }
        child = p
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(event, raw: String(decoding: line, as: UTF8.self))
            }
        }
    }

    private func handle(_ e: [String: Any], raw: String) {
        let kind = e["event"] as? String ?? ""
        // Polls and quiet ticks arrive every minute; only log what's worth reading later.
        if !["poll", "no-switch", "sleep"].contains(kind) { Shell.log("auto: \(raw)") }

        switch kind {
        case "poll":
            if let t = e["threshold"] as? Double { threshold = t }
            let windows = (e["windowsPct"] as? [String: [String: Any]]) ?? [:]
            let peaks = windows.values.map { $0.values.compactMap { $0 as? Double }.max() ?? 0 }
            let allHigh = !peaks.isEmpty && peaks.allSatisfy { $0 >= threshold }
            if !allHigh {
                allHighNotified = false
                exhaustedNotified = false
            } else if !allHighNotified {
                allHighNotified = true
                Task { await notifyAllHigh() }
            }
        case "switch" where (e["dryRun"] as? Bool) != true:
            let from = ((e["from"] as? [String: Any])?["email"] as? String).map(displayName)
            let to = ((e["to"] as? [String: Any])?["email"] as? String).map(displayName) ?? "another account"
            let why: String
            switch (e["trigger"] as? String, from) {
            case ("proactive", let f?): why = "\(f) reached \(Int(threshold))% of its limit"
            case ("at-limit", let f?): why = "\(f) hit its usage limit"
            case ("failover", let f?): why = "\(f) stopped working"
            default: why = "It has the most usage left"
            }
            notify("Switched to \(to)", why)
        case "all-exhausted" where !exhaustedNotified:
            exhaustedNotified = true
            allHighNotified = true
            let back = (e["earliestResetAt"] as? String).flatMap(parseDate).map { "Usage comes back \(relative($0))" }
            notify("All accounts are out of usage", back ?? "Usage comes back when a limit resets")
        default:
            break
        }
    }

    private func notifyAllHigh() async {
        let accounts = await loadAccounts()
        let high = allAccountsHigh(accounts, threshold: Int(threshold))
        let body = high?.resetAt.map { d in "Usage frees up on \(high?.account ?? "an account") \(relative(d))" }
        notify("All accounts are above \(Int(threshold))%", body ?? "Claude will keep using the account with the most left")
    }

    /// Notifies once per account when its saved login stops working, and again only after it's fixed and breaks again.
    private func checkSignIns() async {
        let accounts = await loadAccounts()
        guard !accounts.isEmpty else { return }
        let d = UserDefaults.standard
        var notified = Set(d.stringArray(forKey: signInNotifiedKey) ?? [])
        for a in accounts where a.needsSignIn && !notified.contains(a.email) {
            notify("\(displayName(a.email)) needs signing in again", "Open ClaudeSwap and click Sign In… to keep using it")
            notified.insert(a.email)
        }
        notified = notified.filter { email in accounts.contains { $0.email == email && $0.needsSignIn } }
        d.set(Array(notified), forKey: signInNotifiedKey)
    }

    private func loadAccounts() async -> [Account] {
        let r = await Shell.run("cswap list --json", quiet: true)
        return (try? JSONDecoder().decode(AccountList.self, from: Data(r.out.utf8)))?.accounts ?? []
    }

    private func notify(_ title: String, _ body: String) {
        Shell.log("notify: \(title) — \(body)")
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { error in
            if let error { Shell.log("notify failed: \(error)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        // Helper lives at ClaudeSwap.app/Contents/Helpers/…; open the app around it.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.open(app)
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
