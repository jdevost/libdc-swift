import Foundation
import Clibdivecomputer
import LibDCBridge

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
    }
    
    public func log(_ message: String, level: LogLevel = .debug, file: String = #file, function: String = #function) {
        guard level.rawValue >= minLevel.rawValue else { return }
        
        let timestamp = dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        
        print("\(level.prefix) [\(timestamp)] [\(fileName)] \(message)")
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