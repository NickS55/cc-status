// Polls the session files, watches the folder for changes, and pings when a
// session goes from busy to idle (finished, or waiting on you).
import AppKit
import UserNotifications

@MainActor
final class Store: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published var flash = ""
    /// Bumped each time the panel opens, so it can reset its selection.
    @Published var opened = 0
    @Published var showDead = UserDefaults.standard.bool(forKey: "showDead") {
        didSet { UserDefaults.standard.set(showDead, forKey: "showDead") }
    }
    @Published var sound = UserDefaults.standard.object(forKey: "sound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sound, forKey: "sound") }
    }
    @Published var notify = UserDefaults.standard.bool(forKey: "notify") {
        didSet {
            UserDefaults.standard.set(notify, forKey: "notify")
            if notify { requestNotifications() }
        }
    }
    @Published var soundName = UserDefaults.standard.string(forKey: "soundName") ?? "Glass" {
        didSet { UserDefaults.standard.set(soundName, forKey: "soundName") }
    }

    @Published var shortcut = UserDefaults.standard.string(forKey: "shortcut") ?? Shortcut.presets[0].label {
        didSet { UserDefaults.standard.set(shortcut, forKey: "shortcut") }
    }

    let soundNames: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()

    private let reader = SessionReader()
    private var prev: [String: String] = [:]
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var flashTask: Task<Void, Never>?

    var shown: [Session] { sessions.filter { showDead || $0.live } }
    var liveCount: Int { sessions.filter(\.live).count }
    var busyCount: Int { sessions.filter(\.busy).count }

    init() {
        sessions = reader.load()
        prev = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.status) })
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        watch()
        if notify { requestNotifications() }
    }

    private func watch() {
        let fd = open(SessionReader.sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return } // polling covers it
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                self?.refresh()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    func refresh() {
        let next = reader.load()
        let finished = next.filter { prev[$0.id] == "busy" && !$0.busy && $0.live }
        prev = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0.status) })
        if !finished.isEmpty {
            if sound { ping() }
            if notify { finished.forEach(post) }
            say("✔ ready: \(finished.map(\.label).joined(separator: ", "))")
        }
        sessions = next
    }

    func say(_ m: String) {
        flash = m
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { flash = "" }
        }
    }

    func ping() {
        NSSound(named: NSSound.Name(soundName))?.play()
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(_ s: Session) {
        let c = UNMutableNotificationContent()
        c.title = "Claude is ready"
        c.subtitle = s.name
        c.body = s.label
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // Actions

    func focus(_ s: Session) {
        guard s.live else { return say("that session has ended") }
        do {
            let ok = try focusSession(s, among: sessions.filter(\.live))
            say(ok ? "→ \(s.label)" : "couldn't find its terminal window")
        } catch {
            say("couldn't focus: \(error.localizedDescription)")
        }
    }

    func openFolder(_ s: Session) {
        NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd))
    }

    func copyResume(_ s: Session) {
        let quoted = "'" + s.cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("cd \(quoted) && claude --resume \(s.id)", forType: .string)
        say("copied resume command")
    }
}
