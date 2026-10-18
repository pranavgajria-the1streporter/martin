import AppKit
import AVFoundation
import ServiceManagement

enum Nudge: String, CaseIterable {
    case posture, situp, stretch, walk

    var name: String {
        switch self {
        case .posture: return "Posture check"
        case .situp: return "Sit up"
        case .stretch: return "Stretch"
        case .walk: return "Walk"
        }
    }

    func counted(_ n: Int) -> String {
        let words: (String, String)
        switch self {
        case .posture: words = ("posture check", "posture checks")
        case .situp: words = ("sit-up", "sit-ups")
        case .stretch: words = ("stretch", "stretches")
        case .walk: words = ("walk", "walks")
        }
        return "\(n) \(n == 1 ? words.0 : words.1)"
    }

    /// Minutes of sitting before Martin says something.
    var defaultMinutes: Int {
        switch self {
        case .posture: return 10
        case .situp: return 25
        case .stretch: return 50
        case .walk: return 90
        }
    }

    /// When a bigger nudge fires, the smaller ones it covers start over.
    var covers: [Nudge] {
        switch self {
        case .walk: return Nudge.allCases
        case .stretch: return [.stretch, .situp, .posture]
        case .situp: return [.situp, .posture]
        case .posture: return [.posture]
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    let card = CardWindow()
    private var statusItem: NSStatusItem!
    private var seated: [Nudge: TimeInterval] = [:]
    private var showing: Nudge?
    private var lastTick = Date()
    private var micSince: Date?
    private var timer: Timer?
    private var ding: AVAudioPlayer?
    private var activity: NSObjectProtocol?
    private var shownAt = Date()
    private var onBreak = false
    private var lastBlock: String?
    private var cameraOn = false
    private var micOn = false
    private var ticks = 0
    /// Each card gets a number. Messages from an older card are ignored, so a late "closed" can't hide a new card.
    private var session = 0
    private var shown = false
    private var firedAt = Date()
    private var retryAfter: Date?

    /// How long a card gets to confirm it is on screen before Martin rebuilds it.
    private let confirmSeconds: TimeInterval = 2.5

    /// A break: this long without touching the Mac resets every timer.
    private let breakSeconds: TimeInterval = 5 * 60
    /// The mic counts as a call after this long, so short dictation doesn't silence Martin.
    private let callSeconds: TimeInterval = 2 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        Nudge.allCases.forEach { seated[$0] = 0 }

        // Without this, macOS naps a menu bar app with no windows and stretches its 10 second timer into minutes,
        // which makes every nudge arrive late.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Martin keeps time")
        Log.write("launch: pid \(ProcessInfo.processInfo.processIdentifier), App Nap off")

        // On a notched MacBook, menu bar icons that don't fit hide behind the notch, newest first.
        // Asking for a spot near the clock keeps Martin visible. Cmd-drag still moves him.
        if defaults.object(forKey: "NSStatusItem Preferred Position martin") == nil {
            defaults.set(220, forKey: "NSStatusItem Preferred Position martin")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: 26)
        statusItem.autosaveName = "martin"
        statusItem.button?.image = Self.face()
        statusItem.button?.toolTip = "Martin"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        card.onMessage = { [weak self] message in self?.handle(message) }
        card.parkIfIdle()

        // For testing a running Martin from Terminal: notifyutil -p martin.test.stretch
        for n in Nudge.allCases {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("martin.test.\(n.rawValue)"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.fire(n) }
            }
        }

        if let url = Bundle.main.url(forResource: "ding", withExtension: "wav") {
            ding = try? AVAudioPlayer(contentsOf: url)
            ding?.volume = 0.7
            ding?.prepareToPlay()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                Log.write("wake: timers reset")
                self?.restart()
            }
        }

        // For testing: open Martin.app --args --nudge walk
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--nudge"), i + 1 < args.count, let n = Nudge(rawValue: args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.fire(n) }
            if let j = args.firstIndex(of: "--snapshot"), j + 1 < args.count {
                let base = args[j + 1]
                for t in [3.0, 6.0] { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + t) { self.card.snapshot(to: base + "-\(Int(t)).png") } }
            }
        }
    }

    // MARK: The clock

    private func tick() {
        let now = Date()
        // Without App Nap the timer is on time, so a long gap means the Mac slept. Waking resets the timers anyway.
        let elapsed = min(now.timeIntervalSince(lastTick), 120)
        lastTick = now
        ticks += 1

        // A card that never reports back would silence every later nudge, so give it a deadline.
        if let n = showing, now.timeIntervalSince(shownAt) > 150 {
            Log.write("watchdog: \(n.rawValue) card never closed, reset")
            showing = nil
            card.hide()
        }

        let idle = Quiet.idleSeconds()
        if idle >= breakSeconds {
            if !onBreak {
                Log.write("break: idle \(Int(idle))s, timers reset")
                onBreak = true
            }
            restart()
            return
        }
        onBreak = false

        let mic = Quiet.micInUse()
        let camera = Quiet.cameraInUse()
        if mic != micOn { Log.write("mic \(mic ? "on" : "off")"); micOn = mic }
        if camera != cameraOn { Log.write("camera \(camera ? "on" : "off")"); cameraOn = camera }
        if mic {
            if micSince == nil { micSince = now }
        } else {
            micSince = nil
        }

        for n in Nudge.allCases { seated[n, default: 0] += elapsed }

        if ticks % 30 == 0 {
            let minutes = Nudge.allCases.map { "\($0.rawValue) \(Int(seated[$0, default: 0] / 60))m" }.joined(separator: ", ")
            Log.write("alive: seated \(minutes), idle \(Int(idle))s, card window drawn \(card.isDrawn ? "yes" : "NO")")
        }

        guard let due = [Nudge.walk, .stretch, .situp, .posture].first(where: { seated[$0, default: 0] >= interval($0) }) else { return }
        if showing != nil { return }
        if let retry = retryAfter, now < retry { return }
        if let reason = quietReason() {
            if reason != lastBlock {
                Log.write("due: \(due.rawValue), held back: \(reason)")
                lastBlock = reason
            }
            return
        }
        lastBlock = nil
        fire(due)
    }

    private func restart() {
        Nudge.allCases.forEach { seated[$0] = 0 }
        lastTick = Date()
    }

    private func interval(_ n: Nudge) -> TimeInterval {
        let minutes = defaults.integer(forKey: "minutes.\(n.rawValue)")
        return TimeInterval(minutes > 0 ? minutes : n.defaultMinutes) * 60
    }

    private func quietReason() -> String? {
        if defaults.bool(forKey: "doNotDisturb") { return "Do not disturb is on" }
        if let until = defaults.object(forKey: "pausedUntil") as? Date, until > Date() {
            return "Paused until \(Self.clock.string(from: until))"
        }
        // The night belongs to the day before: Saturday 00:00 to 06:00 still counts as Friday, so a late Friday session keeps Martin.
        let weekday = Calendar.current.component(.weekday, from: Date().addingTimeInterval(-6 * 3600))
        if (weekday == 1 || weekday == 7) && !defaults.bool(forKey: "weekends") { return "Off on weekends" }
        if cameraOn { return "Quiet while the camera is on" }
        if let since = micSince, Date().timeIntervalSince(since) >= callSeconds { return "Quiet while you're on a call" }
        return nil
    }

    private func fire(_ n: Nudge) {
        if showing != nil { card.dismiss() }
        session += 1
        showing = n
        shown = false
        shownAt = Date()
        firedAt = Date()
        retryAfter = nil
        Log.write("fire: \(n.rawValue) (card window drawn: \(card.isDrawn ? "yes" : "NO"))")
        present(n, attempt: 1)
    }

    /// Puts the card up and waits for it to say it arrived. If it doesn't, rebuild it once and try again.
    /// The smaller timers start over only when the card has really shown, so a failed card doesn't cost a quiet 10 minutes.
    private func present(_ n: Nudge, attempt: Int) {
        let hour = Calendar.current.component(.hour, from: Date())
        var counts: [String: Int] = [:]
        for k in Nudge.allCases { counts[k.rawValue] = tally()[k.rawValue] ?? 0 }
        let id = session
        card.show(n, late: hour >= 22 || hour < 6, counts: counts, session: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmSeconds) { [weak self] in
            guard let self, self.session == id, !self.shown else { return }
            if attempt == 1 {
                Log.write("stalled: \(n.rawValue) card did not appear (drawn: \(self.card.isDrawn ? "yes" : "NO")), rebuilding")
                self.card.rebuild()
                self.present(n, attempt: 2)
            } else {
                Log.write("gave up: \(n.rawValue) card did not appear after a rebuild, trying again in 1 minute")
                self.showing = nil
                self.card.hide()
                self.retryAfter = Date().addingTimeInterval(60)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""
        let n = (message["nudge"] as? String).flatMap(Nudge.init(rawValue:))
        let id = message["session"] as? Int ?? 0
        // Only the card on screen now gets to say it arrived or closed.
        if (type == "shown" || type == "closed") && id != session { return }
        switch type {
        case "shown":
            guard !shown, let current = showing else { return }
            shown = true
            current.covers.forEach { seated[$0] = 0 }
            Log.write("shown: \(current.rawValue) in \(Int(Date().timeIntervalSince(firedAt) * 1000)) ms")
        case "counted":
            if let n { addToTally(n) }
        case "done":
            Log.write("done: \(n?.rawValue ?? "?")")
            if let n { addToTally(n) }
            ding?.currentTime = 0
            ding?.play()
        case "snooze":
            Log.write("snooze: \(n?.rawValue ?? "?")")
            if let n { seated[n] = max(0, interval(n) - 10 * 60) }
        case "log":
            FileHandle.standardError.write(("martin: \(message["text"] ?? "")\n").data(using: .utf8)!)
        case "closed":
            Log.write("closed")
            showing = nil
            card.hide()
        default:
            break
        }
    }

    // MARK: Today's tally

    private var todayKey: String { "tally." + Self.day.string(from: Date()) }

    private func tally() -> [String: Int] { defaults.dictionary(forKey: todayKey) as? [String: Int] ?? [:] }

    private func addToTally(_ n: Nudge) {
        var t = tally()
        t[n.rawValue, default: 0] += 1
        defaults.set(t, forKey: todayKey)
    }

    // MARK: The menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let t = tally()
        let done = Nudge.allCases.compactMap { n -> String? in
            let c = t[n.rawValue] ?? 0
            return c > 0 ? n.counted(c) : nil
        }
        menu.addItem(info(done.isEmpty ? "Today: nothing yet" : "Today: " + done.joined(separator: ", ")))
        if let reason = quietReason() {
            menu.addItem(info(reason))
        } else if let next = Nudge.allCases.min(by: { interval($0) - seated[$0, default: 0] < interval($1) - seated[$1, default: 0] }) {
            let minutes = max(0, Int(((interval(next) - seated[next, default: 0]) / 60).rounded(.up)))
            menu.addItem(info("Next: \(next.name.lowercased()) in \(minutes) min"))
        }
        menu.addItem(.separator())

        let dnd = item("Do not disturb", #selector(toggleDoNotDisturb))
        dnd.state = defaults.bool(forKey: "doNotDisturb") ? .on : .off
        menu.addItem(dnd)
        if let until = defaults.object(forKey: "pausedUntil") as? Date, until > Date() {
            menu.addItem(item("Resume now", #selector(resume)))
        } else {
            menu.addItem(item("Pause for an hour", #selector(pauseHour)))
        }
        let weekends = item("Nudge on weekends", #selector(toggleWeekends))
        weekends.state = defaults.bool(forKey: "weekends") ? .on : .off
        menu.addItem(weekends)
        menu.addItem(.separator())

        let now = NSMenuItem(title: "Nudge me now", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for n in Nudge.allCases {
            let i = item(n.name, #selector(nudgeNow(_:)))
            i.representedObject = n.rawValue
            sub.addItem(i)
        }
        now.submenu = sub
        menu.addItem(now)
        let rhythm = Nudge.allCases.map { "\($0.name.lowercased()) \(Int(interval($0) / 60))" }.joined(separator: ", ")
        menu.addItem(info("Every: " + rhythm + " min"))
        menu.addItem(.separator())

        let login = item("Start at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit Martin", #selector(quit), key: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleDoNotDisturb() {
        let on = !defaults.bool(forKey: "doNotDisturb")
        defaults.set(on, forKey: "doNotDisturb")
        if on, showing != nil { card.dismiss() }
    }

    @objc private func pauseHour() {
        defaults.set(Date().addingTimeInterval(3600), forKey: "pausedUntil")
        if showing != nil { card.dismiss() }
    }

    @objc private func resume() {
        defaults.removeObject(forKey: "pausedUntil")
        restart()
    }

    @objc private func toggleWeekends() { defaults.set(!defaults.bool(forKey: "weekends"), forKey: "weekends") }

    @objc private func nudgeNow(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let n = Nudge(rawValue: raw) { fire(n) }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Martin couldn't change Start at login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Small things

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Martin's face for the menu bar, drawn as a template so it follows light and dark menu bars.
    private static func face() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let head = NSBezierPath(ovalIn: NSRect(x: 2.25, y: 2.25, width: 13.5, height: 13.5))
            head.lineWidth = 1.5
            head.stroke()
            NSBezierPath(ovalIn: NSRect(x: 5.9, y: 6.3, width: 2, height: 2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10.1, y: 6.3, width: 2, height: 2)).fill()
            let smile = NSBezierPath()
            smile.move(to: NSPoint(x: 5.8, y: 10.6))
            smile.curve(to: NSPoint(x: 12.2, y: 10.6), controlPoint1: NSPoint(x: 7.4, y: 13.2), controlPoint2: NSPoint(x: 10.6, y: 13.2))
            smile.lineWidth = 1.4
            smile.lineCapStyle = .round
            smile.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
