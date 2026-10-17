// Claude Account Switcher — a small native window over claude-swap (cswap).
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
let logPath = "\(home)/Library/Logs/claude-account-switcher.log"
let threshold = 85
let refreshSeconds: UInt64 = 60

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

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Divider()
            Group {
                switch model.phase {
                case .loading: Spacer(); ProgressView(); Spacer()
                case .needsClaude: NeedsClaudeView()
                case .needsSetup: SetupView()
                case .installing: InstallingView()
                case .ready: ReadyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 460, height: 580)
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

struct Header: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("Claude Account Switcher").font(.title2.bold())
                Text("Stays on whichever Claude account has the most usage left.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
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

struct NeedsClaudeView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "terminal").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Install Claude Code first").font(.title3.bold())
            Text("This app works with Claude Code. Install it, then come back.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Link("How to install", destination: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!)
                    .buttonStyle(.borderedProminent)
                Button("Check again") { Task { await model.refresh() } }
            }
            Spacer()
        }
        .padding(30)
    }
}

struct SetupView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Feature(icon: "person.2.fill", title: "Use all your subscriptions",
                    text: "Save each Claude account you pay for.")
            Feature(icon: "arrow.triangle.2.circlepath", title: "Switches on its own",
                    text: "When one reaches \(threshold)% of its limit, Claude moves to the account with the most left.")
            Feature(icon: "lock.fill", title: "Stays on your Mac",
                    text: "Logins are kept in your Mac's Keychain. Nothing is sent anywhere.")
            Spacer()
            ErrorText()
            Button { Task { await model.install() } } label: {
                Text("Set up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(28)
    }
}

struct Feature: View {
    let icon: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct InstallingView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(model.progress).foregroundStyle(.secondary)
            Text("This takes about a minute.").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct ReadyView: View {
    @EnvironmentObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Accounts").font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            if let email = model.unsavedSignedIn {
                HStack {
                    Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(Color.accentColor)
                    Text("Signed in as **\(email)**").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Save") { Task { await model.saveSignedIn() } }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                VStack(spacing: 10) {
                    if model.accounts.isEmpty {
                        Text("No accounts saved yet.").foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                    ForEach(model.accounts) { AccountRow(account: $0) }
                }
            }
            Button { model.startSignIn() } label: {
                Label("Add account", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.busy)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Switch automatically at \(threshold)% used", isOn: Binding(
                    get: { model.autoOn }, set: { v in Task { await model.setAuto(v) } }))
                Toggle("Show usage in the menu bar", isOn: Binding(
                    get: { model.menubarOn }, set: { v in Task { await model.setMenubar(v) } }))
            }
            .toggleStyle(.switch)

            ErrorText()
            HStack {
                Button("Open log") { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
                    .buttonStyle(.link)
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
            }
            .font(.callout)
        }
        .padding(20)
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: Model
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(account.email).font(.headline).lineLimit(1).truncationMode(.middle)
                if account.isActive {
                    Text("In use")
                        .font(.caption.bold())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.green.opacity(0.2), in: Capsule())
                        .foregroundStyle(.green)
                }
                Spacer()
                if account.needsSignIn && account.email == model.signedInEmail {
                    // Claude itself is still signed in as this account; just re-save it.
                    Button("Fix") { Task { await model.saveSignedIn(slot: account.number) } }
                } else if account.needsSignIn {
                    Button("Sign in again") { model.startSignIn(slot: account.number) }
                } else if !account.isActive {
                    Button("Use") { Task { await model.use(account) } }
                }
            }
            if account.needsSignIn {
                Label(account.email == model.signedInEmail
                      ? "Saved login is out of date. Click Fix to update it."
                      : "Signed out. Sign in again to keep using it.",
                      systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if let u = account.shownUsage {
                UsageBar(label: "5-hour", window: u.fiveHour)
                UsageBar(label: "Weekly", window: u.sevenDay)
            } else {
                Text("Usage not available yet.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(account.isActive ? Color.green.opacity(0.5) : Color.secondary.opacity(0.2)))
        .contextMenu {
            Button("Remove account", role: .destructive) { Task { await model.remove(account) } }
        }
    }
}

struct UsageBar: View {
    let label: String
    let window: UsageWindow?

    var color: Color {
        let p = window?.pct ?? 0
        return p < 60 ? .green : p < Double(threshold) ? .orange : .red
    }

    var resets: String {
        guard let s = window?.resetsAt, let d = ISO8601DateFormatter().date(from: s) else { return "" }
        return "resets " + RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            ProgressView(value: min((window?.pct ?? 0) / 100, 1)).tint(color)
            Text(window.map { "\(Int($0.pct))%" } ?? "–").font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
            Text(resets).font(.caption2).foregroundStyle(.tertiary).frame(width: 88, alignment: .leading)
        }
    }
}

struct SignInSheet: View {
    @EnvironmentObject var model: Model
    @State private var code = ""

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Sign in with your browser").font(.title3.bold())
            Text("A browser tab just opened. Sign in with the Claude account you want to add.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("If the page shows a code, paste it here:").font(.callout)
                HStack {
                    TextField("Code", text: $code).textFieldStyle(.roundedBorder)
                    Button("Continue") { model.submitCode(code) }.disabled(code.isEmpty)
                }
            }
            Button("Cancel", role: .cancel) { model.cancelSignIn() }
        }
        .padding(26)
        .frame(width: 400)
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
        Window("Claude Account Switcher", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}
