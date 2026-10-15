import Foundation

public enum Activity: String, Sendable {
    case thinking, working, tool, reading, searching, coding, testing, waiting, completed, failed, interrupted, unknown
    public var isRunning: Bool {
        [.thinking, .working, .tool, .reading, .searching, .coding, .testing, .waiting].contains(self)
    }
    public var label: String {
        switch self {
        case .thinking: "Thinking"
        case .working: "Working"
        case .tool: "Using a tool"
        case .reading: "Reading"
        case .searching: "Searching"
        case .coding: "Coding"
        case .testing: "Testing"
        case .waiting: "Waiting for you"
        case .completed: "Finished"
        case .failed: "Needs attention"
        case .interrupted: "Interrupted"
        case .unknown: "Status unavailable"
        }
    }
}

public struct Session: Identifiable, Sendable, Equatable {
    public var id: String
    public var project = "Codex session"
    public var activity = Activity.unknown
    public var updated = Date.distantPast
    public var started: Date?
    public var turnID: String?
    public var turnActive = false
    public init(id: String) { self.id = id }

    // Deliberately retain no prompts, outputs, tool arguments, or reasoning text.
    public mutating func consume(_ line: Data) {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = record["type"] as? String,
              let payload = record["payload"] as? [String: Any] else { return }
        if kind == "session_meta" {
            if let value = payload["id"] as? String { id = value }
            if let cwd = payload["cwd"] as? String {
                project = URL(fileURLWithPath: cwd).lastPathComponent
            }
            return
        }
        let type = payload["type"] as? String ?? ""
        let timestamp = (record["timestamp"] as? String).flatMap(Self.date) ?? updated
        guard timestamp >= updated else { return }
        if kind == "event_msg" {
            switch type {
            case "task_started":
                activity = .working
                turnActive = true
                started = timestamp
                turnID = payload["turn_id"] as? String
            case "task_complete", "turn_aborted":
                // A delayed completion from an older turn must not end a new turn.
                if let ending = payload["turn_id"] as? String, let turnID, ending != turnID { return }
                activity = type == "task_complete" ? .completed : .interrupted
                turnActive = false
            case "task_failed":
                if let ending = payload["turn_id"] as? String, let turnID, ending != turnID { return }
                activity = .failed
                turnActive = false
            case "item_completed" where turnActive:
                guard let item = payload["item"] as? [String: Any] else { return }
                if let ending = payload["turn_id"] as? String, let turnID, ending != turnID { return }
                switch item["type"] as? String {
                case "Reasoning": activity = .thinking
                case "CommandExecution":
                    let exit = item["exit_code"] as? Int ?? 0
                    activity = exit != 0 ? .failed : Self.commandActivity(item["command"] as? String ?? "")
                case "FileChange":
                    activity = (item["status"] as? String)?.lowercased().contains("fail") == true ? .failed : .coding
                case "McpToolCall": activity = Self.toolActivity(item["tool"] as? String ?? "")
                case "ImageView": activity = .reading
                case "Extension":
                    activity = (item["kind"] as? String)?.lowercased().contains("search") == true ? .searching : .working
                case "UserMessage": activity = .thinking
                case "AgentMessage":
                    activity = (item["questions"] as? [Any])?.isEmpty == false ? .waiting : .working
                default: return
                }
            default: return
            }
        } else if kind == "response_item", turnActive {
            switch type {
            case "reasoning": activity = .thinking
            case "function_call", "custom_tool_call":
                activity = Self.toolActivity(payload["name"] as? String ?? "")
                if activity == .tool, let arguments = payload["arguments"] as? String,
                   let data = arguments.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let cmd = parsed["cmd"] as? String { activity = Self.commandActivity(cmd) }
            case "function_call_output", "custom_tool_call_output":
                // Completion of a tool call is not a new reasoning event.
                return
            case "message": activity = .working
            default: return
            }
        } else { return }
        updated = timestamp
    }

    static func toolActivity(_ name: String) -> Activity {
        let name = name.lowercased()
        if name.contains("request_user_input") { return .waiting }
        if name.contains("search") || name.contains("web__run") { return .searching }
        if name.contains("apply_patch") || name.contains("write_file") || name.contains("edit_file") { return .coding }
        if name.contains("read_file") || name.contains("view_image") || name.contains("fetch") { return .reading }
        return .tool
    }

    // Only command verbs are classified, never retained or displayed. This describes
    // last observed activity, not the current state of an underlying child process.
    static func commandActivity(_ command: String) -> Activity {
        let words = command.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let first = words.first ?? ""
        if ["swift", "npm", "pnpm", "yarn", "cargo", "go", "pytest", "xcodebuild"].contains(first),
           words.contains(where: { ["test", "tests", "pytest"].contains($0) }) || first == "pytest" { return .testing }
        if ["rg", "grep", "find"].contains(first) { return .searching }
        if ["cat", "sed", "head", "tail", "ls"].contains(first) { return .reading }
        if ["swift", "npm", "pnpm", "yarn", "cargo", "xcodebuild"].contains(first),
           words.contains("build") { return .coding }
        return .working
    }

    public static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

/// Incrementally reads local rollout files; this is an experimental adapter, not a public API.
public actor SessionReader {
    struct Cursor {
        var offset: UInt64 = 0
        var pending = Data()
        var session: Session
    }
    private var cursors: [URL: Cursor] = [:]
    public init() {}

    public func scan(root: URL) throws -> [Session] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { throw ReaderError.missingFolder }
        guard manager.isReadableFile(atPath: root.path) else { throw ReaderError.unreadable }
        var enumerationFailed = false
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles], errorHandler: { _, _ in
            enumerationFailed = true
            return true
        }) else { throw ReaderError.unreadable }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, modified))
        }
        if enumerationFailed && files.isEmpty { throw ReaderError.unreadable }
        // Bounds startup work; files newly receiving events naturally enter this set.
        let selected = Set(files.sorted { $0.1 > $1.1 }.prefix(200).map(\.0))
        cursors = cursors.filter { selected.contains($0.key) }
        var readFailures = 0
        for url in selected {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                var cursor = cursors[url] ?? Cursor(session: Session(id: url.lastPathComponent))
                if size < cursor.offset { cursor = Cursor(session: Session(id: url.lastPathComponent)) }
                if cursor.offset == 0 && size > 524_288 {
                    try handle.seek(toOffset: 0)
                    let head = try handle.read(upToCount: 32_768) ?? Data()
                    if let newline = head.firstIndex(of: 10) { cursor.session.consume(head.prefix(upTo: newline)) }
                    cursor.offset = size - 524_288
                    try handle.seek(toOffset: cursor.offset)
                    let tail = try handle.readToEnd() ?? Data()
                    // Drop the first partial line when seeking into the middle of a file.
                    if let newline = tail.firstIndex(of: 10) { cursor.pending = Data(tail.suffix(from: tail.index(after: newline))) }
                } else {
                    try handle.seek(toOffset: cursor.offset)
                    cursor.pending.append(try handle.readToEnd() ?? Data())
                }
                cursor.offset = size
                while let newline = cursor.pending.firstIndex(of: 10) {
                    cursor.session.consume(Data(cursor.pending.prefix(upTo: newline)))
                    cursor.pending.removeSubrange(...newline)
                }
                // Guard against malformed giant unterminated records.
                if cursor.pending.count > 2_097_152 { cursor.pending.removeAll() }
                cursors[url] = cursor
            } catch { readFailures += 1; cursors.removeValue(forKey: url) }
        }
        if !selected.isEmpty && readFailures == selected.count { throw ReaderError.unreadable }
        return cursors.values.map(\.session).sorted {
            if $0.turnActive != $1.turnActive { return $0.turnActive }
            return $0.updated > $1.updated
        }
    }
}

public enum ReaderError: Error { case missingFolder, unreadable }
