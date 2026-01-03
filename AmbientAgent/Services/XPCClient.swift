import Foundation
import AmbientCore
import ServiceManagement

/// Client for communicating with the background helper via XPC
@MainActor
public final class XPCClient: ObservableObject {
    public static let shared = XPCClient()

    @Published public private(set) var isConnected = false
    @Published public private(set) var isHelperRunning = false
    @Published public private(set) var status: [String: String] = [:]

    private var connection: NSXPCConnection?
    private var service: AmbientAgentProtocol?

    private init() {}

    // MARK: - Connection Management

    public func connect() throws {
        AmbientLogger.xpc.info("Connecting to helper service")

        let connection = NSXPCConnection(machServiceName: AmbientAgentServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: AmbientAgentProtocol.self)

        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.handleDisconnection()
            }
        }

        connection.interruptionHandler = { [weak self] in
            AmbientLogger.xpc.warning("XPC connection interrupted, attempting reconnect")
            Task { @MainActor in
                try? self?.connect()
            }
        }

        connection.resume()

        self.connection = connection
        self.service = connection.remoteObjectProxyWithErrorHandler { error in
            AmbientLogger.xpc.error("XPC proxy error: \(error.localizedDescription)")
        } as? AmbientAgentProtocol

        isConnected = true
    }

    public func disconnect() {
        connection?.invalidate()
        handleDisconnection()
    }

    private func handleDisconnection() {
        connection = nil
        service = nil
        isConnected = false
        isHelperRunning = false
    }

    // MARK: - Helper Registration

    public func registerHelper() throws {
        let service = SMAppService.agent(plistName: "com.ambient.agent.plist")
        try service.register()
        AmbientLogger.general.info("Helper registered successfully")
    }

    public func unregisterHelper() throws {
        let service = SMAppService.agent(plistName: "com.ambient.agent.plist")
        try service.unregister()
        AmbientLogger.general.info("Helper unregistered")
    }

    public var helperStatus: SMAppService.Status {
        SMAppService.agent(plistName: "com.ambient.agent.plist").status
    }

    // MARK: - Service Methods

    public func ping() async -> Bool {
        guard let service else { return false }

        return await withCheckedContinuation { continuation in
            service.ping { success in
                continuation.resume(returning: success)
            }
        }
    }

    public func startMonitoring(sources: [SourceType]) async throws {
        guard let service else {
            throw AmbientAgentError.serviceUnavailable
        }

        let sourceStrings = sources.map(\.rawValue)

        let (success, error) = await withCheckedContinuation { continuation in
            service.startMonitoring(sources: sourceStrings) { success, error in
                continuation.resume(returning: (success, error))
            }
        }

        if !success {
            throw AmbientAgentError.syncFailed(error ?? "Unknown error")
        }

        isHelperRunning = true
    }

    public func stopMonitoring() async throws {
        guard let service else {
            throw AmbientAgentError.serviceUnavailable
        }

        _ = await withCheckedContinuation { continuation in
            service.stopMonitoring { success in
                continuation.resume(returning: success)
            }
        }

        isHelperRunning = false
    }

    public func forceSync(source: SourceType) async throws {
        guard let service else {
            throw AmbientAgentError.serviceUnavailable
        }

        let (success, error) = await withCheckedContinuation { continuation in
            service.forceSync(source: source.rawValue) { success, error in
                continuation.resume(returning: (success, error))
            }
        }

        if !success {
            throw AmbientAgentError.syncFailed(error ?? "Unknown error")
        }
    }

    public func refreshStatus() async {
        guard let service else {
            status = [:]
            return
        }

        status = await withCheckedContinuation { continuation in
            service.getStatus { status in
                continuation.resume(returning: status)
            }
        }

        isHelperRunning = status[MonitorStatusKeys.isRunning] == "true"
    }
}
