import Foundation
import Testing
@testable import FloziCore

private func json(_ value: String) -> Data { Data(value.utf8) }
private func started() -> Session {
    var session = Session(id: "a")
    session.consume(json(#"{"type":"event_msg","timestamp":"2026-10-15T09:00:00Z","payload":{"type":"task_started","turn_id":"a"}}"#))
    return session
}

@Test func failedToolKeepsTurnAliveAndCanRecover() {
    var session = started()
    session.consume(json(#"{"type":"event_msg","payload":{"type":"item_completed","turn_id":"a","item":{"type":"CommandExecution","command":"swift test","exit_code":1}}}"#))
    #expect(session.activity == .failed)
    #expect(session.turnActive)
    session.consume(json(#"{"type":"event_msg","payload":{"type":"item_completed","turn_id":"a","item":{"type":"FileChange","status":"completed"}}}"#))
    #expect(session.activity == .coding)
    #expect(session.turnActive)
    session.consume(json(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"a"}}"#))
    #expect(!session.turnActive)
    #expect(session.activity == .completed)
}

@Test func observedReasoningAndCommandClassification() {
    var session = started()
    session.consume(json(#"{"type":"response_item","payload":{"type":"reasoning","encrypted_content":"ignored"}}"#))
    #expect(session.activity == .thinking)
    session.consume(json(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","command":"swift test","exit_code":0}}}"#))
    #expect(session.activity == .testing)
    session.consume(json(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","command":"cat README.md","exit_code":0}}}"#))
    #expect(session.activity == .reading)
    session.consume(json(#"{"type":"response_item","payload":{"type":"function_call","name":"web__run"}}"#))
    #expect(session.activity == .searching)
}

@Test func completedAndOlderEventsCannotResurrectTurn() {
    var session = started()
    session.consume(json(#"{"type":"event_msg","timestamp":"2026-10-15T09:01:00Z","payload":{"type":"task_complete","turn_id":"a"}}"#))
    session.consume(json(#"{"type":"event_msg","timestamp":"2026-10-15T09:00:00Z","payload":{"type":"task_started","turn_id":"a"}}"#))
    #expect(!session.turnActive)
    session.consume(json(#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning"}}}"#))
    #expect(session.activity == .completed)
}

@Test func staleActivityIsUncertainAndConnectionLossWins() {
    let session = started()
    let now = session.updated.addingTimeInterval(601)
    #expect(CompanionMode.resolve(sessions: [session], connected: true, now: now, idleSince: now) == .uncertain)
    #expect(CompanionMode.resolve(sessions: [session], connected: false, now: now, idleSince: now) == .offline)
}

@Test func activeTaskWinsOverAnotherTasksCelebration() {
    let active = started()
    var done = started()
    done.id = "b"
    done.activity = .completed
    done.turnActive = false
    #expect(CompanionMode.resolve(sessions: [done, active], connected: true, now: active.updated, idleSince: active.updated) == .working)
    var waiting = active
    waiting.id = "c"
    waiting.activity = .waiting
    #expect(CompanionMode.resolve(sessions: [active, waiting], connected: true, now: active.updated, idleSince: active.updated) == .waiting)
}

@Test func celebrationExpiresAndSleepWaitsForInactivity() {
    var session = started()
    session.activity = .completed
    session.turnActive = false
    let time = session.updated
    #expect(CompanionMode.resolve(sessions: [session], connected: true, now: time.addingTimeInterval(2), idleSince: time) == .success)
    #expect(CompanionMode.resolve(sessions: [session], connected: true, now: time.addingTimeInterval(13), idleSince: time) == .idle)
    #expect(CompanionMode.resolve(sessions: [session], connected: true, now: time.addingTimeInterval(91), idleSince: time) == .sleeping)
}
