import XCTest

final class TqdmTests: XCTestCase {
    func testParseLiveLine() throws {
        let p = try XCTUnwrap(Tqdm.parse("\r 38%|████████████████▌                           | 3/8 [00:24<00:39,  7.99s/it]"))
        XCTAssertEqual(p.percent, 38)
        XCTAssertEqual(p.current, 3)
        XCTAssertEqual(p.total, 8)
        XCTAssertEqual(p.elapsedSeconds, 24)
        XCTAssertEqual(p.remainingSeconds, 39)
        XCTAssertEqual(p.rate, "7.99s/it")
    }

    func testParseHoursAndUnknownRemaining() throws {
        let p = try XCTUnwrap(Tqdm.parse("\r  0%|          | 0/20 [1:02:03<?, ?it/s]"))
        XCTAssertEqual(p.elapsedSeconds, 3723)
        XCTAssertNil(p.remainingSeconds)
        XCTAssertNil(Tqdm.parse("\u{1B}[32m[INFO]\u{1B}[0m got prompt\n"))
    }

    func testLatestFromRecordedBuffer() throws {
        let e = try ComfyParse.logsRaw(Fixture.data("logs_raw"))
        let p = try XCTUnwrap(Tqdm.latest(in: e, notBefore: nil))
        XCTAssertEqual(p.current, 2)
        XCTAssertEqual(p.total, 3)
        XCTAssertEqual(p.remainingSeconds, 58)
        XCTAssertFalse(p.closed)
    }

    func testClosedBarAndNotBefore() throws {
        let t0 = Date(timeIntervalSince1970: 1000)
        let entries = [
            LogEntry(time: t0, message: "\r100%|█| 8/8 [01:02<00:00,  7.75s/it]"),
            LogEntry(time: t0.addingTimeInterval(1), message: "\n"),
        ]
        let p = try XCTUnwrap(Tqdm.latest(in: entries, notBefore: nil))
        XCTAssertTrue(p.closed)
        XCTAssertNil(Tqdm.latest(in: entries, notBefore: t0.addingTimeInterval(5)),
                     "a bar older than the running job's start is never attributed to it")
    }
}

final class AttributionTests: XCTestCase {
    private func item(prefixes: [String] = [], client: String? = "c1", workflow: Bool = false) -> QueueItem {
        QueueItem(number: 1, promptID: "p", clientID: client, createTimeMs: 0, outputPrefixes: prefixes, hasWorkflow: workflow, nodeCount: 1)
    }

    func testRecordedQueueIsAnotherClient() throws {
        let q = try ComfyParse.queue(Fixture.data("queue_running"))
        let s = Attribution.source(of: q.running[0], comfyBarClientID: "mine")
        XCTAssertEqual(s, .otherClient(clientID: "b9079a91-1347-4dd9-b7c5-77fced71b566"))
        XCTAssertEqual(s.evidence, "client_id b9079a91…")
    }

    func testOthers() {
        XCTAssertEqual(Attribution.source(of: item(workflow: true), comfyBarClientID: nil).label, "ComfyUI page")
        XCTAssertEqual(Attribution.source(of: item(client: "mine"), comfyBarClientID: "mine"), .comfyBar)
        XCTAssertEqual(Attribution.source(of: item(client: nil), comfyBarClientID: "mine"), .noClientID)
        XCTAssertEqual(Attribution.source(of: item(client: "zz"), comfyBarClientID: "mine"), .otherClient(clientID: "zz"))
    }
}

final class StateMachineTests: XCTestCase {
    private func obs(_ r: Reachability, listening: Bool? = true, running: Int = 0, pending: Int = 0, failure: Bool = false) -> Observation {
        Observation(reachability: r, processListening: listening, runningCount: running, pendingCount: pending, unacknowledgedFailure: failure)
    }

    func testIconStates() {
        XCTAssertEqual(StateMachine.iconState(obs(.refused, listening: false)), .notRunning)
        XCTAssertEqual(StateMachine.iconState(obs(.refused, listening: nil)), .notRunning)
        XCTAssertEqual(StateMachine.iconState(obs(.refused, listening: true)), .error)
        XCTAssertEqual(StateMachine.iconState(obs(.failed("timed out"))), .error)
        XCTAssertEqual(StateMachine.iconState(obs(.up)), .idle)
        XCTAssertEqual(StateMachine.iconState(obs(.up, running: 1)), .running)
        XCTAssertEqual(StateMachine.iconState(obs(.up, running: 1, pending: 2)), .queued)
        XCTAssertEqual(StateMachine.iconState(obs(.up, pending: 1)), .queued)
        XCTAssertEqual(StateMachine.iconState(obs(.up, failure: true)), .error)
        XCTAssertEqual(StateMachine.iconState(obs(.up, running: 1, failure: true)), .running)
    }

    func testWentDown() {
        XCTAssertTrue(StateMachine.wentDown(from: .up, to: .refused))
        XCTAssertTrue(StateMachine.wentDown(from: .up, to: .failed("x")))
        XCTAssertFalse(StateMachine.wentDown(from: nil, to: .refused), "not running at launch is not 'went down'")
        XCTAssertFalse(StateMachine.wentDown(from: .refused, to: .refused))
    }

    func testNewlyFinished() throws {
        let jobs = try ComfyParse.jobs(Fixture.data("jobs_with_cancelled"))
        let all = Set(jobs.map(\.id))
        // seen active last poll -> announced
        var f = StateMachine.newlyFinished(previouslyActive: [jobs[0].id, "gone"], known: all.subtracting([jobs[0].id]),
                                           watchingSinceMs: .max, now: jobs)
        XCTAssertEqual(f.map(\.id), [jobs[0].id])
        // queued and finished between two polls (never seen active) -> announced
        let created = jobs[0].createTimeMs!
        f = StateMachine.newlyFinished(previouslyActive: [], known: all.subtracting([jobs[0].id]),
                                       watchingSinceMs: created, now: jobs)
        XCTAssertEqual(f.map(\.id), [jobs[0].id])
        // old history scrolling into the listing -> not announced
        f = StateMachine.newlyFinished(previouslyActive: [], known: [], watchingSinceMs: created + 1, now: jobs)
        XCTAssertTrue(f.isEmpty)
        // already announced -> not again
        f = StateMachine.newlyFinished(previouslyActive: [jobs[0].id], known: all, watchingSinceMs: 0, now: jobs)
        XCTAssertTrue(f.isEmpty)
    }

    func testDebounce() {
        XCTAssertEqual(StateMachine.debounce(previous: .up, raw: .failed("timeout"), consecutiveFailures: 1), .up)
        XCTAssertEqual(StateMachine.debounce(previous: .up, raw: .failed("timeout"), consecutiveFailures: 2), .up)
        XCTAssertEqual(StateMachine.debounce(previous: .up, raw: .failed("timeout"), consecutiveFailures: 3), .failed("timeout"))
        XCTAssertEqual(StateMachine.debounce(previous: .up, raw: .refused, consecutiveFailures: 1), .refused)
        XCTAssertEqual(StateMachine.debounce(previous: nil, raw: .failed("x"), consecutiveFailures: 1), .failed("x"))
    }

    /// The derived start of a running job, checked against ComfyUI's own execution_start
    /// timestamps for every recorded completed job.
    func testStartEstimateAgainstRecordedHistory() throws {
        for name in ["jobs", "jobs_8199", "jobs_with_cancelled"] {
            let jobs = try ComfyParse.jobs(Fixture.data(name)).filter { $0.status.isFinished }
            for (i, j) in jobs.enumerated() {
                let older = Array(jobs[(i + 1)...])
                guard !older.isEmpty, let actual = j.startTimeMs else { continue }
                let est = try XCTUnwrap(StateMachine.estimateStart(createTimeMs: j.createTimeMs, finishedJobs: older,
                                                                   seenRunningAt: nil, seenPendingBefore: false))
                let err = abs(est.date.timeIntervalSince1970 - Double(actual) / 1000)
                XCTAssertLessThan(err, 1.0, "\(name) \(j.id): derived start off by \(err)s (\(est.basis))")
            }
        }
    }

    func testSightingBoundsEstimate() {
        let seen = Date(timeIntervalSince1970: 2000)
        let e = StateMachine.estimateStart(createTimeMs: 1_999_000, finishedJobs: [], seenRunningAt: seen, seenPendingBefore: true)
        XCTAssertEqual(e?.date, Date(timeIntervalSince1970: 1999))
        let late = StateMachine.estimateStart(createTimeMs: 2_500_000, finishedJobs: [], seenRunningAt: seen, seenPendingBefore: true)
        XCTAssertEqual(late?.date, seen)
    }
}

final class GuardAndTextTests: XCTestCase {
    func testLaunchGuard() throws {
        XCTAssertEqual(try LaunchGuard.arguments(port: 8199, host: "127.0.0.1", extra: "--cpu  --disable-all-custom-nodes"),
                       ["main.py", "--port", "8199", "--cpu", "--disable-all-custom-nodes"])
        // argparse abbreviations (allow_abbrev) are the same option - all refused
        for bad in ["--listen", "--listen=0.0.0.0", "--LISTEN", "--port 9000", "--tls-keyfile k", "--enable-cors-header", "0.0.0.0",
                    "--lis", "--l", "--liste", "--liste=10.0.0.2", "--po 9000", "--po=9000", "--por=9000",
                    "--tls-c", "--enable-cors", "--enable-cor", "--cpu --lis"] {
            XCTAssertThrowsError(try LaunchGuard.arguments(port: 8199, host: "127.0.0.1", extra: bad), bad)
        }
        for fine in ["--lowvram", "--preview-method auto", "--disable-all-custom-nodes", "--output-directory /tmp/o"] {
            XCTAssertNoThrow(try LaunchGuard.arguments(port: 8199, host: "127.0.0.1", extra: fine), fine)
        }
        XCTAssertThrowsError(try LaunchGuard.arguments(port: 8199, host: "192.168.1.5", extra: ""))
        XCTAssertThrowsError(try LaunchGuard.arguments(port: 80, host: "localhost", extra: ""))
    }

    func testStopNamesTheRunningJob() throws {
        let q = try ComfyParse.queue(Fixture.data("queue_running"))
        let r = RunningJobInfo(promptID: q.running[0].promptID,
                               source: Attribution.source(of: q.running[0], comfyBarClientID: nil), elapsedSeconds: 125)
        let t = try XCTUnwrap(Confirmations.text(for: .stop, hostPort: "127.0.0.1:8188", running: r, pendingCount: 1))
        XCTAssertEqual(t.title, "Stop ComfyUI?")
        XCTAssertTrue(t.body.contains("This ends the running job 2f4f18bc… (running 2m 05s), queued by another client (client_id b9079a91…)"), t.body)
        XCTAssertTrue(t.body.contains("1 queued job will be lost"), t.body)
    }

    func testNothingToConfirm() {
        XCTAssertNil(Confirmations.text(for: .interrupt, hostPort: "h", running: nil, pendingCount: 3))
        XCTAssertNil(Confirmations.text(for: .clear, hostPort: "h", running: nil, pendingCount: 0))
        XCTAssertNotNil(Confirmations.text(for: .stop, hostPort: "h", running: nil, pendingCount: 0), "Stop always asks")
    }

    func testCalibrationGraph() throws {
        let g = Calibration.graph(frames: 50, stages: 3, seed: 7)
        XCTAssertEqual(g.count, 2 + 3 + 2)
        let save = try XCTUnwrap(g["save"] as? [String: Any])
        XCTAssertEqual((save["inputs"] as? [String: Any])?["filename_prefix"] as? String, "comfybar_calibration/calib")
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: g))
    }

    func testLoopbackAddress() {
        for a in ["127.0.0.1:8188", "[::1]:8188", "127.0.0.2:8199"] { XCTAssertTrue(PortProbe.isLoopbackAddress(a), a) }
        for a in ["*:8188", "0.0.0.0:8188", "10.0.0.5:8188", "[::]:8188", "192.168.1.2:8188"] { XCTAssertFalse(PortProbe.isLoopbackAddress(a), a) }
    }

    func testLsofParse() {
        let l = PortProbe.parseLsof("p4317\nn127.0.0.1:8188\n")
        XCTAssertEqual(l, [PortProbe.Listener(pid: 4317, address: "127.0.0.1:8188")])
    }
}

final class SettingsTests: XCTestCase {
    func testUnchangedValuesAreNotPersisted() throws {
        let suite = "comfybar.tests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: d)
        s.port = s.port                      // same value (e.g. from a launch argument)
        s.comfyFolder = s.comfyFolder
        s.host = "127.0.0.1"
        XCTAssertNil(d.persistentDomain(forName: suite)?["port"], "an unchanged value must not be written")
        XCTAssertNil(d.persistentDomain(forName: suite)?["comfyFolder"])
        XCTAssertNil(d.persistentDomain(forName: suite)?["host"])
        s.port = 8199
        XCTAssertEqual(d.persistentDomain(forName: suite)?["port"] as? Int, 8199, "a real change is written")
    }

    func testHostValidation() {
        for ok in ["127.0.0.1", "localhost", "studio.local", "my-mac"] { XCTAssertTrue(AppSettings.isValidHost(ok), ok) }
        for bad in ["", "http://x", "a b", "host:8188", "::1", "-x", "x-"] { XCTAssertFalse(AppSettings.isValidHost(bad), bad) }
        XCTAssertFalse(LaunchGuard.isLoopback("::1"), "ComfyUI binds IPv4 127.0.0.1 only")
    }
}
