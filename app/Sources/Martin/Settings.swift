import AppKit
import SwiftUI

/// The choices in each "Every" menu. A value set earlier with `defaults write` that isn't here is added to its menu.
private let choices = [5, 10, 15, 20, 25, 30, 45, 50, 60, 90, 120, 180]

private func label(_ minutes: Int) -> String {
    switch minutes {
    case 60: return "Every hour"
    case let m where m > 60 && m % 60 == 0: return "Every \(m / 60) hours"
    case let m where m > 60: return "Every \(m / 60) h \(m % 60) min"
    default: return "Every \(minutes) min"
    }
}

/// One action: a switch to turn it off and a menu for how often it comes up.
/// Both write straight to the same preferences the timers read, so a change counts from the next tick.
private struct NudgeRow: View {
    let nudge: Nudge
    @AppStorage private var off: Bool
    @AppStorage private var minutes: Int

    init(_ nudge: Nudge) {
        self.nudge = nudge
        _off = AppStorage(wrappedValue: false, "off.\(nudge.rawValue)")
        _minutes = AppStorage(wrappedValue: 0, "minutes.\(nudge.rawValue)")
    }

    private var current: Int { minutes > 0 ? minutes : nudge.defaultMinutes }

    var body: some View {
        HStack(spacing: 12) {
            Text(nudge.name)
                .foregroundStyle(off ? .secondary : .primary)
            Spacer(minLength: 0)
            Picker("", selection: Binding(get: { current }, set: { minutes = $0 })) {
                ForEach((choices + [current]).uniqued().sorted(), id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)
            .disabled(off)
            Toggle(nudge.name, isOn: Binding(get: { !off }, set: { off = !$0 }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How long you sit before Martin speaks up.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ForEach(Nudge.allCases, id: \.self) { NudgeRow($0) }
            Text("A walk starts every timer over. A stretch resets the smaller ones.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(20)
        .frame(width: 380)
        .fixedSize()
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// The Settings window, opened from Martin's menu.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Martin"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // Martin has no Dock icon, so the window has to ask to come to the front.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
