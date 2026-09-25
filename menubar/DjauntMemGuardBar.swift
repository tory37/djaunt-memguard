// DjauntMemGuardBar — menu bar meter for Djaunt MemGuard.
//
// Deliberately dumb: the daemon owns all policy and publishes ~/.djaunt/memguard/state.json.
// This process only renders that file and shells back to the `memguard` CLI for
// actions, so the protection rules are enforced in exactly one place.

import Cocoa

let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".djaunt/memguard/state.json")

final class DjauntMemGuardBar: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var state: [String: Any] = [:]

    /// The CLI lives at <repo>/bin/memguard; this app at <repo>/menubar/DjauntMemGuardBar.app.
    private lazy var cliPath: String = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("bin/djt-memguard")
        .path

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - State

    private func refresh() {
        guard let data = try? Data(contentsOf: stateURL),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            renderTitle(text: "◌ MEM —", color: .secondaryLabelColor)
            return
        }
        state = parsed

        let tier = state["tier"] as? Int ?? 0
        let paused = state["paused"] as? Bool ?? false
        let freePercent = state["free_pct"] as? Int ?? 0

        // The item names itself rather than showing a bare dot, so it is
        // identifiable in a crowded menu bar without clicking it.
        let label = paused ? "MEM paused" : "MEM \(freePercent)%"
        renderTitle(text: "\(glyph(forTier: tier, paused: paused)) \(label)",
                    color: color(forTier: tier, paused: paused))
    }

    /// Shape carries the tier too, so the meter still reads when colour does not.
    private func glyph(forTier tier: Int, paused: Bool) -> String {
        if paused { return "◐" }
        switch tier {
        case 2:  return "▲"
        case 1:  return "◆"
        default: return "●"
        }
    }

    private func color(forTier tier: Int, paused: Bool) -> NSColor {
        if paused { return .secondaryLabelColor }
        switch tier {
        case 2:  return .systemRed
        case 1:  return .systemOrange
        default: return .systemGreen
        }
    }

    private func renderTitle(text: String, color: NSColor) {
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: color,
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            ])
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        let tierName = state["tier_name"] as? String ?? "unknown"
        let reason = state["reason"] as? String ?? "no data from daemon"
        addHeader(menu, "Djaunt MemGuard — \(tierName)")
        addInfo(menu, reason)
        menu.addItem(.separator())

        addInfo(menu, String(format: "Memory free        %@%%", describe("free_pct")))
        addInfo(menu, String(format: "Swap free          %@ GB", describe("swap_free_gb")))
        addInfo(menu, String(format: "Swap growth        %@ GB/min", describe("swap_growth_gb_per_min")))
        addInfo(menu, String(format: "Compressor         %@ GB", describe("compressor_gb")))
        menu.addItem(.separator())

        let reclaimable = state["reclaimable_gb"] as? Double ?? 0
        addAction(menu, "Run soft relief now", #selector(runRelief))

        let candidates = state["candidates"] as? [[String: Any]] ?? []
        if !candidates.isEmpty {
            let reclaimItem = NSMenuItem(
                title: String(format: "Reclaim idle tabs — %.1f GB available", reclaimable),
                action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            let bulk = NSMenuItem(title: "Reclaim ~2 GB of safe tabs",
                                  action: #selector(reclaimSafe), keyEquivalent: "")
            bulk.target = self
            submenu.addItem(bulk)
            submenu.addItem(.separator())

            for candidate in candidates {
                guard let pid = candidate["pid"] as? Int,
                      let mb = candidate["mb"] as? Int else { continue }
                let app = candidate["app"] as? String ?? "?"
                let risky = (candidate["risk"] as? String) == "RISKY"
                let title = String(format: "%@  %d MB%@", app, mb, risky ? "  (reloads window)" : "")
                let item = NSMenuItem(title: title, action: #selector(reclaimOne(_:)), keyEquivalent: "")
                item.target = self
                item.tag = pid
                submenu.addItem(item)
            }
            reclaimItem.submenu = submenu
            menu.addItem(reclaimItem)
        }

        menu.addItem(.separator())
        let paused = state["paused"] as? Bool ?? false
        addAction(menu, paused ? "Resume monitoring" : "Pause for 1 hour",
                  paused ? #selector(resume) : #selector(pause))
        addAction(menu, "Open log", #selector(openLog))
        addAction(menu, "Quit DjauntMemGuardBar", #selector(quit))
    }

    private func describe(_ key: String) -> String {
        if let value = state[key] as? Double { return String(format: "%.2f", value) }
        if let value = state[key] as? Int { return "\(value)" }
        return "—"
    }

    private func addHeader(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(item)
    }

    private func addInfo(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor])
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Actions

    private func runCLI(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", ([cliPath] + arguments)
            .map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")]
        try? process.run()
    }

    @objc private func runRelief()   { runCLI(["relief"]) }
    @objc private func reclaimSafe() { runCLI(["reclaim", "--safe", "2"]) }
    @objc private func pause()       { runCLI(["pause", "60"]) }
    @objc private func resume()      { runCLI(["resume"]) }

    @objc private func reclaimOne(_ sender: NSMenuItem) {
        runCLI(["reclaim", "\(sender.tag)"])
    }

    @objc private func openLog() {
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".djaunt/memguard/memguard.log")
        NSWorkspace.shared.open(log)
    }

    @objc private func openIncidents() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".djaunt/memguard/incidents")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

let application = NSApplication.shared
let controller = DjauntMemGuardBar()
application.delegate = controller
application.setActivationPolicy(.accessory)
application.run()
