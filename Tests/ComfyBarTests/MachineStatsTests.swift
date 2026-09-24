import XCTest

/// R5: each machine figure cross-checked against Apple's own command-line tool.
final class MachineStatsTests: XCTestCase {
    private func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    private func vmStat(_ out: String, _ key: String) -> UInt64? {
        guard let r = out.range(of: key + ":") else { return nil }
        let rest = out[r.upperBound...].drop { $0 == " " }
        return UInt64(rest.prefix { $0.isNumber })
    }

    /// vm_stat samples a moment later than we do; pages move between lists, so compare each
    /// list within 2% of physical memory and page size exactly.
    func testMemoryMatchesVmStat() throws {
        let m = try XCTUnwrap(MachineStats.memory())
        let out = try run("/usr/bin/vm_stat", [])
        let page = try XCTUnwrap(out.range(of: "page size of ").map { UInt64(out[$0.upperBound...].prefix { $0.isNumber }) } ?? nil)
        XCTAssertEqual(m.pageSize, page)
        let slack = Double(m.totalBytes / m.pageSize) * 0.02
        for (key, ours) in [("Pages free", m.freePages), ("Pages inactive", m.inactivePages),
                            ("Pages speculative", m.speculativePages), ("Pages purgeable", m.purgeablePages)] {
            let theirs = try XCTUnwrap(vmStat(out, key), key)
            XCTAssertLessThan(abs(Double(ours) - Double(theirs)), slack, "\(key): ours \(ours) vm_stat \(theirs)")
        }
        let total = UInt64(try run("/usr/sbin/sysctl", ["-n", "hw.memsize"]).trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(m.totalBytes, total)
        XCTAssertEqual(m.availableBytes, (m.freePages + m.inactivePages + m.speculativePages + m.purgeablePages) * m.pageSize)
    }

    func testSwapMatchesSysctl() throws {
        let s = try XCTUnwrap(MachineStats.swap())
        let out = try run("/usr/sbin/sysctl", ["vm.swapusage"])   // "total = 9216.00M  used = 7818.75M ..."
        func mb(_ k: String) -> Double? {
            guard let r = out.range(of: k + " = ") else { return nil }
            return Double(out[r.upperBound...].prefix { $0.isNumber || $0 == "." })
        }
        let total = try XCTUnwrap(mb("total")), used = try XCTUnwrap(mb("used"))
        XCTAssertEqual(Double(s.totalBytes) / 1_048_576, total, accuracy: 1)
        XCTAssertEqual(Double(s.usedBytes) / 1_048_576, used, accuracy: 64, "swap moves; within 64 MB")
    }

    func testOwnProcessFigures() throws {
        let pid = getpid()
        let args = try XCTUnwrap(MachineStats.arguments(pid: pid))
        XCTAssertEqual(args, CommandLine.arguments)
        XCTAssertEqual(MachineStats.currentDirectory(pid: pid).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        let start = try XCTUnwrap(MachineStats.startTime(pid: pid))
        let etime = try run("/bin/ps", ["-o", "etimes=", "-p", String(pid)]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = Double(etime) {
            XCTAssertEqual(Date().timeIntervalSince(start), e, accuracy: 2)
        }
        let fp = try XCTUnwrap(MachineStats.footprint(pid: pid))
        XCTAssertGreaterThan(fp, 1_000_000)
    }

    /// footprint(1) is Apple's reference for phys_footprint.
    func testFootprintMatchesAppleTool() throws {
        let pid = getpid()
        let out = try run("/usr/bin/footprint", ["-p", String(pid)])
        // "... Footprint: 123 MB (16384 bytes per page)"
        guard let r = out.range(of: "Footprint: ") else { throw XCTSkip("footprint output not parseable: \(out.prefix(200))") }
        let rest = out[r.upperBound...]
        let num = Double(rest.prefix { $0.isNumber || $0 == "." }) ?? -1
        let unit = rest.drop { $0.isNumber || $0 == "." || $0 == " " }.prefix(2)
        let mult: Double = unit == "GB" ? 1_073_741_824 : unit == "MB" ? 1_048_576 : unit == "KB" ? 1024 : 1
        let ours = Double(try XCTUnwrap(MachineStats.footprint(pid: pid)))
        XCTAssertEqual(ours, num * mult, accuracy: max(8 * 1_048_576, ours * 0.1), "footprint(1) says \(num) \(unit)")
    }
}
