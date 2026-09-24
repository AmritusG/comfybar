import Foundation

/// Memory pressure from Apple's documented API: DispatchSource.makeMemoryPressureSource
/// (<dispatch/source.h> DISPATCH_MEMORYPRESSURE_NORMAL/WARN/CRITICAL = 0x1/0x2/0x4).
///
/// The source reports CHANGES. It gives no reading of the level at the moment ComfyBar
/// starts, and the sysctl that holds the live level (kern.memorystatus_vm_pressure_level)
/// is not in the public SDK headers - so it is not shown (R5). The panel therefore says
/// "last signal since ComfyBar launched", never a bare "normal".
final class MemoryPressureWatcher: ObservableObject {
    enum Level: String { case normal, warning, critical }

    @Published private(set) var lastSignal: (level: Level, at: Date)?
    let launchedAt = Date()
    private var source: DispatchSourceMemoryPressure?
    private let log: EventLog

    init(log: EventLog) { self.log = log }

    func start() {
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let e = s.data
            let level: Level = e.contains(.critical) ? .critical : e.contains(.warning) ? .warning : .normal
            self.lastSignal = (level, Date())
            self.log.add(.state, "memory pressure signal: \(level.rawValue)")
        }
        s.resume()
        source = s
    }
}
