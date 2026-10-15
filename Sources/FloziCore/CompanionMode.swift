import Foundation

public enum CompanionMode: String, CaseIterable, Identifiable, Sendable {
    case idle, thinking, working, reading, searching, coding, testing, waiting
    case success, error, interrupted, sleeping, offline, uncertain
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .idle: "Idle"; case .thinking: "Thinking"; case .working: "Working"
        case .reading: "Reading"; case .searching: "Searching"; case .coding: "Coding"
        case .testing: "Testing"; case .waiting: "Waiting for you"; case .success: "All done!"
        case .error: "Needs attention"; case .interrupted: "Interrupted"; case .sleeping: "Sleeping"
        case .offline: "Disconnected"; case .uncertain: "Status uncertain"
        }
    }
    public var caption: String {
        switch self {
        case .idle: "Here whenever you need me."
        case .thinking: "A little thinking is happening."
        case .working: "Keeping you company while Codex works."
        case .reading: "Taking a closer look."
        case .searching: "Looking for the missing piece."
        case .coding: "Making something, one little step at a time."
        case .testing: "Checking that the pieces fit."
        case .waiting: "Your turn, when you’re ready."
        case .success: "A little victory for your day."
        case .error: "Something may need a closer look."
        case .interrupted: "Taking a pause."
        case .sleeping: "A tiny nap until the next task."
        case .offline: "I can’t see local Codex activity right now."
        case .uncertain: "No fresh event. The task may still be running."
        }
    }
    public var spriteIndex: Int {
        switch self {
        case .idle: 0; case .thinking: 1; case .working: 2; case .reading: 3
        case .searching: 4; case .coding: 5; case .testing: 6; case .waiting: 7
        case .success: 8; case .error: 9; case .interrupted: 10; case .sleeping: 11
        case .offline: 12; case .uncertain: 13
        }
    }
    public var animated: Bool { ![.sleeping, .offline, .uncertain].contains(self) }

    public static func resolve(sessions: [Session], connected: Bool, now: Date, idleSince: Date) -> Self {
        guard connected else { return .offline }
        let active = sessions.filter { $0.turnActive && now.timeIntervalSince($0.updated) < 600 }
        let priority: [Activity] = [.failed, .waiting, .testing, .coding, .searching, .reading, .thinking, .tool, .working]
        for activity in priority where active.contains(where: { $0.activity == activity }) {
            switch activity {
            case .failed: return .error
            case .waiting: return .waiting
            case .testing: return .testing
            case .coding: return .coding
            case .searching: return .searching
            case .reading: return .reading
            case .thinking: return .thinking
            default: return .working
            }
        }
        if sessions.contains(where: { $0.turnActive }) { return .uncertain }
        if let latest = sessions.max(by: { $0.updated < $1.updated }), now.timeIntervalSince(latest.updated) < 12 {
            switch latest.activity {
            case .completed: return .success
            case .failed: return .error
            case .interrupted: return .interrupted
            default: break
            }
        }
        let lastActivity = max(idleSince, sessions.map(\.updated).max() ?? .distantPast)
        return now.timeIntervalSince(lastActivity) > 90 ? .sleeping : .idle
    }
}
