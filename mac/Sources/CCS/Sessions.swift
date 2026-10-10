// Everything that knows Claude Code's on-disk layout lives here, the same as
// src/sessions.js for the CLI. None of it is a documented API, so if an update
// breaks the app, this is the file to fix.
import Foundation

struct Exchange: Hashable {
    let who: String // "you" or "claude"
    var text: String
}

struct ModelUsage: Hashable {
    let model: String
    let input: Int
    let output: Int
}

struct Session: Identifiable, Hashable {
    let id: String
    let pid: Int32
    let name: String
    let cwd: String
    let version: String
    let procStart: String? // when the process started, to tell it from a reused pid
    let startedAt: Date
    let live: Bool
    let status: String // busy, idle, dead, unknown
    let statusSince: Date
    var title: String?
    var lastPrompt: String?
    var lastTool: String?
    var recap: String?
    var cost: Double?
    var linesAdded = 0
    var linesRemoved = 0
    var models: [ModelUsage] = []
    var subagents = 0
    var exchanges: [Exchange] = []
    var pushed = false

    var busy: Bool { status == "busy" }
    var label: String { title ?? name }
}

private struct TranscriptInfo {
    var title: String?
    var lastPrompt: String?
    var lastTool: String?
    var recap: String?
    var cost: Double?
    var linesAdded = 0
    var linesRemoved = 0
    var models: [ModelUsage] = []
    var subagents = 0
    var exchanges: [Exchange] = []
    var pushed = false // the last thing Claude did was a git push that worked
}

final class SessionReader {
    static let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    static let sessionsDir: URL = {
        if let dir = ProcessInfo.processInfo.environment["CCS_SESSIONS_DIR"] { return URL(fileURLWithPath: dir) }
        return claudeDir.appendingPathComponent("sessions")
    }()
    private let projectsDir = claudeDir.appendingPathComponent("projects")
    private let tailBytes = 256 * 1024
    private let fm = FileManager.default

    private var transcriptPaths: [String: URL] = [:]
    private var titles: [String: String?] = [:] // the ai title can sit far back in the file
    private var tails: [String: (size: Int, mtime: Date, info: TranscriptInfo)] = [:]

    private func alive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func findTranscript(_ sessionId: String, cwd: String) -> URL? {
        if let cached = transcriptPaths[sessionId], fm.fileExists(atPath: cached.path) { return cached }
        let file = "\(sessionId).jsonl"
        let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        var found: URL? = projectsDir.appendingPathComponent(folder).appendingPathComponent(file)
        if !fm.fileExists(atPath: found!.path) {
            found = nil
            for dir in (try? fm.contentsOfDirectory(atPath: projectsDir.path)) ?? [] {
                let p = projectsDir.appendingPathComponent(dir).appendingPathComponent(file)
                if fm.fileExists(atPath: p.path) { found = p; break }
            }
        }
        if let found { transcriptPaths[sessionId] = found }
        return found
    }

    private func readTail(_ url: URL, size: Int) -> [Substring] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let start = max(0, size - tailBytes)
        try? h.seek(toOffset: UInt64(start))
        let data = (try? h.read(upToCount: size - start)) ?? Data()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // first line is probably cut in half
        return lines
    }

    private func parse<S: StringProtocol>(_ lines: [S]) -> [[String: Any]] {
        lines.compactMap { l in
            guard !l.isEmpty, let d = l.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
    }

    private func textOf(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: " ")
    }

    private func describeTool(_ t: [String: Any]) -> String {
        let name = t["name"] as? String ?? "tool"
        let i = t["input"] as? [String: Any] ?? [:]
        let arg = ["description", "command", "file_path", "pattern", "url", "prompt"]
            .lazy.compactMap { i[$0] as? String }.first { !$0.isEmpty } ?? ""
        let first = arg.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return first.isEmpty ? name : "\(name): \(first)"
    }

    private func isPush(_ t: [String: Any]) -> Bool {
        guard t["name"] as? String == "Bash",
              let cmd = (t["input"] as? [String: Any])?["command"] as? String else { return false }
        return cmd.range(of: #"\bgit\s+push\b"#, options: .regularExpression) != nil
    }

    private func summarize(_ entries: [[String: Any]]) -> TranscriptInfo {
        var info = TranscriptInfo()
        var pushId: String? // the last tool call, if it was a push
        for d in entries {
            let type = d["type"] as? String
            if type == "ai-title" {
                info.title = d["aiTitle"] as? String
            } else if type == "last-prompt" {
                info.lastPrompt = d["lastPrompt"] as? String
            } else if type == "system", d["subtype"] as? String == "away_summary" {
                info.recap = d["content"] as? String
            } else if type == "cost-state" {
                info.cost = d["totalCostUSD"] as? Double
                info.linesAdded = d["totalLinesAdded"] as? Int ?? 0
                info.linesRemoved = d["totalLinesRemoved"] as? Int ?? 0
                let usage = d["modelUsage"] as? [String: [String: Any]] ?? [:]
                info.models = usage.map { m, u in
                    let n = { (k: String) in u[k] as? Int ?? 0 }
                    return ModelUsage(model: m,
                                      input: n("inputTokens") + n("cacheReadInputTokens") + n("cacheCreationInputTokens"),
                                      output: n("outputTokens"))
                }.sorted { $0.model < $1.model }
            } else if d["isSidechain"] as? Bool == true {
                info.subagents += 1
            } else if type == "user", d["isMeta"] as? Bool != true,
                      let t = (d["message"] as? [String: Any])?["content"] as? String {
                let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !t.hasPrefix("<") {
                    info.exchanges.append(Exchange(who: "you", text: t))
                    info.recap = nil // a new prompt makes the older recap stale
                    info.pushed = false
                    pushId = nil
                }
            } else if type == "user", let id = pushId,
                      let parts = (d["message"] as? [String: Any])?["content"] as? [[String: Any]],
                      let r = parts.first(where: { $0["tool_use_id"] as? String == id }) {
                info.pushed = r["is_error"] as? Bool != true
            } else if type == "assistant" {
                let content = (d["message"] as? [String: Any])?["content"]
                for c in content as? [[String: Any]] ?? [] where c["type"] as? String == "tool_use" {
                    info.lastTool = describeTool(c)
                    pushId = isPush(c) ? c["id"] as? String : nil
                    info.pushed = false
                }
                let t = textOf(content).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty {
                    if info.exchanges.last?.who == "claude" { info.exchanges[info.exchanges.count - 1].text = t }
                    else { info.exchanges.append(Exchange(who: "claude", text: t)) }
                }
            }
        }
        info.exchanges = Array(info.exchanges.suffix(6))
        return info
    }

    private func transcriptInfo(_ sessionId: String, cwd: String) -> TranscriptInfo? {
        guard let url = findTranscript(sessionId, cwd: cwd),
              let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        if let prev = tails[sessionId], prev.size == size, prev.mtime == mtime { return prev.info }

        var info = summarize(parse(readTail(url, size: size)))
        if let t = info.title {
            titles[sessionId] = t
        } else if titles[sessionId] == nil {
            // Not in the tail: look once through the whole file, then remember it.
            var title: String?
            if size > tailBytes, size < 50 * 1024 * 1024,
               let all = try? String(contentsOf: url, encoding: .utf8) {
                for d in parse(all.split(separator: "\n")) where d["type"] as? String == "ai-title" {
                    title = d["aiTitle"] as? String
                }
            }
            titles[sessionId] = .some(title)
        }
        info.title = titles[sessionId] ?? nil
        tails[sessionId] = (size, mtime, info)
        return info
    }

    func load() -> [Session] {
        let dir = Self.sessionsDir
        var out: [Session] = []
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f)),
                  let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = s["sessionId"] as? String else { continue }
            let pid = Int32(s["pid"] as? Int ?? 0)
            let live = pid > 0 && alive(pid)
            let ms = { (k: String) in (s[k] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
            let started = ms("startedAt") ?? .distantPast
            let cwd = s["cwd"] as? String ?? ""
            var session = Session(
                id: id, pid: pid,
                name: (s["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(id.prefix(8)),
                cwd: cwd,
                version: s["version"] as? String ?? "",
                procStart: s["procStart"] as? String,
                startedAt: started,
                live: live,
                status: live ? s["status"] as? String ?? "unknown" : "dead",
                statusSince: ms("statusUpdatedAt") ?? ms("updatedAt") ?? started)
            if let t = transcriptInfo(id, cwd: cwd) {
                session.title = t.title
                session.lastPrompt = t.lastPrompt
                session.lastTool = t.lastTool
                session.recap = t.recap
                session.cost = t.cost
                session.linesAdded = t.linesAdded
                session.linesRemoved = t.linesRemoved
                session.models = t.models
                session.subagents = t.subagents
                session.exchanges = t.exchanges
                session.pushed = t.pushed
            }
            out.append(session)
        }
        // Live sessions by their last status change, so one that just finished
        // comes first; ended ones after them.
        return out.sorted { $0.live != $1.live ? $0.live : $0.statusSince > $1.statusSince }
    }
}
