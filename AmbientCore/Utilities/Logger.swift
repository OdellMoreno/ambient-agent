import Foundation
import os.log

/// Centralized logging for Ambient Agent
public struct AmbientLogger {
    private static let subsystem = "com.ambient.agent"

    public static let general = Logger(subsystem: subsystem, category: "general")
    public static let monitors = Logger(subsystem: subsystem, category: "monitors")
    public static let extraction = Logger(subsystem: subsystem, category: "extraction")
    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let xpc = Logger(subsystem: subsystem, category: "xpc")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}

// MARK: - Convenience Extensions

public extension Logger {
    func trace(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        self.debug("[\(fileName):\(line)] \(function) - \(message)")
    }
}
