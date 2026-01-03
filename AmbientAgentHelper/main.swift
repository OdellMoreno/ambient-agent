import Foundation
import AmbientCore

/// Entry point for the Ambient Agent background helper
final class AgentDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        AmbientLogger.xpc.info("Accepting new XPC connection")

        // Configure the connection
        newConnection.exportedInterface = NSXPCInterface(with: AmbientAgentProtocol.self)
        newConnection.exportedObject = AgentService.shared

        // Handle connection lifecycle
        newConnection.invalidationHandler = {
            AmbientLogger.xpc.info("XPC connection invalidated")
        }

        newConnection.interruptionHandler = {
            AmbientLogger.xpc.warning("XPC connection interrupted")
        }

        newConnection.resume()
        return true
    }
}

// MARK: - Main

let delegate = AgentDelegate()
let listener = NSXPCListener(machServiceName: AmbientAgentServiceName)
listener.delegate = delegate

AmbientLogger.general.info("Ambient Agent Helper starting...")

// Start the XPC listener
listener.resume()

// Keep the process running
RunLoop.main.run()
