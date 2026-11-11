import Foundation

/// Main-thread cache; expensive process enumeration runs on one worker queue.
final class ActiveAppLoader {
    private let queue = DispatchQueue(label: "WattBar.active-apps", qos: .utility)
    private let read: () -> [ActiveApp]
    private var enabled = false
    private var generation = 0
    private var lastRefresh: TimeInterval?
    private(set) var isLoading = false
    private(set) var apps: [ActiveApp]?
    var onUpdate: (() -> Void)?

    init(read: @escaping () -> [ActiveApp] = { ActiveAppReader().topApps() }) {
        self.read = read
    }

    func setEnabled(_ enabled: Bool) {
        precondition(Thread.isMainThread)
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        generation += 1
        apps = nil
        lastRefresh = nil
        if enabled { refreshIfNeeded() }
    }

    func refreshIfNeeded() {
        precondition(Thread.isMainThread)
        guard enabled, !isLoading else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastRefresh, now - lastRefresh < 5 { return }
        isLoading = true
        let requestedGeneration = generation
        let read = self.read
        queue.async { [weak self] in
            let result = read()
            // Menu tracking can nest inside a main-queue block. A common-mode
            // run-loop callback can deliver results before that menu closes.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                guard let self else { return }
                self.isLoading = false
                guard self.enabled, self.generation == requestedGeneration else {
                    self.refreshIfNeeded()
                    return
                }
                self.apps = result
                self.lastRefresh = ProcessInfo.processInfo.systemUptime
                self.onUpdate?()
            }
        }
    }
}
