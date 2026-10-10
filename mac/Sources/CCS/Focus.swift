// Brings a session's terminal to the front, the same way src/focus.js does.
// Ghostty only, through its AppleScript dictionary: its terminals expose a
// title and a working directory, not a tty or pid, so a session is matched by
// the title Claude Code gives its tab (a status glyph, then the session's
// title), then by folder.
import Foundation

private struct Terminal {
    let id: String
    let title: String
    let cwd: String
}

private func run(_ source: String) throws -> String {
    var err: NSDictionary?
    let out = NSAppleScript(source: source)?.executeAndReturnError(&err)
    if let err { throw NSError(domain: "CCS", code: 1, userInfo: [NSLocalizedDescriptionKey: err[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"]) }
    return out?.stringValue ?? ""
}

private func ghosttyTerminals() throws -> [Terminal] {
    let out = try run("""
    tell application "Ghostty"
      set out to ""
      set sep to character id 9
      repeat with t in terminals
        set out to out & (id of t) & sep & (name of t) & sep & (working directory of t) & linefeed
      end repeat
      return out
    end tell
    """)
    return out.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3 else { return nil }
        let title = f[1].drop { !$0.isLetter && !$0.isNumber }.trimmingCharacters(in: .whitespaces)
        return Terminal(id: f[0], title: title, cwd: f[2])
    }
}

/// `sessions` is every live session, so a folder match can skip terminals that
/// another session's title already claims.
func focusSession(_ s: Session, among sessions: [Session]) throws -> Bool {
    let terms = try ghosttyTerminals()
    var t = s.title.flatMap { title in terms.first { $0.title == title } }
    if t == nil {
        let claimed = Set(sessions.filter { $0.id != s.id }.compactMap(\.title))
        let inDir = terms.filter { $0.cwd == s.cwd && !claimed.contains($0.title) && $0.title != "ccs" }
        if inDir.count == 1 { t = inDir[0] }
    }
    guard let t else { return false }
    let id = t.id.replacingOccurrences(of: "\"", with: "")
    _ = try run("""
    tell application "Ghostty"
      focus (first terminal whose id is "\(id)")
      activate
    end tell
    """)
    return true
}
