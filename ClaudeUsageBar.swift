// Claude Usage Bar: a menu-bar readout of how much of your Claude plan's weekly and 5-hour
// limits you've used, for one Claude Code login or several side by side.
//
// How it gets the numbers: for each account it runs one tiny headless Claude Code turn
// (`claude -p hi --model haiku --output-format stream-json --verbose`) and reads the
// `rate_limit_event` Claude Code prints, the same figures its own /usage and statusLine show.
// It uses Claude Code's existing login for that account. It never reads, copies or refreshes
// tokens, cookies or the keychain itself.
//
// Accounts: ~/.config/claude-usage-bar/accounts.json (see accounts.example.json). With no file,
// it shows one account: your normal `claude` login.
//
// Build + install: ./build.sh   ·   Render the panel to PNGs: ClaudeUsageBar --snapshot <dir>

import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Accounts

struct Account: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let glyph: String       // menu-bar mark
    let symbol: String      // SF Symbol for the panel
    let tint: Color
    let letter: String
    let configDir: String?  // CLAUDE_CONFIG_DIR for this login; nil = the default ~/.claude login
    let tokenFile: String?  // a `claude setup-token` token file, for logins that have no config folder
    let desktopProfile: String?  // the desktop app's --user-data-dir for this account; nil = its default profile
    var hasDesktopApp = true     // false hides the Open button (a login used only from the terminal)
    var group = ""               // the "Use X" hint only suggests an account from the same group
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let claudeAppBin = "/Applications/Claude.app/Contents/MacOS/Claude"
let configPath = ProcessInfo.processInfo.environment["CLAUDE_USAGE_BAR_CONFIG"] ?? "\(home)/.config/claude-usage-bar/accounts.json"
let (accounts, configProblem) = loadAccounts(configPath)
let lowPercent = 25.0
let autoRefreshMinutes = 30.0

func loadAccounts(_ path: String) -> ([Account], String?) {
    let fallback = [Account(id: "default", name: "Claude", subtitle: "claude login", glyph: "✳︎", symbol: "sparkle",
                            tint: .orange, letter: "C", configDir: nil, tokenFile: nil, desktopProfile: nil)]
    guard let data = FileManager.default.contents(atPath: path) else { return (fallback, nil) }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = json["accounts"] as? [[String: Any]], !rows.isEmpty else {
        return (fallback, "Can't read \(path), so only your default login is shown.")
    }
    let tints: [String: Color] = ["red": .red, "orange": .orange, "yellow": .yellow, "green": .green, "mint": .mint,
                                  "teal": .teal, "cyan": .cyan, "blue": .blue, "indigo": .indigo, "purple": .purple,
                                  "pink": .pink, "brown": .brown, "gray": .gray]
    let defaultDir = "\(home)/.claude"
    var list: [Account] = [], unusable: [String] = []
    for (i, row) in rows.enumerated() {
        func text(_ key: String) -> String? { (row[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        guard let name = text("name") else { unusable.append("entry \(i + 1) (no name)"); continue }
        let dir = text("config_dir").map { NSString(string: $0).expandingTildeInPath }
        list.append(Account(id: "\(i)", name: name, subtitle: text("subtitle") ?? "",
                            glyph: text("glyph") ?? String(name.prefix(1)), symbol: text("symbol") ?? "circle.fill",
                            tint: tints[text("tint") ?? ""] ?? .gray, letter: String(name.prefix(1)).uppercased(),
                            configDir: dir == defaultDir ? nil : dir,   // naming ~/.claude explicitly would point at a different keychain login
                            tokenFile: text("token_file").map { NSString(string: $0).expandingTildeInPath },
                            desktopProfile: text("desktop_profile").map { NSString(string: $0).expandingTildeInPath },
                            hasDesktopApp: row["desktop_app"] as? Bool ?? true, group: text("group") ?? ""))
    }
    return (list.isEmpty ? fallback : list,
            unusable.isEmpty ? nil : "Skipped in \(path): \(unusable.joined(separator: ", ")).")
}

// MARK: - Usage readings

struct Limit {
    let left: Double      // % left, 0–100
    let resetsAt: Date?   // nil when the window has already rolled over since the reading
}

struct Reading {
    let weekUsed: Double?
    let weekResets: Date?
    let fiveUsed: Double?
    let fiveResets: Date?
    let takenAt: Date

    /// A window whose reset time has passed is full again; Claude Code treats it the same way.
    private func limit(_ used: Double?, _ resets: Date?) -> Limit? {
        if let resets, resets <= Date() { return Limit(left: 100, resetsAt: nil) }
        return used.map { Limit(left: max(0, 100 - $0), resetsAt: resets) }
    }
    var week: Limit? { limit(weekUsed, weekResets) }
    var fiveHour: Limit? { limit(fiveUsed, fiveResets) }
    var usableNow: Double? { [week, fiveHour].compactMap { $0?.left }.min() }
    var binding: Limit? { [week, fiveHour].compactMap { $0 }.min { $0.left < $1.left } }
    var bindingName: String { (fiveHour?.left ?? 101) < (week?.left ?? 101) ? "5-hour" : "week" }
    var ageMinutes: Double { Date().timeIntervalSince(takenAt) / 60 }
}

/// Finds the Claude Code CLI. Apps started from Finder get a bare PATH, so look in the usual places,
/// then ask a login shell.
func findClaude() -> String? {
    let fm = FileManager.default
    for p in ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    where fm.isExecutableFile(atPath: p) { return p }
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
    sh.arguments = ["-lc", "command -v claude"]
    let pipe = Pipe()
    sh.standardOutput = pipe
    sh.standardError = FileHandle.nullDevice
    guard (try? sh.run()) != nil else { return nil }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    sh.waitUntilExit()
    return fm.isExecutableFile(atPath: out) ? out : nil
}

/// One headless turn on the account's login; returns its reading or why there isn't one.
func fetchReading(_ account: Account, claude: String) -> Result<Reading, FetchError> {
    let workDir = NSTemporaryDirectory() + "claude-usage-bar"   // empty folder: no project CLAUDE.md or settings load
    try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    var env = ProcessInfo.processInfo.environment
    // An API key or gateway would bill the turn to the API and report no plan limits.
    for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
              "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CONFIG_DIR"] { env.removeValue(forKey: k) }
    if let dir = account.configDir { env["CLAUDE_CONFIG_DIR"] = dir }
    if let file = account.tokenFile {
        guard let token = (try? String(contentsOfFile: file, encoding: .utf8))?
                .components(separatedBy: .whitespacesAndNewlines).joined(), !token.isEmpty else {
            return .failure(.message("Can't read the token file \(file)."))
        }
        env["CLAUDE_CODE_OAUTH_TOKEN"] = token   // handed to this one Claude Code run only, never stored
    }
    let bin = (claude as NSString).deletingLastPathComponent
    env["PATH"] = "\(bin):" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")

    let p = Process()
    p.executableURL = URL(fileURLWithPath: claude)
    p.arguments = ["-p", "hi", "--model", "haiku", "--setting-sources", "project", "--strict-mcp-config",
                   "--output-format", "stream-json", "--verbose", "--no-session-persistence"]
    p.environment = env
    p.currentDirectoryURL = URL(fileURLWithPath: workDir)
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return .failure(.message("Couldn't start Claude Code.")) }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()

    var windows: [String: Any]?
    var loggedOut = false, apiKey = false
    for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
        guard let ev = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        switch ev["type"] as? String {
        case "rate_limit_event":
            if let w = (ev["rate_limit_info"] as? [String: Any])?["unifiedWindows"] as? [String: Any] { windows = w }
        case "system":
            if let src = ev["apiKeySource"] as? String, src != "none" { apiKey = true }
        case "result":
            if (ev["api_error_status"] as? Int) == 401 { loggedOut = true }
            if let r = ev["result"] as? String, r.localizedCaseInsensitiveContains("not logged in") { loggedOut = true }
        case "assistant":
            if (ev["error"] as? String) == "authentication_failed" { loggedOut = true }
        default: break
        }
    }
    guard let windows else {
        if loggedOut {
            return .failure(.message(account.tokenFile != nil ? "The token was rejected. Make a new one with `claude setup-token`."
                : "Not logged in. Run `claude` and /login" + (account.configDir.map { " with CLAUDE_CONFIG_DIR=\($0)" } ?? "") + "."))
        }
        if apiKey { return .failure(.message("This login uses an API key, which has no plan limits to show.")) }
        if p.terminationReason == .uncaughtSignal { return .failure(.message("Claude Code didn't answer within a minute.")) }
        return .failure(.message("No plan usage came back. Check this login is on a Pro or Max plan (`claude`, then /login), or update with `claude update`."))
    }
    func window(_ key: String) -> (Double?, Date?) {
        let w = windows[key] as? [String: Any]
        let used = (w?["utilization"] as? Double).map { ($0 * 1000).rounded() / 10 }   // Claude Code's own rounding
        let resets = (w?["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return (used, resets)
    }
    let (wu, wr) = window("seven_day"), (fu, fr) = window("five_hour")
    return .success(Reading(weekUsed: wu, weekResets: wr, fiveUsed: fu, fiveResets: fr, takenAt: Date()))
}

enum FetchError: Error { case message(String) }

// MARK: - Desktop app

/// PID of each account's running Claude desktop app, matched on its --user-data-dir.
func claudeProcesses() -> [String: pid_t] {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axo", "pid=,command="]
    let pipe = Pipe()
    ps.standardOutput = pipe
    guard (try? ps.run()) != nil else { return [:] }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ps.waitUntilExit()
    var found: [String: pid_t] = [:]
    for raw in out.split(separator: "\n") {
        let line = raw.drop { $0 == " " }
        guard let space = line.firstIndex(of: " "), let pid = pid_t(line[..<space]) else { continue }
        let cmd = line[line.index(after: space)...]
        guard cmd == claudeAppBin || cmd.hasPrefix(claudeAppBin + " ") else { continue }
        for a in accounts where a.hasDesktopApp {
            let matches = a.desktopProfile.map { cmd == "\(claudeAppBin) --user-data-dir=\($0)" || cmd.hasPrefix("\(claudeAppBin) --user-data-dir=\($0) ") }
                ?? !cmd.contains("--user-data-dir=")
            if matches { found[a.id] = pid }
        }
    }
    return found
}

/// Brings the account's desktop app forward, or starts it. Every instance registers as Claude.app,
/// so a running one is found by PID rather than by name.
func openDesktop(_ account: Account) {
    if let pid = claudeProcesses()[account.id], let app = NSRunningApplication(processIdentifier: pid) {
        app.activate()
        return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = account.desktopProfile.map { ["-n", "-a", "Claude", "--args", "--user-data-dir=\($0)"] } ?? ["-a", "Claude"]
    try? p.run()
}

// MARK: - Model

final class Model: ObservableObject {
    @Published var readings: [String: Reading] = [:]
    @Published var problems: [String: String] = [:]
    @Published var running: [String: pid_t] = [:]
    @Published var refreshing = false
    @Published var lastAttempt: Date?

    func reloadRunning() { running = claudeProcesses() }

    /// Fetches every account at once (one tiny Haiku turn each). A failed fetch keeps the last good
    /// reading on screen, with its age, and shows why the new one failed.
    func refreshNow(then done: (() -> Void)? = nil) {
        guard !refreshing else { return }
        refreshing = true
        lastAttempt = Date()
        DispatchQueue.global().async {
            let claude = findClaude()
            var results: [String: Result<Reading, FetchError>] = [:]
            let lock = NSLock(), group = DispatchGroup()
            for a in accounts {
                group.enter()
                DispatchQueue.global().async {
                    let r: Result<Reading, FetchError> = claude.map { fetchReading(a, claude: $0) }
                        ?? .failure(.message("Claude Code isn't installed. Get it at claude.com/claude-code."))
                    lock.lock(); results[a.id] = r; lock.unlock()
                    group.leave()
                }
            }
            group.wait()
            DispatchQueue.main.async {
                for (id, r) in results {
                    switch r {
                    case .success(let reading): self.readings[id] = reading; self.problems[id] = nil
                    case .failure(.message(let m)): self.problems[id] = m
                    }
                }
                self.refreshing = false
                self.reloadRunning()
                done?()
            }
        }
    }

    var hint: String? {
        let usable = accounts.compactMap { a in readings[a.id].flatMap { r in r.usableNow.map { (a, $0, r) } } }
        guard let worst = usable.min(by: { $0.1 < $1.1 }),
              let best = usable.filter({ $0.0.group == worst.0.group }).max(by: { $0.1 < $1.1 }),
              worst.1 < 10, best.1 >= 10, worst.0.id != best.0.id else { return nil }
        return "Use \(best.0.name) · \(worst.0.name) is back \(resetText(worst.2.binding?.resetsAt))"
    }
}

// MARK: - Reset notifications

func scheduleResetNotifications(_ model: Model) {
    let center = UNUserNotificationCenter.current()
    let ids = accounts.flatMap { a in ["week", "five"].map { "reset.\(a.id).\($0)" } }
    guard UserDefaults.standard.object(forKey: "notify.resets") as? Bool ?? true else {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        return
    }
    for a in accounts {
        let r = model.readings[a.id]
        for (key, label, limit) in [("week", "Weekly", r?.week), ("five", "5-hour", r?.fiveHour)] {
            let id = "reset.\(a.id).\(key)"
            guard let limit, limit.left < lowPercent, let at = limit.resetsAt, at > Date() else {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = "\(a.name) is back"
            content.body = "\(label) limit has reset, so \(a.name) has its full usage again."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: at.timeIntervalSinceNow + 60, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}

// MARK: - Formatting

func tone(left: Double) -> Color { left <= 10 ? .red : left <= 25 ? .orange : .blue }
func showUsed() -> Bool { (UserDefaults.standard.string(forKey: "display.mode") ?? "used") == "used" }
func shown(_ left: Double) -> Double { showUsed() ? 100 - left : left }
func modeWord() -> String { showUsed() ? "used" : "left" }
func percent(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "–" }

func resetText(_ date: Date?) -> String {
    guard let date else { return "now" }
    let secs = Int(date.timeIntervalSinceNow)
    if secs < 24 * 3600 {
        let h = secs / 3600, m = (secs % 3600) / 60
        return h > 0 ? "in \(h)h \(m)m" : "in \(m)m"
    }
    let f = DateFormatter()
    f.dateFormat = "EEE HH:mm"
    return f.string(from: date)
}

func ageText(_ minutes: Double) -> String {
    minutes < 1 ? "updated just now"
        : minutes < 90 ? "updated \(Int(minutes)) min ago"
        : "updated \(Int((minutes / 60).rounded())) h ago"
}

func menuBarTitle(_ model: Model) -> NSAttributedString {
    let d = UserDefaults.standard
    let metric = d.string(forKey: "title.metric") ?? "now"
    let icons = (d.string(forKey: "title.style") ?? "icons") == "icons"
    let parts = accounts.filter { d.object(forKey: "show.\($0.id)") as? Bool ?? true }.map { a -> String in
        let r = model.readings[a.id]
        let v = metric == "week" ? r?.week?.left : metric == "five" ? r?.fiveHour?.left : r?.usableNow
        return "\(icons ? a.glyph : a.letter) \(percent(v.map(shown)))"
    }
    return NSAttributedString(
        string: parts.isEmpty ? "Claude" : parts.joined(separator: "   "),
        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)])
}

// MARK: - Panel

struct LimitRow: View {
    let label: String
    let limit: Limit
    let showReset: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                Spacer(minLength: 2)
                Text(percent(shown(limit.left)) + (showReset ? " · \(resetText(limit.resetsAt))" : ""))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tone(left: limit.left))
                        .frame(width: shown(limit.left) > 0 ? max(4, g.size.width * shown(limit.left) / 100) : 0)
                }
            }
            .frame(height: 4)
        }
    }
}

struct AccountCard: View {
    let account: Account
    @ObservedObject var model: Model
    let showFiveHour: Bool
    let showResets: Bool
    let onOpen: () -> Void

    var body: some View {
        let reading = model.readings[account.id]
        let problem = model.problems[account.id]
        let running = model.running[account.id] != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: account.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(account.tint)
                    .frame(width: 16)
                Text(account.name).font(.system(size: 12, weight: .semibold))
                if running { Circle().fill(.green).frame(width: 5, height: 5).help("Desktop app is open") }
                if !account.subtitle.isEmpty {
                    Text(account.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if account.hasDesktopApp { Button(action: onOpen) { Image(systemName: "arrow.up.forward.app").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(running ? "Switch to \(account.name)'s Claude app" : "Open \(account.name)'s Claude app") }
                if let r = reading, let now = r.usableNow {
                    Text(percent(shown(now)))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(now <= 25 ? tone(left: now) : Color.primary)
                        .help("\(modeWord()) · \(r.bindingName)")
                }
            }
            if let r = reading {
                HStack(spacing: 12) {
                    if let w = r.week { LimitRow(label: "Week", limit: w, showReset: showResets) }
                    if showFiveHour, let f = r.fiveHour { LimitRow(label: "5-hour", limit: f, showReset: showResets) }
                }
            } else if problem == nil {
                Text(model.refreshing ? "Checking…" : "No reading yet").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct StoredToggle: View {
    @AppStorage private var on: Bool
    init(_ key: String) { _on = AppStorage(wrappedValue: true, key) }
    var body: some View { Toggle("", isOn: $on) }
}

struct SettingsPanel: View {
    @AppStorage("title.metric") private var metric = "now"
    @AppStorage("title.style") private var style = "icons"
    @AppStorage("display.mode") private var displayMode = "used"
    @AppStorage("panel.fiveHour") private var showFiveHour = true
    @AppStorage("panel.resets") private var showResets = true
    @AppStorage("notify.resets") private var notifyResets = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Numbers") {
                row("Show as") {
                    Picker("", selection: $displayMode) {
                        Text("Used").tag("used")
                        Text("Left").tag("left")
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Text("“Used” matches Claude's own usage screen.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            section("Menu bar") {
                ForEach(accounts) { a in row(a.name) { StoredToggle("show.\(a.id)") } }
                row("Number") {
                    Picker("", selection: $metric) {
                        Text("Tightest limit").tag("now")
                        Text("Weekly").tag("week")
                        Text("5-hour").tag("five")
                    }
                    .fixedSize()
                }
                row("Mark") {
                    Picker("", selection: $style) {
                        Text(accounts.map(\.glyph).joined(separator: " ")).tag("icons")
                        Text(accounts.map(\.letter).joined(separator: " ")).tag("letters")
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Text("“Tightest limit” is whichever of the weekly and 5-hour limits is closer to running out.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            section("Panel") {
                row("5-hour limit") { Toggle("", isOn: $showFiveHour) }
                row("Reset times") { Toggle("", isOn: $showResets) }
            }
            section("App") {
                row("Notify when a limit resets") { Toggle("", isOn: $notifyResets) }
                row("Open at login") {
                    Toggle("", isOn: $openAtLogin)
                        .onChange(of: openAtLogin) { _, on in
                            try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                }
                Text("Accounts: \(configPath.replacingOccurrences(of: home, with: "~"))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Quit Claude Usage Bar") { NSApp.terminate(nil) }
            }
        }
        .toggleStyle(.switch)
        .labelsHidden()
        .controlSize(.small)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            control()
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: Model
    @AppStorage("panel.fiveHour") private var showFiveHour = true
    @AppStorage("panel.resets") private var showResets = true
    @AppStorage("display.mode") private var displayMode = "used"
    @State private var showSettings: Bool
    let onOpen: (Account) -> Void

    init(model: Model, showSettings: Bool = false, onOpen: @escaping (Account) -> Void) {
        self.model = model
        self.onOpen = onOpen
        _showSettings = State(initialValue: showSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(showSettings ? "Settings" : "Claude usage").font(.system(size: 13, weight: .semibold))
                if !showSettings, let oldest = model.readings.values.map(\.ageMinutes).max() {
                    Text("\(ageText(oldest)) · % \(modeWord())").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if !showSettings {
                    if model.refreshing {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Button { model.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Get fresh numbers now")
                    }
                }
                Button { showSettings.toggle() } label: {
                    Image(systemName: showSettings ? "chevron.backward" : "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help(showSettings ? "Back" : "Choose what's shown")
            }
            if showSettings {
                SettingsPanel()
            } else {
                if let problem = configProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                }
                if let hint = model.hint {
                    Label(hint, systemImage: "arrow.right.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                ForEach(accounts) { a in
                    AccountCard(account: a, model: model, showFiveHour: showFiveHour, showResets: showResets) { onOpen(a) }
                }
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = Model()
    let popover = NSPopover()
    var item: NSStatusItem!
    var timer: Timer?
    var outsideClicks: Any?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        let host = NSHostingController(rootView: PanelView(model: model) { [weak self] account in
            self?.popover.performClose(nil)
            openDesktop(account)
        })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        if UserDefaults.standard.object(forKey: "notify.resets") as? Bool ?? true {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        model.$readings.receive(on: RunLoop.main).sink { [weak self] _ in self?.readingsChanged() }.store(in: &bag)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        model.refreshNow()
        // Re-check every minute: redraws countdowns and fetches again once the last try is old enough.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    func tick() {
        if let last = model.lastAttempt, Date().timeIntervalSince(last) / 60 >= autoRefreshMinutes { model.refreshNow() }
        readingsChanged()
    }

    func readingsChanged() {
        item.button?.attributedTitle = menuBarTitle(model)
        scheduleResetNotifications(model)
    }

    @objc func settingsChanged() { readingsChanged() }

    @objc func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.reloadRunning()
            if let last = model.lastAttempt, Date().timeIntervalSince(last) / 60 > 10 { model.refreshNow() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            // An accessory app often isn't active, so .transient alone misses clicks in other apps.
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let m = outsideClicks { NSEvent.removeMonitor(m) }
        outsideClicks = nil
    }
}

/// Fetches live numbers, then renders the panel and settings (dark appearance) to PNGs.
func snapshot(to dir: String) {
    let model = Model()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { model.refreshNow { done.signal() } }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    for (name, settings) in [("panel", false), ("settings", true)] {
        let view = NSHostingView(rootView: PanelView(model: model, showSettings: settings) { _ in }
            .background(Color(white: 0.16))
            .environment(\.colorScheme, .dark))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
    print(menuBarTitle(model).string)
    for a in accounts {
        let r = model.readings[a.id]
        print("\(a.name): week \(percent(r?.weekUsed)) used, 5-hour \(percent(r?.fiveUsed)) used\(model.problems[a.id].map { " — \($0)" } ?? "")")
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            app.setActivationPolicy(.prohibited)
            snapshot(to: args[i + 1])
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
