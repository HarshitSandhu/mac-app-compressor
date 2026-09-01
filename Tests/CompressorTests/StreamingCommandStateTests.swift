import XCTest
@testable import Compressor

private struct ProgressEvent: Equatable {
    let title: String
    let detail: String
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProgressEvent] = []

    func record(title: String, detail: String) {
        lock.lock()
        events.append(ProgressEvent(title: title, detail: detail))
        lock.unlock()
    }

    var recorded: [ProgressEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var titles: [String] {
        recorded.map { $0.title }
    }
}

final class StreamingCommandStateTests: XCTestCase {
    private func makeProgress(
        _ recorder: ProgressRecorder
    ) -> @Sendable (String, String) -> Void {
        { title, detail in
            recorder.record(title: title, detail: detail)
        }
    }

    func testDecodesMultiByteCharacterSplitAcrossReads() throws {
        let state = StreamingCommandState()
        let recorder = ProgressRecorder()

        // "Café.app" - é is two bytes, and the pipe read is cut between them.
        var line = Data(#"{"event":"progress","title":"Compressing Café.app","detail":"Working."}"#.utf8)
        line.append(0x0A)

        let splitIndex = try XCTUnwrap(line.firstIndex(of: 0xC3), "fixture should contain a multi-byte character")

        state.appendStdout(line[line.startIndex...splitIndex], progress: makeProgress(recorder))
        state.appendStdout(line[line.index(after: splitIndex)...], progress: makeProgress(recorder))

        XCTAssertEqual(recorder.titles, ["Compressing Café.app"])
        XCTAssertNil(state.snapshot().error)
    }

    func testParsesMultipleEventsArrivingInOneRead() {
        let state = StreamingCommandState()
        let recorder = ProgressRecorder()

        let payload = """
        {"event":"progress","title":"One","detail":"First."}
        {"event":"progress","title":"Two","detail":"Second."}

        """
        state.appendStdout(Data(payload.utf8), progress: makeProgress(recorder))

        XCTAssertEqual(recorder.titles, ["One", "Two"])
        XCTAssertNil(state.snapshot().error)
    }

    func testTrailingLineWithoutNewlineIsParsedOnFinish() {
        let state = StreamingCommandState()
        let recorder = ProgressRecorder()
        let progress = makeProgress(recorder)

        let line = #"{"event":"progress","title":"Last","detail":"No newline."}"#
        state.appendStdout(Data(line.utf8), progress: progress)
        XCTAssertTrue(recorder.titles.isEmpty)

        state.finish(progress: progress)
        XCTAssertEqual(recorder.titles, ["Last"])
    }

    func testResultEventIsCaptured() {
        let state = StreamingCommandState()
        let payload = """
        {"event":"result","app":{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","displayName":"Foo.app",\
        "bundleIdentifier":null,"originalPath":"/Applications/Foo.app","archivePath":"/archives/foo.dmg",\
        "originalSizeBytes":100,"archiveSizeBytes":40,"createdAt":"2026-01-01T00:00:00Z",\
        "lastRestoredAt":null,"status":"archived"}}

        """
        state.appendStdout(Data(payload.utf8), progress: nil)

        let snapshot = state.snapshot()
        XCTAssertNil(snapshot.error)
        XCTAssertTrue(snapshot.sawResult)
        XCTAssertEqual(snapshot.app?.displayName, "Foo.app")
        XCTAssertEqual(snapshot.app?.archiveSizeBytes, 40)
    }
}
