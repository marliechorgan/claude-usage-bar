// Claude Usage Bar: a menu-bar readout of how much of your Claude plan's weekly and 5-hour
// limits you've used, for one Claude Code login or several side by side.
//
// How it gets the numbers: for each account it runs one tiny headless Claude Code turn
// (`claude -p hi --model haiku --output-format stream-json --verbose`) and reads the
// `rate_limit_event` Claude Code prints, the same figures its own /usage and statusLine show.
// It uses Claude Code's existing login for that account. It never reads, copies or refreshes
// tokens, cookies or the keychain itself. If another tool already keeps a reading for an account
// in a file (`usage_file`), the app reads that file too and shows whichever reading is newer, so
// it runs fewer turns of its own.
//
// Freshness: while the panel is open no reading is more than about 2 minutes old; while it is
// closed each account is checked when its newest reading passes 15 minutes. Each card says how old
// its own reading is.
//
// Accounts: ~/.config/claude-usage-bar/accounts.json (see accounts.example.json). With no file,
// it shows one account: your normal `claude` login.
//
// Build + install: ./build.sh   ·   Render the panel to PNGs: ClaudeUsageBar --snapshot <dir>
// Check the parsing and pace maths: ClaudeUsageBar --selftest

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
    var desktopLauncher: String? = nil  // an app that starts this account's desktop app; the Open button opens it
    var usageFile: String? = nil        // a file another tool keeps a reading in (statusLine cache shape)
    var roleID: String? = nil           // this account's id in the roles file (see RoleSource)
    var section: String? = nil          // the panel draws a divider where this changes; defaults to group
    var panelSection: String { section ?? group }
}

/// Where the role labels come from: a YAML-style file with a section of `key: id id …` lines, and
/// the label to show for each key. A label list gives one label per position in that key's list.
struct RoleSource {
    let file: String
    let section: String
    let labels: [String: [String]]
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let configPath = ProcessInfo.processInfo.environment["CLAUDE_USAGE_BAR_CONFIG"] ?? "\(home)/.config/claude-usage-bar/accounts.json"
let (accounts, configProblem) = loadAccounts(configPath)
let roleSource = loadRoleSource(configPath)
let lowPercent = 25.0
/// Oldest a reading may get before the app checks that account again: open panel, closed panel.
/// 2 minutes is what "live" needs while you look; 15 minutes keeps the menu-bar numbers within a
/// point or two on a weekly window while costing at most four tiny Haiku turns an hour per account.
let maxAgeOpen: TimeInterval = 120
let maxAgeClosed: TimeInterval = 15 * 60
let failedRetry: TimeInterval = 10 * 60   // after a failed check, wait this long before trying that account again
let weekWindow: TimeInterval = 7 * 24 * 3600
let fiveHourWindow: TimeInterval = 5 * 3600

func loadRoleSource(_ path: String) -> RoleSource? {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let roles = json["roles"] as? [String: Any], let file = roles["file"] as? String,
          let raw = roles["labels"] as? [String: Any] else { return nil }
    var labels: [String: [String]] = [:]
    for (k, v) in raw {
        if let s = v as? String { labels[k] = [s] } else if let l = v as? [String] { labels[k] = l }
    }
    return RoleSource(file: NSString(string: file).expandingTildeInPath,
                      section: roles["section"] as? String ?? "accounts", labels: labels)
}

/// Reads `key: a b c  # comment` lines from one top-level section of a YAML-style file. Only the
/// section's direct children count; values are split on spaces. Returns them in file order.
func parseRoleSection(_ text: String, section: String) -> [(key: String, ids: [String])] {
    var out: [(String, [String])] = []
    var inside = false
    var childIndent: Int?
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let indent = line.prefix { $0 == " " }.count
        if indent == 0 {
            if inside { break }
            inside = trimmed == "\(section):" || trimmed.hasPrefix("\(section): #") || trimmed.hasPrefix("\(section):#")
            continue
        }
        guard inside else { continue }
        if childIndent == nil { childIndent = indent }
        guard indent == childIndent, let colon = trimmed.firstIndex(of: ":") else { continue }
        let key = String(trimmed[..<colon])
        var value = String(trimmed[trimmed.index(after: colon)...])
        if let hash = value.range(of: " #") ?? (value.hasPrefix("#") ? value.range(of: "#") : nil) {
            value = String(value[..<hash.lowerBound])
        }
        let ids = value.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
        out.append((key, ids))
    }
    return out
}

/// The role labels for each account id, in the order the keys appear in the roles file.
func roleLabels(_ source: RoleSource, text: String, for list: [Account] = accounts) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for (key, ids) in parseRoleSection(text, section: source.section) {
        guard let labels = source.labels[key], !labels.isEmpty else { continue }
        for a in list {
            guard let rid = a.roleID, let pos = ids.firstIndex(of: rid) else { continue }
            let label = labels[min(pos, labels.count - 1)]
            if !label.isEmpty { result[a.id, default: []].append(label) }
        }
    }
    return result
}

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
                            hasDesktopApp: row["desktop_app"] as? Bool ?? true, group: text("group") ?? "",
                            desktopLauncher: text("desktop_launcher").map { NSString(string: $0).expandingTildeInPath },
                            usageFile: text("usage_file").map { NSString(string: $0).expandingTildeInPath },
                            roleID: text("role_id"), section: text("section")))
    }
    return (list.isEmpty ? fallback : list,
            unusable.isEmpty ? nil : "Skipped in \(path): \(unusable.joined(separator: ", ")).")
}

// MARK: - Usage readings

struct Limit {
    let left: Double      // % left, 0–100
    let resetsAt: Date?   // nil when the window has already rolled over since the reading
    var window: TimeInterval = weekWindow

    var used: Double { 100 - left }
    /// How far through its window the clock is, 0–1; nil when the reset time isn't known.
    func through(at now: Date = Date()) -> Double? {
        resetsAt.map { min(1, max(0, 1 - $0.timeIntervalSince(now) / window)) }
    }
    /// Percentage points used beyond (positive) or short of (negative) an even pace through the window.
    func paceGap(at now: Date = Date()) -> Double? { through(at: now).map { used - $0 * 100 } }
}

enum ReadingSource: Equatable {
    case check            // this app's own Claude Code turn
    case file(String)     // a usage_file another tool keeps
}

struct Reading {
    let weekUsed: Double?
    let weekResets: Date?
    let fiveUsed: Double?
    let fiveResets: Date?
    let takenAt: Date
    var source: ReadingSource = .check

    /// A window whose reset time has passed is full again; Claude Code treats it the same way.
    private func limit(_ used: Double?, _ resets: Date?, _ window: TimeInterval) -> Limit? {
        if let resets, resets <= Date() { return Limit(left: 100, resetsAt: nil, window: window) }
        return used.map { Limit(left: max(0, 100 - $0), resetsAt: resets, window: window) }
    }
    var week: Limit? { limit(weekUsed, weekResets, weekWindow) }
    var fiveHour: Limit? { limit(fiveUsed, fiveResets, fiveHourWindow) }
    var usableNow: Double? { [week, fiveHour].compactMap { $0?.left }.min() }
    var binding: Limit? { [week, fiveHour].compactMap { $0 }.min { $0.left < $1.left } }
    var bindingName: String { (fiveHour?.left ?? 101) < (week?.left ?? 101) ? "5-hour" : "week" }
    var ageMinutes: Double { Date().timeIntervalSince(takenAt) / 60 }
}

/// Reads a usage file in Claude Code's statusLine-cache shape:
/// {"seven_day_pct": 52.0, "seven_day_resets_at": "2030-01-05T15:00:00+00:00" (or epoch seconds),
///  "five_hour_pct": 3, "five_hour_resets_at": …, "at_epoch": 1893800000}
/// A file without `at_epoch` or without a weekly figure is ignored: its age can't be known.
func readUsageFile(_ path: String) -> Reading? {
    guard let data = FileManager.default.contents(atPath: path),
          let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let at = (d["at_epoch"] as? NSNumber)?.doubleValue, at > 0,
          let week = (d["seven_day_pct"] as? NSNumber)?.doubleValue else { return nil }
    func date(_ key: String) -> Date? {
        if let n = d[key] as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        guard let s = d[key] as? String else { return nil }
        let f = ISO8601DateFormatter()
        if let x = f.date(from: s) { return x }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
    return Reading(weekUsed: week, weekResets: date("seven_day_resets_at"),
                   fiveUsed: (d["five_hour_pct"] as? NSNumber)?.doubleValue, fiveResets: date("five_hour_resets_at"),
                   takenAt: Date(timeIntervalSince1970: at), source: .file(path))
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
    var loggedOut = false, apiKey = false, billingError = false
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
            if (ev["error"] as? String) == "billing_error" { billingError = true }
        default: break
        }
    }
    guard let windows else {
        // A login whose tokens were blanked (refresh token expired) is answered with a billing error, not a 401.
        if billingError && !apiKey { loggedOut = true }
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
        // The main process of any copy of the desktop app: Claude.app itself, or a per-account app
        // (desktop_launcher) that runs its own Contents/MacOS/Claude. Helpers live elsewhere in the bundle.
        guard let binEnd = cmd.range(of: ".app/Contents/MacOS/Claude"),
              binEnd.upperBound == cmd.endIndex || cmd[binEnd.upperBound] == " " else { continue }
        let args = cmd[binEnd.upperBound...]
        for a in accounts where a.hasDesktopApp {
            let matches = a.desktopProfile.map { args == " --user-data-dir=\($0)" || args.hasPrefix(" --user-data-dir=\($0) ") }
                ?? !args.contains("--user-data-dir=")
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
    p.arguments = account.desktopLauncher.map { ["-a", $0] }
        ?? account.desktopProfile.map { ["-n", "-a", "Claude", "--args", "--user-data-dir=\($0)"] } ?? ["-a", "Claude"]
    try? p.run()
}

// MARK: - Model

final class Model: ObservableObject {
    @Published var readings: [String: Reading] = [:]
    @Published var problems: [String: String] = [:]
    @Published var running: [String: pid_t] = [:]
    @Published var checking: Set<String> = []
    @Published var roles: [String: [String]] = [:]
    private var lastAttempt: [String: Date] = [:]

    var refreshing: Bool { !checking.isEmpty }

    func reloadRunning() { running = claudeProcesses() }

    /// Re-reads the roles file, so a change there shows on the next open without a restart.
    func reloadRoles() {
        guard let src = roleSource, let text = try? String(contentsOfFile: src.file, encoding: .utf8) else { roles = [:]; return }
        roles = roleLabels(src, text: text)
    }

    func subtitle(_ a: Account) -> String {
        let s = ([a.subtitle] + (roles[a.id] ?? [])).filter { !$0.isEmpty }.joined(separator: " · ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Takes any usage_file reading that is newer than what's on screen. Reading a file costs nothing.
    func loadFiles() {
        for a in accounts {
            guard let f = a.usageFile, let r = readUsageFile(f), r.takenAt <= Date().addingTimeInterval(60) else { continue }
            if r.takenAt > (readings[a.id]?.takenAt ?? .distantPast) { readings[a.id] = r }
        }
    }

    /// Checks every account whose newest reading is older than maxAge. An account is never checked
    /// twice at once, again within a minute, or within failedRetry of a failed check.
    func refreshStale(maxAge: TimeInterval) {
        loadFiles()
        let now = Date()
        check(accounts.filter { a in
            let age = readings[a.id].map { now.timeIntervalSince($0.takenAt) } ?? .infinity
            let since = lastAttempt[a.id].map { now.timeIntervalSince($0) } ?? .infinity
            return age > maxAge && since > (problems[a.id] != nil ? failedRetry : 60)
        })
    }

    /// Checks the given accounts (one tiny Haiku turn each), each card updating as its turn ends.
    /// A failed check keeps the last good reading on screen, with its age, and shows why it failed.
    func check(_ list: [Account], then done: (() -> Void)? = nil) {
        let list = list.filter { !checking.contains($0.id) }
        guard !list.isEmpty else { done?(); return }
        let group = DispatchGroup()
        for a in list {
            checking.insert(a.id)
            lastAttempt[a.id] = Date()
            group.enter()
            DispatchQueue.global().async {
                let r: Result<Reading, FetchError> = findClaude().map { fetchReading(a, claude: $0) }
                    ?? .failure(.message("Claude Code isn't installed. Get it at claude.com/claude-code."))
                DispatchQueue.main.async {
                    switch r {
                    case .success(let reading): self.readings[a.id] = reading; self.problems[a.id] = nil
                    case .failure(.message(let m)): self.problems[a.id] = m
                    }
                    self.checking.remove(a.id)
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            self.reloadRunning()
            done?()
        }
    }

    /// One line per group in which an account is nearly out and another in the same group isn't.
    var hints: [String] {
        let usable = accounts.compactMap { a in readings[a.id].flatMap { r in r.usableNow.map { (a, $0, r) } } }
        var lines: [String] = [], groups: [String] = []
        for a in accounts where !groups.contains(a.group) { groups.append(a.group) }
        for group in groups {
            let inGroup = usable.filter { $0.0.group == group }
            guard let worst = inGroup.min(by: { $0.1 < $1.1 }), worst.1 < 10,
                  let best = inGroup.filter({ $0.0.id != worst.0.id }).max(by: { $0.1 < $1.1 }), best.1 >= 10 else { continue }
            lines.append("Use \(best.0.name) · \(worst.0.name) resets \(resetText(worst.2.binding?.resetsAt))")
        }
        return lines
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

/// Colour only where it means something: red when nearly out, orange when used faster than an even
/// pace through the window (more than 5 points ahead), otherwise none.
let paceSlack = 5.0
func tone(_ limit: Limit) -> Color? {
    limit.left <= 10 ? .red : (limit.paceGap() ?? 0) > paceSlack ? .orange : nil
}
func showUsed() -> Bool { (UserDefaults.standard.string(forKey: "display.mode") ?? "used") == "used" }
func shown(_ left: Double) -> Double { showUsed() ? 100 - left : left }
func modeWord() -> String { showUsed() ? "used" : "left" }
func percent(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))%" } ?? "–" }

/// Every reset time in one form: weekday and 24-hour time, e.g. "Sat 15:00".
func resetText(_ date: Date?) -> String {
    guard let date else { return "now" }
    let f = DateFormatter()
    f.dateFormat = "EEE HH:mm"
    return f.string(from: date)
}

func paceText(_ limit: Limit) -> String? {
    guard let gap = limit.paceGap() else { return nil }
    let pts = Int(abs(gap).rounded())
    return pts < 3 ? "on pace" : gap > 0 ? "\(pts) over pace" : "\(pts) under pace"
}

/// When this window runs out if use carries on at its average rate so far; nil when it lasts to its
/// reset or there is too little of the window behind us (under 5%) to say. An empty window is out now.
func runOut(_ limit: Limit, at now: Date = Date()) -> Date? {
    if limit.left <= 0.5 { return now }
    guard let through = limit.through(at: now), through >= 0.05, limit.used > 0, let reset = limit.resetsAt else { return nil }
    let rate = limit.used / (through * limit.window)          // points per second so far
    let out = now.addingTimeInterval(limit.left / rate)
    return out < reset ? out : nil
}

/// The one line a row leads with: out (and until when), going to run out (and roughly when), or when it resets.
func statusLine(_ r: Reading, fiveHour: Bool, resets: Bool, at now: Date = Date()) -> (text: String, color: Color?) {
    let limits = [r.week, fiveHour ? r.fiveHour : nil].compactMap { $0 }
    let empty = limits.filter { $0.left <= 0.5 }
    if !empty.isEmpty {
        let back = empty.compactMap(\.resetsAt).max()
        return ("Out · back \(back.map { resetText($0) } ?? "soon")", .red)
    }
    // A 5-hour window is only worth projecting once it is half used; earlier it is noise.
    let outs = limits.filter { $0.window == weekWindow || $0.used >= 50 }.compactMap { runOut($0, at: now) }
    if let out = outs.min() { return ("Runs out ~\(resetText(out))", .orange) }
    if resets, let w = r.week, let at = w.resetsAt { return ("Resets \(resetText(at))", nil) }
    return ("", nil)
}

/// The account's own Dock icon (its desktop_launcher app, or Claude.app for the default profile).
var iconCache: [String: NSImage] = [:]
func appIcon(_ a: Account) -> NSImage? {
    guard a.hasDesktopApp else { return nil }
    let path = a.desktopLauncher ?? (a.desktopProfile == nil ? "/Applications/Claude.app" : nil)
    guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
    if let hit = iconCache[path] { return hit }
    // The bundle's own icon file first: the Finder icon carries a padlock badge on a locked bundle.
    let file = (Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleIconFile") as? String).map {
        "\(path)/Contents/Resources/\($0.hasSuffix(".icns") ? $0 : $0 + ".icns")"
    }
    let img = file.flatMap { NSImage(contentsOfFile: $0) } ?? NSWorkspace.shared.icon(forFile: path)
    iconCache[path] = img
    return img
}

func ageText(_ minutes: Double) -> String {
    minutes < 1 ? "just now"
        : minutes < 90 ? "\(Int(minutes)) min ago"
        : minutes < 48 * 60 ? "\(Int((minutes / 60).rounded())) h ago"
        : "\(Int((minutes / 1440).rounded())) days ago"
}

/// Which accounts appear in the menu bar. Keyed by name, so adding or reordering accounts doesn't
/// move a setting to another account; the old position-keyed setting is still honoured.
func showKey(_ a: Account) -> String { "show.\(a.name)" }
func isShown(_ a: Account) -> Bool {
    let d = UserDefaults.standard
    return d.object(forKey: showKey(a)) as? Bool ?? d.object(forKey: "show.\(a.id)") as? Bool ?? true
}

/// The figure a card and the menu bar both lead with, as % left.
func headline(_ r: Reading?) -> Limit? {
    let metric = UserDefaults.standard.string(forKey: "title.metric") ?? "now"
    return metric == "week" ? r?.week : metric == "five" ? r?.fiveHour : r?.binding
}

func menuBarTitle(_ model: Model) -> NSAttributedString {
    let style = UserDefaults.standard.string(forKey: "title.style") ?? "icons"
    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    let quiet: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
    let lefts = accounts.filter(isShown).map { a in (a, headline(model.readings[a.id])?.left) }
    guard !lefts.isEmpty else { return NSAttributedString(string: "Claude", attributes: [.font: font]) }
    // "none": bare numbers in config order, a thin dot inside a group and a bar between groups,
    // so six accounts stay readable and you can tell whose number is whose by where it sits.
    let bare = style == "none"
    let title = NSMutableAttributedString()
    for (i, (a, left)) in lefts.enumerated() {
        if i > 0 {
            let newGroup = lefts[i - 1].0.group != a.group
            title.append(NSAttributedString(string: bare ? (newGroup ? "\u{2002}|\u{2002}" : "\u{2009}·\u{2009}") : "   ",
                                            attributes: bare ? quiet : [.font: font]))
        }
        let number = bare ? left.map { "\(Int(shown($0).rounded()))" } ?? "–" : percent(left.map(shown))
        let mark = bare ? "" : "\(style == "icons" ? a.glyph : a.letter) "
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        if let left, left <= 10 { attrs[.foregroundColor] = NSColor.systemRed }   // nearly out
        title.append(NSAttributedString(string: mark + number, attributes: attrs))
    }
    return title
}

// MARK: - Panel

/// Layout constants, so every card lines up on the same columns.
enum Metrics {
    static let panelWidth: CGFloat = 348
    static let pad: CGFloat = 12
    static let iconColumn: CGFloat = 18
    static let labelColumn: CGFloat = 30
    static let percentColumn: CGFloat = 34
    static let gap: CGFloat = 8
}

/// A used-so-far bar with a tick at how far through the window the clock is: fill past the tick
/// means the account is being used faster than an even pace.
struct PaceBar: View {
    let fill: Double        // 0–100, what the number beside it shows
    let tick: Double?       // 0–1
    let color: Color?
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1)).frame(height: 5)
                Capsule().fill(color ?? Color.primary.opacity(0.42))
                    .frame(width: fill > 0 ? max(5, g.size.width * min(fill, 100) / 100) : 0, height: 5)
                if let tick {
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 1.5, height: 11)
                        .offset(x: min(g.size.width - 1.5, max(0, g.size.width * tick - 0.75)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 11)
        .help("The tick is how far through this window the clock is. Fill past it: used faster than an even pace.")
    }
}

struct LimitRow: View {
    let label: String
    let limit: Limit
    var body: some View {
        let color = tone(limit)
        HStack(spacing: Metrics.gap) {
            Text(label).frame(width: Metrics.labelColumn, alignment: .leading).foregroundStyle(.tertiary)
            PaceBar(fill: shown(limit.left), tick: limit.through().map { showUsed() ? $0 : 1 - $0 }, color: color)
            Text(percent(shown(limit.left)))
                .monospacedDigit()
                .foregroundStyle(color ?? .secondary)
                .frame(width: Metrics.percentColumn, alignment: .trailing)
        }
        .font(.system(size: 10.5))
        .help(paceText(limit).map { "\($0) (percentage points against an even pace)" } ?? "")
    }
}

struct AccountCard: View {
    let account: Account
    @ObservedObject var model: Model
    let showFiveHour: Bool
    let showResets: Bool
    let onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        let reading = model.readings[account.id]
        let problem = model.problems[account.id]
        let running = model.running[account.id] != nil
        let checking = model.checking.contains(account.id)
        let status = reading.map { statusLine($0, fiveHour: showFiveHour, resets: showResets) }
        let stale = reading.map { $0.ageMinutes >= 20 } ?? false
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon = appIcon(account) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: account.symbol).font(.system(size: 15)).foregroundStyle(account.tint)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(account.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if running { Circle().fill(.green).frame(width: 5, height: 5).help("Its desktop app is open") }
                    Spacer(minLength: 6)
                    if checking { ProgressView().controlSize(.mini) }
                    if let status, !status.text.isEmpty {
                        Text(status.text)
                            .font(.system(size: 11, weight: status.color == nil ? .regular : .medium))
                            .foregroundStyle(status.color ?? .secondary)
                            .monospacedDigit().lineLimit(1)
                    }
                }
                if let r = reading {
                    if let w = r.week { LimitRow(label: "Week", limit: w) }
                    if showFiveHour, let f = r.fiveHour { LimitRow(label: "5h", limit: f) }
                    if stale { Text("Reading \(ageText(r.ageMinutes))").font(.system(size: 10)).foregroundStyle(.tertiary) }
                } else if problem == nil {
                    Text(checking ? "Checking…" : "No reading yet").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hover && account.hasDesktopApp ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if account.hasDesktopApp { onOpen() } }
        .help(helpText(reading, running: running))
    }

    func helpText(_ r: Reading?, running: Bool) -> String {
        var parts: [String] = []
        let sub = model.subtitle(account)
        if !sub.isEmpty { parts.append(sub) }
        if account.hasDesktopApp { parts.append(running ? "Click to switch to its Claude app" : "Click to open its Claude app") }
        if let r { parts.append("\(sourceText(r)), \(ageText(r.ageMinutes))") }
        return parts.joined(separator: "\n")
    }

    func sourceText(_ r: Reading) -> String {
        switch r.source {
        case .check: return "Read by this app's own Claude Code check"
        case .file(let path): return "Read from \(path.replacingOccurrences(of: home, with: "~"))"
        }
    }
}

struct StoredToggle: View {
    @AppStorage private var on: Bool
    init(_ account: Account) { _on = AppStorage(wrappedValue: isShown(account), showKey(account)) }
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
                ForEach(accounts) { a in row(a.name) { StoredToggle(a) } }
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
                        Text("None").tag("none")
                    }
                    .fixedSize()   // a pop-up, not segments: six accounts' marks don't fit as segments
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(showSettings ? "Settings" : "Claude usage").font(.system(size: 13, weight: .semibold))
                if !showSettings {
                    Text("% \(modeWord())").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if !showSettings {
                    if model.refreshing {
                        ProgressView().controlSize(.small).frame(width: 16, height: 16)
                    } else {
                        Button { model.loadFiles(); model.check(accounts) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Check every account now")
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
                ForEach(model.hints, id: \.self) { hint in
                    Label(hint, systemImage: "arrow.right.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                }
                VStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { i, a in
                        if i > 0, accounts[i - 1].panelSection != a.panelSection {
                            Divider().padding(.vertical, 4).padding(.horizontal, 8)
                        }
                        AccountCard(account: a, model: model, showFiveHour: showFiveHour, showResets: showResets) { onOpen(a) }
                    }
                }
            }
        }
        .padding(Metrics.pad)
        .frame(width: Metrics.panelWidth)
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
        model.reloadRoles()
        model.refreshStale(maxAge: maxAgeClosed)
        // Every 30 s: pick up newer usage files (free), redraw ages and pace ticks, and check any
        // account whose newest reading is past the limit for the panel's state.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 5
    }

    func tick() {
        model.refreshStale(maxAge: popover.isShown ? maxAgeOpen : maxAgeClosed)
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
            model.reloadRoles()
            model.refreshStale(maxAge: maxAgeOpen)
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

/// Fetches live numbers, then renders the panel and settings, dark and light, to PNGs.
func snapshot(to dir: String) {
    let model = Model()
    model.reloadRoles()
    model.loadFiles()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { model.check(accounts) { done.signal() } }
    while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    for (look, scheme, appearance, bg) in [("dark", ColorScheme.dark, NSAppearance.Name.darkAqua, Color(white: 0.16)),
                                           ("light", ColorScheme.light, NSAppearance.Name.aqua, Color(white: 0.94))] {
        for (name, settings) in [("panel", false), ("settings", true)] {
            let view = NSHostingView(rootView: PanelView(model: model, showSettings: settings) { _ in }
                .background(bg)
                .environment(\.colorScheme, scheme))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(look).png"))
        }
    }
    print(menuBarTitle(model).string)
    for a in accounts {
        let r = model.readings[a.id]
        let from = r.map { $0.source == .check ? "own check" : "usage file" } ?? "no reading"
        print("\(a.name) [\(model.subtitle(a))]: week \(percent(r?.weekUsed)) used, 5-hour \(percent(r?.fiveUsed)) used, "
              + "\(r.map { ageText($0.ageMinutes) } ?? "-") from \(from)\(model.problems[a.id].map { " — \($0)" } ?? "")")
    }
}

/// Checks the pure parts (roles file, usage files, pace maths, reset text) on fixed inputs.
/// Prints one line per case and exits 1 if any fails.
func selftest() -> Int32 {
    var failed = 0
    func expect(_ name: String, _ ok: Bool) { print(ok ? "ok   \(name)" : "FAIL \(name)"); if !ok { failed += 1 } }

    let yaml = """
    top: 1
    accounts:
      primary: c            # first choice
      spares: b a      # ordered
      # a comment line
      phone: "c"
      fallback: none
      nested:
        deeper: z
    reserve:
      primary: a
    """
    let parsed = parseRoleSection(yaml, section: "accounts")
    expect("roles: keys in file order, direct children only", parsed.map(\.key) == ["primary", "spares", "phone", "fallback", "nested"])
    expect("roles: comment stripped, list split", parsed.first { $0.key == "spares" }?.ids == ["b", "a"])
    expect("roles: quotes stripped", parsed.first { $0.key == "phone" }?.ids == ["c"])
    expect("roles: next section not read", !parsed.contains { $0.key == "primary" && $0.ids == ["a"] })
    expect("roles: missing section gives nothing", parseRoleSection(yaml, section: "nope").isEmpty)
    let mk = { (id: String, rid: String?) in
        Account(id: id, name: id, subtitle: "", glyph: "", symbol: "", tint: .gray, letter: "", configDir: nil,
                tokenFile: nil, desktopProfile: nil, roleID: rid)
    }
    let src = RoleSource(file: "", section: "accounts",
                         labels: ["primary": ["home"], "phone": ["desk"], "spares": ["spare", "last resort"]])
    let labels = roleLabels(src, text: yaml, for: [mk("0", "a"), mk("1", "b"), mk("2", "c"), mk("3", nil), mk("4", "z")])
    expect("labels: two roles in file order", labels["2"] == ["home", "desk"])
    expect("labels: first in list", labels["1"] == ["spare"])
    expect("labels: second in list", labels["0"] == ["last resort"])
    expect("labels: no role id, no label", labels["3"] == nil)
    expect("labels: id not listed, no label", labels["4"] == nil)

    let dir = NSTemporaryDirectory() + "claude-usage-bar-selftest-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func file(_ name: String, _ body: String) -> String {
        let p = "\(dir)/\(name)"; try? body.write(toFile: p, atomically: true, encoding: .utf8); return p
    }
    let good = readUsageFile(file("good.json", #"{"seven_day_pct": 52.0, "seven_day_resets_at": "2030-01-05T15:00:00+00:00", "five_hour_pct": null, "five_hour_resets_at": null, "at_epoch": 1893800000, "source": "x"}"#))
    expect("usage file: week and age read", good?.weekUsed == 52 && good?.takenAt == Date(timeIntervalSince1970: 1893800000))
    expect("usage file: ISO reset read", good?.weekResets == ISO8601DateFormatter().date(from: "2030-01-05T15:00:00Z"))
    expect("usage file: null 5-hour stays absent", good?.fiveUsed == nil && good?.fiveResets == nil)
    let epoch = readUsageFile(file("epoch.json", #"{"seven_day_pct": 3, "seven_day_resets_at": 1794800000, "five_hour_pct": 7, "five_hour_resets_at": 1794710000.5, "at_epoch": 1794700000}"#))
    expect("usage file: epoch resets and int percent", epoch?.weekResets == Date(timeIntervalSince1970: 1794800000) && epoch?.fiveUsed == 7)
    expect("usage file: no at_epoch is ignored", readUsageFile(file("noage.json", #"{"seven_day_pct": 3}"#)) == nil)
    expect("usage file: no weekly figure is ignored", readUsageFile(file("noweek.json", #"{"at_epoch": 1794700000}"#)) == nil)
    expect("usage file: junk is ignored", readUsageFile(file("junk.json", "not json")) == nil)
    expect("usage file: missing file is ignored", readUsageFile("\(dir)/absent.json") == nil)
    try? FileManager.default.removeItem(atPath: dir)

    let now = Date()
    let half = Limit(left: 40, resetsAt: now.addingTimeInterval(weekWindow / 2))
    expect("pace: half way through the week", abs((half.through(at: now) ?? -1) - 0.5) < 0.0001)
    expect("pace: 60 used at half way is 10 over", abs((half.paceGap(at: now) ?? 0) - 10) < 0.01)
    expect("pace: over pace is orange", tone(half) == .orange)
    expect("pace: on pace is uncoloured", tone(Limit(left: 52, resetsAt: now.addingTimeInterval(weekWindow / 2))) == nil)
    expect("pace: nearly out is red", tone(Limit(left: 8, resetsAt: now.addingTimeInterval(weekWindow * 0.05))) == .red)
    let five = Limit(left: 90, resetsAt: now.addingTimeInterval(fiveHourWindow * 0.75), window: fiveHourWindow)
    expect("pace: 5-hour window uses its own length", abs((five.through(at: now) ?? -1) - 0.25) < 0.0001)
    let passed = Reading(weekUsed: 99, weekResets: now.addingTimeInterval(-10), fiveUsed: nil, fiveResets: nil, takenAt: now)
    expect("pace: a passed reset is full with no tick", passed.week?.left == 100 && passed.week?.through() == nil)
    expect("pace text: under", paceText(Limit(left: 90, resetsAt: now.addingTimeInterval(weekWindow / 2))) == "40 under pace")
    expect("pace text: on", paceText(Limit(left: 49, resetsAt: now.addingTimeInterval(weekWindow / 2))) == "on pace")

    let fast = Limit(left: 40, resetsAt: now.addingTimeInterval(weekWindow / 2))   // 60 used at half way
    let fastOut = runOut(fast, at: now)
    expect("run-out: 60 used at half way runs out a third of a week from now",
           fastOut.map { abs($0.timeIntervalSince(now) - weekWindow / 3) < 60 } ?? false)
    expect("run-out: 20 used at half way lasts to the reset", runOut(Limit(left: 80, resetsAt: now.addingTimeInterval(weekWindow / 2)), at: now) == nil)
    expect("run-out: too early in the window to say", runOut(Limit(left: 90, resetsAt: now.addingTimeInterval(weekWindow * 0.98)), at: now) == nil)
    let outRead = Reading(weekUsed: 30, weekResets: now.addingTimeInterval(weekWindow / 2), fiveUsed: 100,
                          fiveResets: now.addingTimeInterval(3600), takenAt: now)
    expect("status: an empty 5-hour window is out until it resets",
           statusLine(outRead, fiveHour: true, resets: true, at: now).text == "Out · back \(resetText(now.addingTimeInterval(3600)))")
    let calm = Reading(weekUsed: 20, weekResets: now.addingTimeInterval(weekWindow / 2), fiveUsed: nil, fiveResets: nil, takenAt: now)
    expect("status: a calm account shows its reset", statusLine(calm, fiveHour: true, resets: true, at: now).text.hasPrefix("Resets "))
    let hot = Reading(weekUsed: 60, weekResets: now.addingTimeInterval(weekWindow / 2), fiveUsed: nil, fiveResets: nil, takenAt: now)
    expect("status: a fast account warns", statusLine(hot, fiveHour: true, resets: true, at: now).text.hasPrefix("Runs out ~"))

    let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
    let soon = now.addingTimeInterval(3600), later = now.addingTimeInterval(5 * 86400)
    expect("reset text: one form near and far", resetText(soon) == f.string(from: soon) && resetText(later) == f.string(from: later))

    print(failed == 0 ? "selftest: all passed" : "selftest: \(failed) failed")
    return failed == 0 ? 0 : 1
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if args.contains("--selftest") { exit(selftest()) }
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
