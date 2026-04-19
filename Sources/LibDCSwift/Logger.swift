import Foundation
import Clibdivecomputer
import LibDCBridge
#if canImport(UIKit)
import UIKit
#endif

public enum LogLevel: Int {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    
    public var prefix: String {
        switch self {
        case .debug: return "🔍 DEBUG"
        case .info: return "ℹ️ INFO"
        case .warning: return "⚠️ WARN"
        case .error: return "❌ ERROR"
        }
    }
}

public class Logger {
    public static let shared = Logger()
    private var isEnabled = true
    private var minLevel: LogLevel = .debug
    public var shouldShowRawData = false  // Toggle for full hex dumps
    private var dataCounter = 0  // Track number of data packets
    private var totalBytesReceived = 0  // Track total bytes
    
    // In-memory log buffer for diagnostic export
    private var logEntries: [String] = []
    private let logEntriesLock = NSLock()
    private let maxLogEntries = 5000
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    public var minimumLogLevel: LogLevel {
        get { minLevel }
        set { minLevel = newValue }
    }
    
    public func setMinLevel(_ level: LogLevel) {
        minLevel = level
    }
    
    private init() {
        isEnabled = true
        minLevel = .debug
        registerBridgeLogCallback()
    }
    
    /// Registers the C bridge log callback so all printf/NSLog output
    /// from configuredc.c and BLEBridge.m is captured in the log buffer.
    private func registerBridgeLogCallback() {
        set_bridge_log_callback { cMessage in
            guard let cMessage = cMessage else { return }
            let message = String(cString: cMessage)
            Logger.shared.appendBridgeMessage(message)
        }
        // Mark the callback as registered so we can verify in the export
        let timestamp = dateFormatter.string(from: Date())
        let entry = "ℹ️ INFO [\(timestamp)] [Logger.swift] Bridge log callback registered — C/ObjC output will be captured"
        logEntriesLock.lock()
        logEntries.append(entry)
        logEntriesLock.unlock()
    }
    
    /// Appends a raw message from the C bridge to the log buffer.
    private func appendBridgeMessage(_ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let entry = "[C] [\(timestamp)] \(message)"
        logEntriesLock.lock()
        logEntries.append(entry)
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
        logEntriesLock.unlock()
    }
    
    public func log(_ message: String, level: LogLevel = .debug, file: String = #file, function: String = #function) {
        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        
        let entry = "\(level.prefix) [\(timestamp)] [\(fileName)] \(message)"
        
        // Always buffer every entry for diagnostic export
        logEntriesLock.lock()
        logEntries.append(entry)
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
        logEntriesLock.unlock()
        
        // Only print to console if level passes the filter
        guard level.rawValue >= minLevel.rawValue else { return }
        print(entry)
    }
    
    /// Enables debug mode: sets Swift log level to .debug and libdivecomputer
    /// internal logging to DC_LOGLEVEL_ALL. This produces verbose protocol-level
    /// traces (SLIP frames, packet hex dumps, etc.) that are essential for
    /// diagnosing intermittent communication errors.
    /// Call this BEFORE connecting to a device.
    public func enableDebugMode() {
        minLevel = .debug
        shouldShowRawData = true
        set_libdc_loglevel(DC_LOGLEVEL_ALL)
        log("Debug mode enabled - libdivecomputer verbose logging active", level: .info)
    }
    
    /// Disables debug mode: sets Swift log level to .warning and libdivecomputer
    /// internal logging to DC_LOGLEVEL_WARNING.
    public func disableDebugMode() {
        set_libdc_loglevel(DC_LOGLEVEL_WARNING)
        minLevel = .warning
        shouldShowRawData = false
        log("Debug mode disabled", level: .warning)
    }
    
    /// Returns whether debug mode is currently active.
    public var isDebugMode: Bool {
        return get_libdc_loglevel() == DC_LOGLEVEL_ALL
    }
    
    private func handleBLEDataLog(_ message: String, _ timestamp: String) {
        dataCounter += 1
        
        // Extract byte count from message
        if let bytesStart = message.range(of: "("),
           let bytesEnd = message.range(of: " bytes)") {
            let bytesStr = message[bytesStart.upperBound..<bytesEnd.lowerBound]
            if let bytes = Int(bytesStr) {
                totalBytesReceived += bytes
                
                // Only print summary at the end or for significant events
                if message.contains("completed") || message.contains("error") {
                    print("📱 [\(timestamp)] BLE: Total received: \(totalBytesReceived) bytes in \(dataCounter) packets")
                }
            }
        }
    }
    
    private func formatHexData(_ hexString: String) -> String {
        // Format hex data in chunks of 8 bytes (16 characters)
        var formatted = ""
        var index = hexString.startIndex
        let chunkSize = 16
        
        while index < hexString.endIndex {
            let endIndex = hexString.index(index, offsetBy: chunkSize, limitedBy: hexString.endIndex) ?? hexString.endIndex
            let chunk = hexString[index..<endIndex]
            formatted += chunk
            if endIndex != hexString.endIndex {
                formatted += "\n\t\t\t"  // Indent continuation lines
            }
            index = endIndex
        }
        
        return formatted
    }
    
    public func setShowRawData(_ show: Bool) {
        shouldShowRawData = show
    }
    
    public func resetDataCounters() {
        dataCounter = 0
        totalBytesReceived = 0
    }
    
    /// Clears the in-memory log buffer.
    public func clearLogBuffer() {
        logEntriesLock.lock()
        logEntries.removeAll()
        logEntriesLock.unlock()
    }
    
    /// Generates a full diagnostic log string suitable for export/sharing.
    public func generateDiagnosticLog() -> String {
        var lines: [String] = []
        lines.append("BlueDive Diagnostic Log")
        lines.append("========================")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("App Version: \(appVersion) (\(buildNumber))")
        
        #if canImport(UIKit)
        let device = UIDevice.current
        lines.append("Device: \(deviceModelIdentifier())")
        lines.append("OS: \(device.systemName) \(device.systemVersion)")
        #else
        lines.append("Platform: macOS")
        #endif
        
        lines.append("Debug Mode: \(isDebugMode ? "ON" : "OFF")")
        lines.append("Min Log Level: \(minLevel)")
        lines.append("")
        
        logEntriesLock.lock()
        let count = logEntries.count
        let entriesCopy = logEntries
        logEntriesLock.unlock()
        
        lines.append("=== Log Entries (\(count)) ===")
        lines.append("")
        lines.append(contentsOf: entriesCopy)
        
        return lines.joined(separator: "\n")
    }
    
    private func deviceModelIdentifier() -> String {
        #if canImport(UIKit)
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
        #else
        return "Mac"
        #endif
    }

}

// Global convenience functions
public func logDebug(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .debug, file: file, function: function)
}

public func logInfo(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .info, file: file, function: function)
}

public func logWarning(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .warning, file: file, function: function)
}

public func logError(_ message: String, file: String = #file, function: String = #function) {
    Logger.shared.log(message, level: .error, file: file, function: function)
} 
