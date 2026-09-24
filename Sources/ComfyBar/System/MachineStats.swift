import Foundation
import Darwin

/// Machine and process figures. Every one is read from a public Apple interface (SDK
/// header named beside it) and cross-checked against Apple's own CLI in the tests
/// (vm_stat, sysctl, ps, footprint). See docs/GROUNDING.md section 1.3.
struct MemorySnapshot: Equatable {
    let pageSize: UInt64
    let totalBytes: UInt64
    /// vm_stat "Pages free" = free_count - speculative_count.
    let freePages: UInt64
    let inactivePages: UInt64
    let speculativePages: UInt64
    let purgeablePages: UInt64

    /// ComfyBar's definition, in vm_stat's terms:
    /// AVAILABLE = free + inactive + speculative + purgeable.
    var availableBytes: UInt64 {
        (freePages + inactivePages + speculativePages + purgeablePages) * pageSize
    }
    /// Shown as "in use": total - AVAILABLE, same definition. Not Activity Monitor's
    /// "Memory Used" (whose formula Apple does not publish).
    var inUseBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
}

struct SwapSnapshot: Equatable {
    let totalBytes: UInt64
    let usedBytes: UInt64
}

enum MachineStats {
    /// <mach/host_info.h> HOST_VM_INFO64 / <mach/vm_statistics.h> vm_statistics64.
    static func memory() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        var total: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &total, &len, nil, 0) == 0 else { return nil }
        let free = UInt64(stats.free_count)
        let spec = UInt64(stats.speculative_count)
        return MemorySnapshot(pageSize: UInt64(pageSize), totalBytes: total,
                              freePages: free >= spec ? free - spec : 0,
                              inactivePages: UInt64(stats.inactive_count),
                              speculativePages: spec,
                              purgeablePages: UInt64(stats.purgeable_count))
    }

    /// <sys/sysctl.h> struct xsw_usage via "vm.swapusage" (public, see sysctl(8)).
    static func swap() -> SwapSnapshot? {
        var xsw = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &len, nil, 0) == 0 else { return nil }
        return SwapSnapshot(totalBytes: xsw.xsu_total, usedBytes: xsw.xsu_used)
    }

    /// <libproc.h> proc_pid_rusage RUSAGE_INFO_V4 ri_phys_footprint - the figure Apple's
    /// `footprint` tool and Activity Monitor's Memory column report.
    static func footprint(pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : nil
    }

    /// <sys/sysctl.h> KERN_PROC_PID -> kinfo_proc.kp_proc.p_starttime.
    static func startTime(pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var len = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &len, nil, 0) == 0, len > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    /// <sys/sysctl.h> KERN_PROCARGS2: argc, exec path, then argv.
    static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }  // exec path
        while i < size, buf[i] == 0 { i += 1 }  // padding
        var args: [String] = []
        while i < size, args.count < argc {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// <libproc.h> PROC_PIDVNODEPATHINFO -> the process's current directory.
    static func currentDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

/// Which process is listening on a TCP port, via /usr/sbin/lsof (runs as the user; sees
/// the user's own processes, which is where ComfyUI runs).
enum PortProbe {
    struct Listener: Equatable {
        let pid: pid_t
        let address: String   // e.g. "127.0.0.1:8188"
    }

    /// lsof names: "127.0.0.1:8188", "[::1]:8188", "*:8188", "10.0.0.5:8188".
    static func isLoopbackAddress(_ address: String) -> Bool {
        guard let colon = address.lastIndex(of: ":") else { return false }
        let host = address[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.hasPrefix("127.") || host == "::1" || host == "localhost"
    }

    static func parseLsof(_ out: String) -> [Listener] {
        // -F pn output: "p<pid>" lines followed by "n<addr>" lines.
        var result: [Listener] = []
        var pid: pid_t?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = pid_t(line.dropFirst()) }
            else if line.hasPrefix("n"), let p = pid { result.append(Listener(pid: p, address: String(line.dropFirst()))) }
        }
        return result
    }

    static func listeners(port: Int) -> [Listener] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pn"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseLsof(String(decoding: data, as: UTF8.self))
    }
}
