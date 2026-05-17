import Foundation
import Dispatch

@MainActor
final class CmuxMemoryPressureMonitor {
    static let shared = CmuxMemoryPressureMonitor()

    enum Level: String {
        case normal
        case warning
        case critical
    }

    private var source: DispatchSourceMemoryPressure?
    private var subscribers: [UUID: (Level) -> Void] = [:]
    private(set) var lastObservedLevel: Level = .normal

    private init() {}

    func start() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: .main
        )
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let event = s.data
            let level: Level
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .normal
            }
            #if DEBUG
            cmuxDebugLog("mem.pressure level=\(level.rawValue)")
            #endif
            self.lastObservedLevel = level
            for handler in self.subscribers.values {
                handler(level)
            }
        }
        s.activate()
        self.source = s
    }

    @discardableResult
    func subscribe(_ handler: @escaping (Level) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
