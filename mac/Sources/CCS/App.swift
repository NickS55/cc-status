// CCS as a menu bar app: the same list as the `ccs` terminal dashboard, behind
// an icon that shows how many sessions are busy.
import Combine
import SwiftUI

@main
struct CCSApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // `CCS --list` prints what the app sees and exits, for checking the
        // parser against the CLI's without opening the menu.
        if CommandLine.arguments.contains("--list") {
            for s in SessionReader().load() {
                print([s.id, s.status, s.title ?? "-", money(s.cost), s.lastTool ?? "-", "\(s.exchanges.count)", s.pushed ? "pushed" : "-"].joined(separator: "\t"))
            }
            exit(0)
        }
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// The menu bar item is AppKit rather than SwiftUI's MenuBarExtra, because
// MenuBarExtra can't be opened from code, and the shortcut needs to.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var hotkey: Hotkey?
    private var watching: [AnyCancellable] = []
    private var current: Shortcut?
    private var cycling = false // cycled since the modifiers went down

    func applicationDidFinishLaunching(_ note: Notification) {
        let host = NSHostingController(rootView: Panel().environmentObject(store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading

        hotkey = Hotkey { [weak self] in Task { @MainActor in self?.shortcut() } }
        watching = [
            store.$sessions.sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } },
            store.$shortcut.sink { [weak self] label in
                let shortcut = Shortcut.presets.first { $0.label == label }
                self?.current = shortcut
                if self?.hotkey?.set(shortcut) == false { self?.store.say("\(label) is taken by another app") }
            },
        ]
        // Our own window has the keyboard while the panel is open, so a local
        // monitor sees the modifiers come up; no Input Monitoring needed.
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.flagsChanged(e)
            return e
        }
    }

    private func updateIcon() {
        let busy = store.busyCount
        item.button?.image = NSImage(systemSymbolName: busy > 0 ? "sparkle" : "checkmark.circle",
                                     accessibilityDescription: "Claude sessions")
        item.button?.title = busy > 0 ? " \(busy)" : ""
    }

    /// The shortcut opens the panel, and pressed again while it's open moves
    /// the selection down, wrapping at the end, like ⌘Tab through apps.
    /// Opening and letting go leaves the panel open; cycling and letting go
    /// jumps to the selected session.
    private func shortcut() {
        if popover.isShown {
            store.cycled += 1
            cycling = true
        } else {
            toggle()
        }
    }

    private func flagsChanged(_ e: NSEvent) {
        guard cycling, let mods = current?.flags else { return }
        if e.modifierFlags.intersection(mods).isEmpty {
            cycling = false
            store.released += 1
        }
    }

    @objc func toggle() {
        cycling = false
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            store.refresh()
            store.opened += 1
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

private let home = FileManager.default.homeDirectoryForCurrentUser.path

func tilde(_ p: String) -> String {
    p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
}

func ago(_ d: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(d)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

func oneLine(_ t: String?) -> String {
    (t ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

func money(_ c: Double?) -> String {
    c.map { String(format: "$%.2f", $0) } ?? ""
}

private extension Session {
    var color: Color { busy ? .orange : !live ? .secondary : pushed ? .purple : .green }
    var state: String { busy ? "busy" : !live ? "ended" : pushed ? "pushed" : "idle" }
    var context: String {
        if busy { return lastTool.map { "⚙ \($0)" } ?? lastPrompt.map { "\"\(oneLine($0))\"" } ?? "" }
        if let recap { return "Recap: \(oneLine(recap))" }
        return lastPrompt.map { "\"\(oneLine($0))\"" } ?? ""
    }
}

struct Panel: View {
    @EnvironmentObject var store: Store
    @State private var detail: String?
    @State private var sel = 0
    @State private var stopping: String? // armed by d, carried out by Enter
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let id = detail, let s = store.sessions.first(where: { $0.id == id }) {
                Detail(s: s, back: { detail = nil })
            } else if store.shown.isEmpty {
                Text("No Claude Code sessions running.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                CappedScroll(max: 460) {
                    ScrollViewReader { proxy in
                        VStack(spacing: 2) {
                            ForEach(Array(store.shown.enumerated()), id: \.element.id) { i, s in
                                Row(s: s, selected: i == sel, stopping: s.id == stopping, showDetail: { detail = s.id })
                                    .id(s.id)
                            }
                        }
                        .padding(6)
                        .onChange(of: sel) { _, i in
                            if store.shown.indices.contains(i) { proxy.scrollTo(store.shown[i].id) }
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 440)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down, action: key)
        .onAppear { reset() }
        .onChange(of: store.opened) { reset() }
        .onChange(of: store.cycled) { cycle() }
        .onChange(of: store.released) {
            if store.shown.indices.contains(sel) { store.focus(store.shown[sel]) }
        }
    }

    /// Each time the panel opens: back to the list, first session selected.
    private func reset() {
        detail = nil
        sel = 0
        stopping = nil
        focused = true
    }

    private func cycle() {
        let n = store.shown.count
        guard n > 0 else { return }
        detail = nil
        stopping = nil
        sel = (sel + 1) % n
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        let shown = store.shown
        // d arms a stop; Enter carries it out and any other key cancels it.
        if let id = stopping {
            stopping = nil
            if press.key == .return, let s = store.sessions.first(where: { $0.id == id }) { store.stop(s) }
            return .handled
        }
        if let id = detail, let s = store.sessions.first(where: { $0.id == id }) {
            switch press.key {
            case .escape, "i": detail = nil
            case .return: store.focus(s)
            case "d" where s.live: stopping = s.id
            case "n": store.newSession(near: s)
            default: return .ignored
            }
            return .handled
        }
        switch press.key {
        case .upArrow, "w", "k": sel = max(0, sel - 1)
        case .downArrow, "s", "j": sel = min(shown.count - 1, sel + 1)
        case .return:
            guard shown.indices.contains(sel) else { return .ignored }
            store.focus(shown[sel])
        case "i":
            guard shown.indices.contains(sel) else { return .ignored }
            detail = shown[sel].id
        case "d":
            guard shown.indices.contains(sel), shown[sel].live else { return .ignored }
            stopping = shown[sel].id
        case "n": store.newSession(near: shown.indices.contains(sel) ? shown[sel] : nil)
        default: return .ignored
        }
        return .handled
    }

    private var header: some View {
        HStack {
            Text("Claude Sessions").font(.headline)
            Spacer()
            Text("\(store.liveCount) live").foregroundStyle(.green)
            Text("·").foregroundStyle(.secondary)
            Text("\(store.busyCount) busy").foregroundStyle(store.busyCount > 0 ? .orange : .secondary)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let id = stopping, let s = store.sessions.first(where: { $0.id == id }) {
                Text("Stop \(s.label)? Enter stops it, any other key cancels.")
                    .foregroundStyle(.red).lineLimit(1)
            } else if !store.flash.isEmpty {
                Text(store.flash).foregroundStyle(.green).lineLimit(1)
            } else {
                Toggle("Ended", isOn: $store.showDead)
                Toggle(isOn: $store.sound) { Image(systemName: store.sound ? "bell.fill" : "bell.slash") }
                    .help("Play a sound when a session finishes")
                Toggle(isOn: $store.notify) { Image(systemName: "text.bubble") }
                    .help("Show a notification when a session finishes")
            }
            Spacer()
            Menu {
                Picker("Sound", selection: $store.soundName) {
                    ForEach(store.soundNames, id: \.self) { Text($0) }
                }
                Button("Test ping") { store.ping(); store.say("test ping (\(store.soundName))") }
                Picker("Shortcut to open", selection: $store.shortcut) {
                    ForEach(Shortcut.presets, id: \.label) { Text($0.label).tag($0.label) }
                    Text("None").tag("")
                }
                Divider()
                Button("Quit CCS") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct Row: View {
    @EnvironmentObject var store: Store
    let s: Session
    let selected: Bool
    let stopping: Bool
    let showDetail: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if s.busy { ProgressView().controlSize(.mini) }
                else { Image(systemName: s.live ? "circle" : "xmark").font(.system(size: 9, weight: .bold)) }
            }
            .foregroundStyle(s.color)
            .frame(width: 14, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.label).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(s.state).foregroundStyle(s.color)
                    Text(ago(s.statusSince)).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(tilde(s.cwd)).foregroundStyle(.teal).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    Text(money(s.cost)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
                if !s.context.isEmpty {
                    Text("↳ " + s.context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .opacity(s.live ? 1 : 0.55)
        .background(RoundedRectangle(cornerRadius: 6).fill(stopping ? Color.red.opacity(0.25) : selected ? Color.accentColor.opacity(0.25) : hover ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.focus(s) }
        .help("Click to jump to its Ghostty tab")
        .contextMenu {
            Button("Jump to its tab") { store.focus(s) }.disabled(!s.live)
            Button("Details") { showDetail() }
            Button("Open folder in Finder") { store.openFolder(s) }
            Button("Copy resume command") { store.copyResume(s) }
        }
    }
}

struct Detail: View {
    @EnvironmentObject var store: Store
    let s: Session
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Jump") { store.focus(s) }.disabled(!s.live)
                Button("Folder") { store.openFolder(s) }
                Button("Copy resume") { store.copyResume(s) }
            }
            .controlSize(.small)

            Text(s.label).font(.headline).textSelection(.enabled)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                line("session", "\(s.name)  \(s.id)")
                line("status", "\(s.status) for \(ago(s.statusSince)) · started \(ago(s.startedAt)) ago · pid \(s.pid) · v\(s.version)")
                line("folder", tilde(s.cwd))
                line("cost", "\(s.cost == nil ? "—" : money(s.cost))  ·  +\(s.linesAdded) −\(s.linesRemoved) lines")
                ForEach(s.models, id: \.self) { m in
                    line("", "\(m.model): \(m.input.formatted()) in · \(m.output.formatted()) out")
                }
                if s.subagents > 0 { line("subagents", "\(s.subagents) recent sidechain messages") }
                if let t = s.lastTool { line("last tool", t) }
                if let r = s.recap { line("recap", oneLine(r)) }
            }
            .font(.caption)

            if !s.exchanges.isEmpty {
                Divider()
                CappedScroll(max: 220) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(s.exchanges.enumerated()), id: \.offset) { _, e in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(e.who).bold().foregroundStyle(e.who == "you" ? .pink : .blue).frame(width: 44, alignment: .leading)
                                Text(oneLine(e.text)).lineLimit(4).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func line(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).lineLimit(3).textSelection(.enabled)
        }
    }
}

/// A ScrollView as tall as its content, up to `max`. In a menu bar window a
/// plain ScrollView has no height of its own and collapses to nothing.
struct CappedScroll<Content: View>: View {
    let max: CGFloat
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .frame(height: min(height, max))
    }
}
