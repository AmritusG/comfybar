import XCTest

final class ParseTests: XCTestCase {
    func testSystemStats() throws {
        let s = try ComfyParse.systemStats(Fixture.data("system_stats"))
        XCTAssertEqual(s.comfyVersion, "0.34.0")
        XCTAssertEqual(s.os, "darwin")
        XCTAssertEqual(s.pythonVersion, "3.12.13")
        XCTAssertEqual(s.ramTotal, 137_438_953_472)
        XCTAssertEqual(s.argv, ["main.py"])
        XCTAssertEqual(s.devices.first?.type, "mps")
        // On MPS ComfyUI reports host RAM as "vram" (model_management.py:321, 1758).
        XCTAssertEqual(s.devices.first?.vramTotal, s.ramTotal)
    }

    func testQueueRunningItem() throws {
        let q = try ComfyParse.queue(Fixture.data("queue_running"))
        XCTAssertEqual(q.running.count, 1)
        let r = try XCTUnwrap(q.running.first)
        XCTAssertEqual(r.promptID, "2f4f18bc-51c6-4b47-bc40-cac956324c0f")
        XCTAssertEqual(r.clientID, "b9079a91-1347-4dd9-b7c5-77fced71b566")
        XCTAssertEqual(r.createTimeMs, 1_790_239_413_670)
        XCTAssertEqual(r.outputPrefixes, ["renders/scene1081_b"])
        XCTAssertFalse(r.hasWorkflow)
    }

    func testPendingSortedByNumber() throws {
        let raw = #"{"queue_running": [], "queue_pending": [[7, "b", {}, {}, []], [3, "a", {}, {}, []], [-2, "front", {}, {}, []]]}"#
        let q = try ComfyParse.queue(Data(raw.utf8))
        XCTAssertEqual(q.pending.map(\.promptID), ["front", "a", "b"])
    }

    func testJobsCompletedHaveDurations() throws {
        let jobs = try ComfyParse.jobs(Fixture.data("jobs"))
        XCTAssertEqual(jobs.count, 6)
        XCTAssertEqual(jobs.first?.status, .inProgress)
        XCTAssertNil(jobs.first?.startTimeMs, "a running job carries no start time (jobs.py:186)")
        let done = jobs.filter { $0.status == .completed }
        XCTAssertFalse(done.isEmpty)
        for j in done { XCTAssertNotNil(j.durationSeconds) }
        let j = try XCTUnwrap(jobs.first { $0.id == "8cff32d1-80a1-4130-b249-e94666ae956d" })
        XCTAssertEqual(j.durationSeconds!, 333.68, accuracy: 0.01)  // log said "Prompt executed in 333.68 seconds"
        XCTAssertEqual(j.previewFilename, "scene1081_a_00001_.mp4")
    }

    func testJobsCancelled() throws {
        let jobs = try ComfyParse.jobs(Fixture.data("jobs_with_cancelled"))
        XCTAssertEqual(jobs.first?.status, .cancelled)
        XCTAssertTrue(jobs.first!.status.isFinished)
    }

    func testLogsRaw() throws {
        let e = try ComfyParse.logsRaw(Fixture.data("logs_raw"))
        XCTAssertEqual(e.count, 40)
        XCTAssertNotNil(e.last?.time)
    }

    func testSocketMessages() throws {
        let arr = try XCTUnwrap(Fixture.json("ws_broadcast_interrupted") as? [[String: Any]])
        let msgs = try arr.map { d -> SocketMessage in
            let s = String(decoding: try JSONSerialization.data(withJSONObject: d), as: UTF8.self)
            return try XCTUnwrap(ComfyParse.socketMessage(s))
        }
        XCTAssertTrue(msgs.contains { if case .status = $0 { return true } else { return false } })
        let progress = msgs.compactMap { m -> (Int, Int, String?)? in
            if case let .progress(v, mx, _, node) = m { return (v, mx, node) } else { return nil }
        }
        XCTAssertFalse(progress.isEmpty, "a prompt without client_id broadcasts progress")
        XCTAssertEqual(progress.first?.1, 300)
        XCTAssertEqual(progress.first?.2, "3", "node id of the ColorTransfer stage in the probe graph")
        XCTAssertTrue(msgs.contains { if case .executionInterrupted = $0 { return true } else { return false } })
    }
}
