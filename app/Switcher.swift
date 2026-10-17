// ClaudeSwap — a small native window over claude-swap (cswap).
// Lists accounts with live usage, adds accounts via browser sign-in, and turns
// auto-switching / the cswap menu bar icon on and off. All real work is cswap.
import AppKit
import SwiftUI

let home = FileManager.default.homeDirectoryForCurrentUser.path
// Finder-launched apps get a bare PATH; add where uv, cswap and claude live.
let shellPath = "\(home)/.local/bin:\(home)/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
let autoLabel = "dev.claude-swap.auto"
let autoPlist = "\(home)/Library/LaunchAgents/\(autoLabel).plist"
let menubarPlist = "\(home)/Library/LaunchAgents/com.cswap.menubar.plist"
let logPath = "\(home)/Library/Logs/claudeswap.log"
let threshold = 85
let refreshSeconds: UInt64 = 60
let isDemo = ProcessInfo.processInfo.environment["CAS_DEMO"] != nil

// MARK: - Shell

enum Shell {
    static func logHandle() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let h = FileHandle(forWritingAtPath: logPath)
        h?.seekToEndOfFile()
        return h
    }

    static func log(_ line: String) {
        logHandle()?.write("[\(Date())] \(line)\n".data(using: .utf8)!)
    }

    static func process(_ cmd: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = shellPath
        p.environment = env
        return p
    }

    /// Runs `cmd`; stdout is returned, stderr goes to the log. `input` is fed to stdin.
    @discardableResult
    static func run(_ cmd: String, input: String = "") async -> (code: Int32, out: String) {
        log("$ \(cmd)")
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = process(cmd)
                let out = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = logHandle()
                p.standardInput = inp
                do { try p.run() } catch {
                    log("failed to start: \(error)")
                    cont.resume(returning: (-1, ""))
                    return
                }
                inp.fileHandleForWriting.write(input.data(using: .utf8)!)
                try? inp.fileHandleForWriting.close()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    static func exists(_ tool: String) async -> Bool {
        await run("command -v \(tool)").code == 0
    }
}

// MARK: - cswap data

struct UsageWindow: Decodable {
    let pct: Double
    let resetsAt: String?
}

struct Usage: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
}

struct Account: Decodable, Identifiable {
    let number: Int
    let email: String
    let active: Bool?
    let usageStatus: String?
    let usage: Usage?
    let lastGoodUsage: Usage?
    let disabled: Bool?
    var id: Int { number }
    var isActive: Bool { active ?? false }
    var needsSignIn: Bool { ["relogin_required", "token_expired"].contains(usageStatus ?? "") }
    var shownUsage: Usage? { usage ?? lastGoodUsage }
}

struct AccountList: Decodable {
    let accounts: [Account]
}

struct AuthStatus: Decodable {
    let loggedIn: Bool?
    let email: String?
}

// MARK: - Model

final class SignInSession: Identifiable {
    let id = UUID()
    let process: Process
    let input: Pipe
    let slot: Int?
    var cancelled = false
    init(process: Process, input: Pipe, slot: Int?) {
        self.process = process
        self.input = input
        self.slot = slot
    }
}

@MainActor
final class Model: ObservableObject {
    enum Phase { case loading, needsClaude, needsSetup, installing, ready }

    @Published var phase: Phase = .loading
    @Published var progress = ""
    @Published var accounts: [Account] = []
    @Published var signedInEmail: String?
    @Published var autoOn = false
    @Published var menubarOn = false
    @Published var busy = false
    @Published var error: String?
    @Published var signIn: SignInSession?
    private var checkedUpgrade = false

    var unsavedSignedIn: String? {
        guard let e = signedInEmail, !accounts.contains(where: { $0.email == e }) else { return nil }
        return e
    }

    func refresh() async {
        if isDemo { return loadDemo() }
        guard await Shell.exists("claude") else { phase = .needsClaude; return }
        guard await Shell.exists("cswap") else { phase = .needsSetup; return }
        if !checkedUpgrade {
            checkedUpgrade = true
            // Installs older than the menu bar service can't run this app's toggles.
            progress = "Updating claude-swap…"
            await Shell.run("cswap menubar --help 2>&1 | grep -q install-service || uv tool install --upgrade 'claude-swap[menubar]'")
        }
        let list = await Shell.run("cswap list --json")
        if let parsed = try? JSONDecoder().decode(AccountList.self, from: Data(list.out.utf8)) {
            accounts = parsed.accounts
        } else {
            error = "Couldn't read your accounts. Try Refresh."
        }
        let auth = await Shell.run("claude auth status --json")
        let status = try? JSONDecoder().decode(AuthStatus.self, from: Data(auth.out.utf8))
        signedInEmail = (status?.loggedIn ?? false) ? status?.email : nil
        autoOn = FileManager.default.fileExists(atPath: autoPlist)
        menubarOn = FileManager.default.fileExists(atPath: menubarPlist)
        phase = .ready
    }

    /// Sample data for README screenshots: `CAS_DEMO=1` (accounts) or `CAS_DEMO=setup` (welcome).
    private func loadDemo() {
        if ProcessInfo.processInfo.environment["CAS_DEMO"] == "setup" { phase = .needsSetup; return }
        func w(_ pct: Double, hours: Double) -> UsageWindow {
            UsageWindow(pct: pct, resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(hours * 3600)))
        }
        func a(_ n: Int, _ email: String, active: Bool, _ five: Double, _ week: Double, status: String = "ok") -> Account {
            Account(number: n, email: email, active: active, usageStatus: status,
                    usage: status == "ok" ? Usage(fiveHour: w(five, hours: 2.4), sevenDay: w(week, hours: 75)) : nil,
                    lastGoodUsage: nil, disabled: nil)
        }
        accounts = [
            a(1, "sam@studio.co", active: true, 38, 52),
            a(2, "sam.personal@gmail.com", active: false, 6, 21),
            a(3, "sam@sidegig.dev", active: false, 92, 71),
        ]
        autoOn = true
        menubarOn = true
        phase = .ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func install() async {
        phase = .installing
        error = nil
        if !(await Shell.exists("uv")) {
            progress = "Installing helper tools…"
            guard await Shell.run("curl -LsSf https://astral.sh/uv/install.sh | sh").code == 0 else {
                return installFailed()
            }
        }
        progress = "Installing claude-swap…"
        guard await Shell.run("uv tool install --upgrade 'claude-swap[menubar]'").code == 0 else {
            return installFailed()
        }
        progress = "Turning on auto-switching…"
        await Shell.run("cswap config set autoswitch.threshold \(threshold)")
        await setAuto(true)
        await setMenubar(true)
        await refresh()
    }

    private func installFailed() {
        phase = .needsSetup
        error = "Setup didn't finish. Check your internet and try again."
    }

    // Each step is a cswap command; "y" answers any overwrite confirmation.
    func act(_ cmd: String, failure: String) async {
        busy = true
        error = nil
        if await Shell.run(cmd, input: "y\n").code != 0 { error = failure }
        await refresh()
        busy = false
    }

    func saveSignedIn(slot: Int? = nil) async {
        let cmd = slot.map { "cswap add --slot \($0)" } ?? "cswap add"
        await act(cmd, failure: "Couldn't save that account.")
    }

    func use(_ a: Account) async { await act("cswap switch \(a.number)", failure: "Couldn't switch to \(a.email).") }
    func remove(_ a: Account) async { await act("cswap remove \(a.number)", failure: "Couldn't remove \(a.email).") }

    func startSignIn(slot: Int? = nil) {
        error = nil
        let p = Shell.process("claude auth login")
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = Shell.logHandle()
        p.standardError = Shell.logHandle()
        let session = SignInSession(process: p, input: input, slot: slot)
        p.terminationHandler = { proc in
            Task { @MainActor in await self.finishSignIn(session, code: proc.terminationStatus) }
        }
        do {
            try p.run()
            signIn = session
        } catch {
            self.error = "Couldn't start sign-in."
        }
    }

    func submitCode(_ code: String) {
        signIn?.input.fileHandleForWriting.write((code.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").data(using: .utf8)!)
    }

    func cancelSignIn() {
        signIn?.cancelled = true
        signIn?.process.terminate()
        signIn = nil
    }

    private func finishSignIn(_ s: SignInSession, code: Int32) async {
        if signIn === s { signIn = nil }
        guard !s.cancelled else { return }
        if code == 0 {
            await saveSignedIn(slot: s.slot)
        } else {
            error = "Sign-in didn't finish. Try again."
        }
    }

    func setAuto(_ on: Bool) async {
        let uid = getuid()
        await Shell.run("launchctl bootout gui/\(uid)/\(autoLabel)")
        if on {
            let cswap = (await Shell.run("command -v cswap")).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let plist: [String: Any] = [
                "Label": autoLabel,
                "ProgramArguments": [cswap, "auto"],
                "EnvironmentVariables": ["PATH": shellPath],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ThrottleInterval": 60,
                "StandardOutPath": "\(home)/Library/Logs/claude-swap-auto.log",
                "StandardErrorPath": "\(home)/Library/Logs/claude-swap-auto.log",
            ]
            try? FileManager.default.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
            let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            FileManager.default.createFile(atPath: autoPlist, contents: data)
            if await Shell.run("launchctl bootstrap gui/\(uid) '\(autoPlist)'").code != 0 {
                error = "Couldn't turn on auto-switching."
            }
        } else {
            try? FileManager.default.removeItem(atPath: autoPlist)
        }
        autoOn = FileManager.default.fileExists(atPath: autoPlist)
    }

    func setMenubar(_ on: Bool) async {
        busy = true
        defer { busy = false }
        // Older installs lack the menu bar extra; upgrading is a no-op when current.
        let cmd = on
            ? "uv tool install --upgrade 'claude-swap[menubar]' && cswap menubar --install-service"
            : "cswap menubar --uninstall-service"
        if await Shell.run(cmd).code != 0 {
            error = "Couldn't change the menu bar icon."
        }
        menubarOn = FileManager.default.fileExists(atPath: menubarPlist)
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var model: Model
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Group {
            switch model.phase {
            case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsClaude: NeedsClaudeView()
            case .needsSetup: SetupView()
            case .installing: InstallingView()
            case .ready: ReadyView()
            }
        }
        .frame(width: 480, height: 510)
        // Demo screenshots: render in the active (key-window) style even when focus is elsewhere.
        .environment(\.controlActiveState, isDemo ? .key : controlActiveState)
        .sheet(item: $model.signIn) { _ in SignInSheet() }
        .task {
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: refreshSeconds * 1_000_000_000)
                if model.phase == .ready, model.signIn == nil, !model.busy { await model.refresh() }
            }
        }
    }
}

struct AppIcon: View {
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
    }
}

struct ErrorText: View {
    @EnvironmentObject var model: Model
    var body: some View {
        if let e = model.error {
            Label(e, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

/// Centered welcome-style layout shared by the setup, installing and "needs Claude" screens.
struct Onboarding<Body: View, Footer: View>: View {
    let title: String
    @ViewBuilder let content: Body
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            AppIcon(size: 96)
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            content
                .padding(.top, 32)
                .padding(.horizontal, 48)
            Spacer(minLength: 24)
            VStack(spacing: 10) { footer }
                .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct NeedsClaudeView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Onboarding(title: "Install Claude Code First") {
            Text("ClaudeSwap works with Claude Code. Install it, then come back here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } footer: {
            Link(destination: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!) {
                Text("Get Claude Code").frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Check Again") { Task { await model.refresh() } }
                .buttonStyle(.link)
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Onboarding(title: "Welcome to ClaudeSwap") {
            VStack(alignment: .leading, spacing: 22) {
                Feature(icon: "person.2.fill", color: .blue, title: "All your subscriptions",
                        text: "Save each Claude account you pay for.")
                Feature(icon: "arrow.triangle.2.circlepath", color: .orange, title: "Switches on its own",
                        text: "At \(threshold)% of a limit, Claude moves to the account with the most left.")
                Feature(icon: "lock.fill", color: .green, title: "Private by design",
                        text: "Logins stay in your Mac's Keychain. Nothing is sent anywhere.")
            }
        } footer: {
            ErrorText()
            Button { Task { await model.install() } } label: {
                Text("Continue").frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Text("Setup takes about a minute.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Feature: View {
    let icon: String, color: Color, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(color)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct InstallingView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        Onboarding(title: "Setting Up…") {
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text(model.progress).foregroundStyle(.secondary)
            }
        } footer: {
            Text("This takes about a minute.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ReadyView: View {
    @EnvironmentObject var model: Model

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIcon(size: 40)
                Text("ClaudeSwap").font(.title3.weight(.semibold))
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            // The icon art has ~4pt of transparent margin; offset so the tile lines up at 20pt.
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .padding(.top, 6)

            Form {
                if let email = model.unsavedSignedIn {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(email).lineLimit(1).truncationMode(.middle)
                                Text("You're signed in to Claude with this account.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Save") { Task { await model.saveSignedIn() } }
                        }
                    }
                }

                Section {
                    if model.accounts.isEmpty {
                        Text("No accounts yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.accounts) { AccountRow(account: $0) }
                } header: {
                    // Grouped forms inset headers 10pt; pull it flush with the box outline.
                    Text("Accounts").padding(.leading, -10)
                } footer: {
                    HStack {
                        Button("Add Account…") { model.startSignIn() }
                            .disabled(model.busy)
                        Spacer()
                        Button { Task { await model.refresh() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh usage")
                    }
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 14) {
                SettingRow(title: "Switch automatically",
                           detail: "When an account reaches \(threshold)% of its 5-hour or weekly limit.",
                           isOn: Binding(get: { model.autoOn }, set: { v in Task { await model.setAuto(v) } }))
                SettingRow(title: "Show in menu bar",
                           detail: "See usage and switch accounts from the top of your screen.",
                           isOn: Binding(get: { model.menubarOn }, set: { v in Task { await model.setMenubar(v) } }))
                HStack {
                    ErrorText()
                    Spacer()
                    Button("Open Log") { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
}

struct SettingRow: View {
    let title: String, detail: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

struct Avatar: View {
    let email: String
    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .mint]

    var body: some View {
        let color = Self.palette[email.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.palette.count]
        Circle()
            .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .top, endPoint: .bottom))
            .overlay(
                Text(email.prefix(1).uppercased())
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .frame(width: 34, height: 34)
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: Model
    let account: Account

    private var canFix: Bool { account.needsSignIn && account.email == model.signedInEmail }

    var body: some View {
        HStack(spacing: 12) {
            Avatar(email: account.email)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(account.email).lineLimit(1).truncationMode(.middle)
                    if account.isActive {
                        Text("In Use")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.inUse)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.inUse.opacity(0.18), in: Capsule())
                    }
                }
                if account.needsSignIn {
                    Text(canFix ? "Saved login is out of date." : "Signed out.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let u = account.shownUsage {
                    HStack(spacing: 14) {
                        Meter(label: "5h", window: u.fiveHour)
                        Meter(label: "Week", window: u.sevenDay)
                    }
                } else {
                    Text("Usage not available yet").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Group {
                if canFix {
                    Button("Fix") { Task { await model.saveSignedIn(slot: account.number) } }
                } else if account.needsSignIn {
                    Button("Sign In…") { model.startSignIn(slot: account.number) }
                } else if !account.isActive {
                    Button("Use") { Task { await model.use(account) } }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Remove Account", role: .destructive) { Task { await model.remove(account) } }
        }
    }
}

extension Color {
    /// Readable green for text: system green in Dark Mode, a deeper green in Light Mode (≥4.5:1).
    static let inUse = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1)
            : NSColor(red: 0.10, green: 0.50, blue: 0.22, alpha: 1)
    })
}

struct Meter: View {
    let label: String
    let window: UsageWindow?

    private var pct: Double { window?.pct ?? 0 }
    private var color: Color { pct < 60 ? .green : pct < Double(threshold) ? .orange : .red }
    private var resets: String {
        guard let s = window?.resetsAt, let d = ISO8601DateFormatter().date(from: s) else { return "" }
        return "Resets " + RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 6) {
            Gauge(value: min(pct, 100), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(color)
                .frame(width: 64)
            Text("\(label) \(window.map { "\(Int($0.pct))%" } ?? "–")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(resets)
    }
}

struct SignInSheet: View {
    @EnvironmentObject var model: Model
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign In to Claude").font(.headline)
                    Text("Finish signing in with your browser, using the account you want to add.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for your browser…").font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("If the page shows a code, paste it here.").font(.caption).foregroundStyle(.secondary)
                TextField("Code", text: $code).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelSignIn() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { model.submitCode(code) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        Window("ClaudeSwap", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
