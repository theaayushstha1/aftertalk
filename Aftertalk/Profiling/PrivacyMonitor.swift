import Foundation
import Network
import Observation
import os

@Observable
@MainActor
final class PrivacyMonitor {
    enum State: Equatable {
        case unknown
        case offline
        case onlineButIdle(interfaces: [String])
        case violation(interfaces: [String])
    }

    private(set) var state: State = .unknown
    private(set) var lastEvaluatedAt: Date?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.theaayushstha.aftertalk.privacy", qos: .utility)
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Privacy")

    /// Set true while a meeting is being recorded; an active interface during this window is a hard violation.
    var isCapturingMeeting: Bool = false {
        didSet { reevaluate(monitor.currentPath) }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.reevaluate(path) }
        }
        monitor.start(queue: queue)
    }

    private func reevaluate(_ path: NWPath) {
        let active = activeInterfaceNames(path)
        lastEvaluatedAt = Date()

        if active.isEmpty {
            state = .offline
        } else if isCapturingMeeting {
            state = .violation(interfaces: active)
            log.fault("Privacy violation: interfaces \(active.joined(separator: ","), privacy: .public) up while recording")
        } else {
            state = .onlineButIdle(interfaces: active)
        }
    }

    private func activeInterfaceNames(_ path: NWPath) -> [String] {
        guard path.status == .satisfied else { return [] }
        var names: [String] = []
        if path.usesInterfaceType(.wifi) { names.append("wifi") }
        if path.usesInterfaceType(.cellular) { names.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { names.append("ethernet") }
        if path.usesInterfaceType(.other) { names.append("other") }
        return names
    }
}
