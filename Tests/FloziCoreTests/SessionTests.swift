import Foundation
import Testing
@testable import FloziCore

private func event(_ type: String, turn: String = "a") -> Data {
    Data("{\"type\":\"event_msg\",\"timestamp\":\"2026-10-15T09:00:00.000Z\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"\(turn)\"}}".utf8)
}

@Test func lifecycleIgnoresDelayedCompletion() {
    var session = Session(id: "test")
    session.consume(event("task_started"))
    #expect(session.activity == .working)
    session.consume(event("task_started", turn: "b"))
    session.consume(event("task_complete", turn: "a"))
    #expect(session.activity == .working)
    session.consume(event("task_complete", turn: "b"))
    #expect(session.activity == .completed)
}

@Test func toolOutputDoesNotResurrectCompletedTurn() {
    var session = Session(id: "test")
    let tool = Data(#"{"type":"response_item","payload":{"type":"function_call"}}"#.utf8)
    session.consume(tool)
    #expect(session.activity == .unknown)
    session.consume(event("task_started"))
    session.consume(tool)
    #expect(session.activity == .tool)
    session.consume(event("task_complete"))
    session.consume(tool)
    #expect(session.activity == .completed)
    session.consume(Data("malformed".utf8))
    #expect(session.activity == .completed)
}

@Test func readerHandlesPartialLinesAndTruncation() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("session.jsonl")
    let reader = SessionReader()
    let start = event("task_started")
    try start.prefix(20).write(to: file)
    var snapshots = try await reader.scan(root: folder)
    #expect(snapshots[0].activity == .unknown)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: start.dropFirst(20) + Data([10]))
    try handle.close()
    snapshots = try await reader.scan(root: folder)
    #expect(snapshots[0].activity == .working)
    try Data("{}\n".utf8).write(to: file)
    snapshots = try await reader.scan(root: folder)
    #expect(snapshots[0].activity == .unknown)
}

@Test func missingFolderIsReported() async {
    let reader = SessionReader()
    await #expect(throws: ReaderError.self) {
        try await reader.scan(root: URL(fileURLWithPath: "/tmp/flozi-missing-\(UUID().uuidString)"))
    }
}
