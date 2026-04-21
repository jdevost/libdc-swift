import Foundation
#if canImport(UIKit)
import UIKit
#endif
import CoreBluetooth
import Clibdivecomputer
import LibDCBridge
import LibDCBridge.CoreBluetoothManagerProtocol
import Combine

/// Represents a BLE serial service with its identifying information
@objc(SerialService)
class SerialService: NSObject {
    @objc let uuid: String
    @objc let vendor: String
    @objc let product: String
    
    @objc init(uuid: String, vendor: String, product: String) {
        self.uuid = uuid
        self.vendor = vendor
        self.product = product
        super.init()
    }
}

/// Extension to check if a CBUUID is a standard Bluetooth service UUID
extension CBUUID {
    var isStandardBluetooth: Bool {
        return self.data.count == 2
    }
}

/// Central manager for handling BLE communications with dive computers.
/// Manages device discovery, connection, and data transfer with BLE dive computers.
@objc(CoreBluetoothManager)
public class CoreBluetoothManager: NSObject, CoreBluetoothManagerProtocol, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // MARK: - Singleton
    private static let sharedInstance = CoreBluetoothManager()
    
    @objc public static func shared() -> Any! {
        return sharedInstance
    }
    
    public static var sharedManager: CoreBluetoothManager {
        return sharedInstance
    }
    
    // MARK: - Published Properties
    @Published public var centralManager: CBCentralManager! // Core Bluetooth central manager instance
    @Published public var peripheral: CBPeripheral? // Currently selected peripheral device
    @Published public var discoveredPeripherals: [CBPeripheral] = [] // List of discovered BLE peripherals
    @Published public var isPeripheralReady = false // Indicates if peripheral is ready for communication
    @Published @objc dynamic public var connectedDevice: CBPeripheral? // Currently connected peripheral device
    @Published public var isScanning = false // Indicates if currently scanning for devices
    @Published public var isRetrievingLogs = false { // Indicates if currently retrieving dive logs
        didSet {
            objectWillChange.send()
        }
    }
    @Published public var currentRetrievalDevice: CBPeripheral? { // Device currently being used for log retrieval
        didSet {
            objectWillChange.send()
        }
    }
    @Published public var isDisconnecting = false // Indicates if currently disconnecting from device
    @Published public var isBluetoothReady = false // Indicates if Bluetooth is ready for use
    @Published public var isConnecting = false // Indicates if a connection attempt is in progress (prevents auto-reconnect)
    @Published private var deviceDataPtrChanged = false

    // MARK: - Private Properties
    private var bleTimeoutMs: Int = -1 // Timeout in ms, -1 means no timeout (use default 3s)
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    /// Queue of individual BLE notifications. Each notification is kept as a
    /// separate Data element to preserve packet boundaries.  Protocols like
    /// Shearwater's SLIP framing expect each `read()` to return exactly one
    /// BLE packet; merging notifications in a flat buffer can produce
    /// "Invalid packet header" errors when two notifications arrive before
    /// the consumer reads the first one.
    private var receivedPackets: [Data] = []
    /// Leftover bytes from a partially-consumed notification.  When the
    /// caller requests fewer bytes than a notification contains we store
    /// the remainder here and drain it before dequeuing the next packet.
    private var partialPacket: Data = Data()
    private let queue = DispatchQueue(label: "com.blemanager.queue")
    private let dataAvailableSemaphore = DispatchSemaphore(value: 0) // Signals when new data arrives
    private let writeReadySemaphore = DispatchSemaphore(value: 0) // Signals when peripheral is ready for next write-without-response
    private let frameMarker: UInt8 = 0x7E
    private var _deviceDataPtr: UnsafeMutablePointer<device_data_t>?
    private let deviceDataPtrLock = NSLock() // Protects _deviceDataPtr for cross-thread access
    private var connectionCompletion: ((Bool) -> Void)?
    private var totalBytesReceived: Int = 0
    private var lastDataReceived: Date?
    private var averageTransferRate: Double = 0
    private var preferredService: CBService?
    private var pendingOperations: [() -> Void] = []
    
    // MARK: - Public Properties
    /// Thread-safe access to device data pointer with change notification.
    /// This property is set from the main queue (by openBLEDevice) and read from
    /// background threads (e.g. the polling loop in BluetoothScannerView).
    public var openedDeviceDataPtr: UnsafeMutablePointer<device_data_t>? {
        get {
            deviceDataPtrLock.lock()
            defer { deviceDataPtrLock.unlock() }
            return _deviceDataPtr
        }
        set {
            deviceDataPtrLock.lock()
            _deviceDataPtr = newValue
            deviceDataPtrLock.unlock()
            objectWillChange.send()
        }
    }
    
    /// Checks if there is a valid device data pointer
    /// - Returns: True if device data pointer exists
    public func hasValidDeviceDataPtr() -> Bool {
        return openedDeviceDataPtr != nil
    }
    
    // MARK: - Serial Services
    /// Known BLE serial services for supported dive computers
    @objc private let knownSerialServices: [SerialService] = [
        SerialService(uuid: "0000fefb-0000-1000-8000-00805f9b34fb", vendor: "Heinrichs-Weikamp", product: "Telit/Stollmann"),
        SerialService(uuid: "2456e1b9-26e2-8f83-e744-f34f01e9d701", vendor: "Heinrichs-Weikamp", product: "U-Blox"),
        SerialService(uuid: "544e326b-5b72-c6b0-1c46-41c1bc448118", vendor: "Mares", product: "BlueLink Pro"),
        SerialService(uuid: "6e400001-b5a3-f393-e0a9-e50e24dcca9e", vendor: "Nordic Semi", product: "UART"),
        SerialService(uuid: "98ae7120-e62e-11e3-badd-0002a5d5c51b", vendor: "Suunto", product: "EON Steel/Core"),
        SerialService(uuid: "cb3c4555-d670-4670-bc20-b61dbc851e9a", vendor: "Pelagic", product: "i770R/i200C"),
        SerialService(uuid: "ca7b0001-f785-4c38-b599-c7c5fbadb034", vendor: "Pelagic", product: "i330R/DSX"),
        SerialService(uuid: "fdcdeaaa-295d-470e-bf15-04217b7aa0a0", vendor: "ScubaPro", product: "G2/G3"),
        SerialService(uuid: "fe25c237-0ece-443c-b0aa-e02033e7029d", vendor: "Shearwater", product: "Perdix/Teric"),
        SerialService(uuid: "0000fcef-0000-1000-8000-00805f9b34fb", vendor: "Divesoft", product: "Freedom")
    ]
    
    /// Service UUIDs to exclude from discovery
    private let excludedServices: Set<String> = [
        "00001530-1212-efde-1523-785feabcd123", // Nordic Upgrade
        "9e5d1e47-5c13-43a0-8635-82ad38a1386f", // Broadcom Upgrade #1
        "a86abc2d-d44c-442e-99f7-80059a873e36"  // Broadcom Upgrade #2
    ]
    
    // MARK: - Initialization
    private override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Service Discovery
    @objc(getPeripheralReadyState)
    public func getPeripheralReadyState() -> Bool {
        return self.isPeripheralReady
    }
    
    @objc(setTimeout:)
    public func setTimeout(_ timeoutMs: Int32) {
        let old = self.bleTimeoutMs
        self.bleTimeoutMs = Int(timeoutMs)
        if Logger.shared.isDebugMode {
            logDebug("[BLE TIMEOUT] Swift setTimeout: \(old) ms -> \(self.bleTimeoutMs) ms")
        }
    }
    
    @objc(discoverServices)
    public func discoverServices() -> Bool {
        guard let peripheral = self.peripheral else {
            logError("No peripheral available for service discovery")
            return false
        }
        
        // Check if peripheral is actually connected
        guard peripheral.state == .connected else {
            logError("Peripheral not in connected state: \(peripheral.state.rawValue)")
            return false
        }
        
        let startTime = Date()
        if Logger.shared.isDebugMode {
            logDebug("[BLE DISCOVER] Starting service discovery on thread: \(Thread.isMainThread ? "main" : "background") for \(peripheral.name ?? "unknown")")
        }
        
        peripheral.discoverServices(nil)
        
        // Wait for characteristics with timeout.
        // CoreBluetooth callbacks are delivered on the main queue, so we
        // must not block the main thread here.  Use Thread.sleep so the
        // main thread stays free to process callbacks when this is called
        // from a background thread.
        let timeout = Date(timeIntervalSinceNow: 5.0)
        while writeCharacteristic == nil || notifyCharacteristic == nil {
            if Date() > timeout {
                logError("Timeout waiting for service discovery (5s)")
                if Logger.shared.isDebugMode {
                    logDebug("[BLE DISCOVER] writeChar=\(writeCharacteristic != nil), notifyChar=\(notifyCharacteristic != nil)")
                }
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        
        if Logger.shared.isDebugMode {
            let elapsed = Date().timeIntervalSince(startTime)
            let writeType = writeCharacteristic?.properties.contains(.writeWithoutResponse) == true ? "withoutResponse" : "withResponse"
            logDebug("[BLE DISCOVER] Completed in \(String(format: "%.2f", elapsed))s - writeChar: \(writeCharacteristic?.uuid.uuidString ?? "nil") (props=\(writeCharacteristic?.properties.rawValue ?? 0), writeType=\(writeType)), notifyChar: \(notifyCharacteristic?.uuid.uuidString ?? "nil")")
        }
        
        return writeCharacteristic != nil && notifyCharacteristic != nil
    }
    
    @objc(enableNotifications)
    public func enableNotifications() -> Bool {
        guard let notifyCharacteristic = self.notifyCharacteristic,
              let peripheral = self.peripheral else {
            logError("Missing characteristic or peripheral for notifications")
            return false
        }
        
        // Check if peripheral is actually connected
        guard peripheral.state == .connected else {
            logError("Peripheral not in connected state for notifications: \(peripheral.state.rawValue)")
            return false
        }
        
        let startTime = Date()
        if Logger.shared.isDebugMode {
            logDebug("[BLE NOTIFY] Enabling notifications on thread: \(Thread.isMainThread ? "main" : "background"), characteristic: \(notifyCharacteristic.uuid.uuidString)")
        }
        
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
        
        // Wait for notifications to be enabled with timeout.
        // Use Thread.sleep instead of RunLoop so the main thread stays
        // free to process CoreBluetooth callbacks.
        let timeout = Date(timeIntervalSinceNow: 5.0)
        while !notifyCharacteristic.isNotifying {
            if Date() > timeout {
                logError("Timeout waiting for notifications to enable (5s)")
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        
        if Logger.shared.isDebugMode {
            let elapsed = Date().timeIntervalSince(startTime)
            logDebug("[BLE NOTIFY] Enabled in \(String(format: "%.2f", elapsed))s")
        }
        
        return notifyCharacteristic.isNotifying
    }

    /// Returns the peripheral's advertised Bluetooth name.
    /// Used by libdivecomputer's DC_IOCTL_BLE_GET_NAME to perform the
    /// device-name-based handshake required by Oceanic/Aqualung models
    /// (e.g. i300C, i770R, i200C), which embed digits of the serial
    /// number in the advertised name (e.g. "FH020399").
    @objc public func getDeviceName() -> String {
        return peripheral?.name ?? ""
    }

    // MARK: - Data Handling
    /// Unused legacy method — kept for API compatibility.  The packet-queue
    /// approach (`receivedPackets`) replaced the flat-buffer approach.
    private func findNextCompleteFrame() -> Data? {
        return nil
    }
    
    @objc public func write(_ data: Data!) -> Bool {
        guard let peripheral = self.peripheral,
              let characteristic = self.writeCharacteristic else { return false }

        // Determine write type based on characteristic properties.
        // Prefer .withoutResponse — this is the standard data path for BLE
        // UART services.  Many devices (e.g. Aqualung i300C / Pelagic) only
        // process data received via .withoutResponse even when the char also
        // advertises .write; a .withResponse write succeeds at the ATT level
        // but the firmware's UART handler never sees it.
        // Fall back to .withResponse only when .writeWithoutResponse is NOT
        // supported (e.g. Shearwater characteristics that only have .write).
        let useWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)

        if useWithoutResponse {
            // writeWithoutResponse path — briefly wait for transmit readiness
            if !peripheral.canSendWriteWithoutResponse {
                let deadline = Date(timeIntervalSinceNow: 0.5)
                while !peripheral.canSendWriteWithoutResponse {
                    if Date() > deadline {
                        logWarning("[BLE WRITE] canSendWriteWithoutResponse still false after 500ms, writing anyway (\(data?.count ?? 0) bytes)")
                        break
                    }
                    let result = writeReadySemaphore.wait(timeout: .now() + .milliseconds(50))
                    if result == .timedOut {
                        continue
                    }
                }
            }
            if Logger.shared.isDebugMode {
                logDebug("[BLE WRITE] withoutResponse, canSend=\(peripheral.canSendWriteWithoutResponse), \(data?.count ?? 0) bytes")
            }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            if Logger.shared.isDebugMode {
                logDebug("[BLE WRITE] withResponse, \(data?.count ?? 0) bytes")
            }
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
        return true
    }
    
    @objc public func readDataPartial(_ requested: Int32) -> Data? {
        let requestedInt = Int(requested)
        let startTime = Date()
        // Short-circuit if close() is already in progress.  Without this,
        // dc_device_close()'s internal shutdown handshake (e.g. Oceanic
        // "power off" command) can block readDataPartial for a full 30 s
        // waiting for an ACK the device never sends, delaying the UI.
        if isDisconnecting {
            return nil
        }
        // Use the timeout set by libdivecomputer via ble_set_timeout.
        // If timeout is -1 (no timeout set), default to 3s for safety.
        // If timeout is 0, it means "poll" — return immediately if no data.
        // BLE adapters (e.g. Mares BlueLink Pro) can stall mid-transfer for
        // 10+ seconds while the link stays up.  The protocol-level timeout
        // (often 3 s for Mares, 1 s for Oceanic) is tuned for serial, not
        // BLE.  Enforce a 30 s floor so transient stalls don't abort an
        // otherwise healthy download — this matches observed stall duration
        // in field logs and aligns with other BLE dive-computer clients.
        let minBleTimeoutSec: TimeInterval = 30.0
        let effectiveTimeoutMs = self.bleTimeoutMs
        let rawTimeout: TimeInterval = effectiveTimeoutMs <= 0 ? 3.0 : Double(effectiveTimeoutMs) / 1000.0
        let timeoutInterval: TimeInterval = max(rawTimeout, minBleTimeoutSec)

        if effectiveTimeoutMs == 0 {
            // Poll mode: check once and return immediately
            var outData: Data?
            queue.sync {
                // First drain any leftover partial packet
                if !partialPacket.isEmpty {
                    let amount = min(requestedInt, partialPacket.count)
                    outData = partialPacket.prefix(amount)
                    partialPacket.removeSubrange(0..<amount)
                } else if !receivedPackets.isEmpty {
                    // Return the next complete BLE notification
                    let packet = receivedPackets.removeFirst()
                    if packet.count <= requestedInt {
                        outData = packet
                    } else {
                        outData = packet.prefix(requestedInt)
                        partialPacket = packet.suffix(from: requestedInt)
                    }
                }
            }
            return outData
        }

        while Date().timeIntervalSince(startTime) < timeoutInterval {
            var outData: Data?

            queue.sync {
                // First drain any leftover partial packet from a previous read
                if !partialPacket.isEmpty {
                    let amount = min(requestedInt, partialPacket.count)
                    outData = partialPacket.prefix(amount)
                    partialPacket.removeSubrange(0..<amount)
                } else if !receivedPackets.isEmpty {
                    // Return one complete BLE notification to preserve packet boundaries.
                    // This is critical for protocols like Shearwater SLIP that expect
                    // each read() to correspond to exactly one BLE notification.
                    let packet = receivedPackets.removeFirst()
                    if packet.count <= requestedInt {
                        outData = packet
                    } else {
                        // Caller requested fewer bytes than the notification contains.
                        // Return the requested portion and save the rest.
                        outData = packet.prefix(requestedInt)
                        partialPacket = Data(packet.suffix(from: requestedInt))
                    }
                }
            }

            if let data = outData {
                return data
            }

            // Wait for data - use semaphore with short timeout, fall back to brief sleep
            let result = dataAvailableSemaphore.wait(timeout: .now() + .milliseconds(50))
            if result == .timedOut {
                // Brief sleep as fallback to avoid tight spin loop
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        // Timeout - no data received within the configured timeout
        if Logger.shared.isDebugMode {
            let peripheralState = peripheral?.state.rawValue ?? -1
            logDebug("readDataPartial timeout after \(String(format: "%.1f", timeoutInterval))s (requested \(requestedInt) bytes, protocol timeout: \(effectiveTimeoutMs) ms, effective: \(String(format: "%.1f", timeoutInterval))s, peripheral state: \(peripheralState), isRetrievingLogs: \(isRetrievingLogs))")
        }
        return nil
    }
    
    // MARK: - Device Management
    @objc public func close(clearDevicePtr: Bool = false) {
        let closeStartTime = Date()
        if Logger.shared.isDebugMode {
            logDebug("[BLE CLOSE] Starting close(clearDevicePtr: \(clearDevicePtr)) on thread: \(Thread.isMainThread ? "main" : "background"), peripheral: \(peripheral?.name ?? "nil"), state: \(peripheral?.state.rawValue ?? -1)")
        }
        
        isDisconnecting = true
        // Reset timeout to default for next connection
        self.bleTimeoutMs = -1
        // Clear ready state SYNCHRONOUSLY so that any immediate retry
        // (e.g. open_ble_device_with_identification fallback) sees it.
        // DispatchQueue.main.async would leave isPeripheralReady=true
        // for a brief window, causing the retry to skip the connection
        // wait and fail with "No peripheral available".
        self.isPeripheralReady = false
        self.connectedDevice = nil
        queue.sync {
            receivedPackets.removeAll()
            partialPacket.removeAll()
        }

        // Drain and signal semaphore to unblock any waiting reads and clear stale signals
        while dataAvailableSemaphore.wait(timeout: .now()) == .success {
            // Drain any accumulated signals
        }
        dataAvailableSemaphore.signal() // Signal once to unblock any waiting read

        // Also drain write-ready semaphore to unblock any waiting writes
        while writeReadySemaphore.wait(timeout: .now()) == .success { }
        writeReadySemaphore.signal()

        if clearDevicePtr {
            if let devicePtr = self.openedDeviceDataPtr {
                if devicePtr.pointee.device != nil {
                    dc_device_close(devicePtr.pointee.device)
                }
                devicePtr.deallocate()
                self.openedDeviceDataPtr = nil
            }
        }
        
        if let peripheral = self.peripheral {
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            self.preferredService = nil
            self.peripheral = nil
            centralManager.cancelPeripheralConnection(peripheral)
        }
        
        if Logger.shared.isDebugMode {
            let elapsed = Date().timeIntervalSince(closeStartTime)
            logDebug("[BLE CLOSE] Completed in \(String(format: "%.3f", elapsed))s")
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isDisconnecting = false
        }
    }
    
    public func startScanning(omitUnsupportedPeripherals: Bool = true) {
        centralManager.scanForPeripherals(
            withServices: omitUnsupportedPeripherals ? knownSerialServices.map { CBUUID(string: $0.uuid) } : nil,
            options: nil)
        isScanning = true
    }
    
    public func stopScanning() {
        centralManager.stopScan()
        isScanning = false
    }
    
    @objc public func connect(toDevice address: String!) -> Bool {
        guard let uuid = UUID(uuidString: address),
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            return false
        }
        
        // Set peripheral synchronously regardless of thread.
        // BLEBridge.m calls connectToBLEDevice → connect(toDevice:) from
        // a background thread, then immediately checks isPeripheralReady
        // and calls discoverServices().  If we defer the assignment to
        // main.async, discoverServices() sees self.peripheral == nil and
        // fails with "No peripheral available".
        self.peripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
        return true  // Return immediately, connection status will be handled by delegate
    }
    
    public func connectToStoredDevice(_ uuid: String) -> Bool {
        guard let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: uuid) else {
            return false
        }
        
        return DeviceConfiguration.openBLEDevice(
            name: storedDevice.name,
            deviceAddress: storedDevice.uuid
        )
    }
    
    // MARK: - State Management
    public func clearRetrievalState() {
        DispatchQueue.main.async { [weak self] in
            self?.isRetrievingLogs = false
            self?.currentRetrievalDevice = nil
        }
    }
    
    public func setBackgroundMode(_ enabled: Bool) {
        if enabled {
            // Set connection parameters for background operation
            if let peripheral = peripheral {
                // For iOS/macOS, we can only ensure the connection stays alive
                // by maintaining the peripheral reference and keeping the central manager active
                
                #if os(iOS)
                // On iOS, we can request background execution time
                var backgroundTask: UIBackgroundTaskIdentifier = .invalid
                backgroundTask = UIApplication.shared.beginBackgroundTask { [backgroundTask] in
                    // Cleanup callback
                    if backgroundTask != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTask)
                    }
                }
                
                // Store the task identifier for later cleanup
                currentBackgroundTask = backgroundTask
                #endif
            }
        } else {
            #if os(iOS)
            // Clean up any background tasks when disabling background mode
            if let peripheral = peripheral {
                if let task = currentBackgroundTask, task != .invalid {
                    UIApplication.shared.endBackgroundTask(task)
                    currentBackgroundTask = nil
                }
            }
            #endif
        }
    }

    // track background tasks
    #if os(iOS)
    private var currentBackgroundTask: UIBackgroundTaskIdentifier?
    #endif

    public func systemDisconnect(_ peripheral: CBPeripheral) {
        logInfo("Performing system-level disconnect for \(peripheral.name ?? "Unknown Device")")
        self.isPeripheralReady = false
        self.connectedDevice = nil
        self.writeCharacteristic = nil
        self.notifyCharacteristic = nil
        self.preferredService = nil
        self.peripheral = nil
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    public func clearDiscoveredPeripherals() {
        DispatchQueue.main.async {
            self.discoveredPeripherals.removeAll()
        }
    }
    
    public func addDiscoveredPeripheral(_ peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            if !self.discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                self.discoveredPeripherals.append(peripheral)
            }
        }
    }

    public func queueOperation(_ operation: @escaping () -> Void) {
        if isBluetoothReady {
            operation()
        } else {
            pendingOperations.append(operation)
        }
    }
    
    // MARK: - CBCentralManagerDelegate Methods
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logInfo("Bluetooth is powered on")
            isBluetoothReady = true
            pendingOperations.forEach { $0() }
            pendingOperations.removeAll()
        case .poweredOff:
            logWarning("Bluetooth is powered off")
            isBluetoothReady = false
        case .resetting:
            logWarning("Bluetooth is resetting")
            isBluetoothReady = false
        case .unauthorized:
            logError("Bluetooth is unauthorized")
            isBluetoothReady = false
        case .unsupported:
            logError("Bluetooth is unsupported")
            isBluetoothReady = false
        case .unknown:
            logWarning("Bluetooth state is unknown")
            isBluetoothReady = false
        @unknown default:
            logWarning("Unknown Bluetooth state")
            isBluetoothReady = false
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logInfo("Successfully connected to \(peripheral.name ?? "Unknown Device")")
        peripheral.delegate = self

        // Flush any stale data left over from a previous connection.
        // A late-arriving notification can sneak into receivedPackets after
        // close() clears the buffer but before cancelPeripheralConnection
        // takes effect.  Clearing here guarantees the protocol starts clean.
        queue.sync {
            receivedPackets.removeAll()
            partialPacket.removeAll()
        }
        while dataAvailableSemaphore.wait(timeout: .now()) == .success { }

        // Set isPeripheralReady synchronously so that callers busy-waiting on
        // this flag (e.g. connectToBLEDevice in BLEBridge.m) see it immediately
        // when the RunLoop processes this callback.  The @Published wrapper will
        // still notify SwiftUI/Combine observers on the main thread.
        self.isPeripheralReady = true
        self.connectedDevice = peripheral
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logError("Failed to connect to \(peripheral.name ?? "Unknown Device"): \(error?.localizedDescription ?? "No error description")")
        // Reset state so the app doesn't remain stuck in a connecting state.
        self.isPeripheralReady = false
        self.connectedDevice = nil
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logInfo("Disconnected from \(peripheral.name ?? "unknown device")")
        if let error = error {
            logError("Disconnect error: \(error.localizedDescription)")
        }
        
        if Logger.shared.isDebugMode {
            logDebug("[DISCONNECT] Full state: isDisconnecting=\(isDisconnecting), isRetrievingLogs=\(isRetrievingLogs), isConnecting=\(isConnecting), hasDeviceDataPtr=\(openedDeviceDataPtr != nil), peripheralState=\(peripheral.state.rawValue), error=\(error?.localizedDescription ?? "none")")
        }
        
        DispatchQueue.main.async {
            self.isPeripheralReady = false
            self.connectedDevice = nil
            
            // Don't attempt to reconnect if:
            // 1. We initiated the disconnect
            // 2. A download is currently in progress (will cause race conditions)
            // 3. A connection attempt is already in progress
            if !self.isDisconnecting && !self.isRetrievingLogs && !self.isConnecting {
                // Attempt to reconnect if this was a stored device
                if let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) {
                    logInfo("Attempting to reconnect to stored device")
                    _ = DeviceConfiguration.openBLEDevice(
                        name: storedDevice.name,
                        deviceAddress: storedDevice.uuid
                    )
                }
            } else if self.isRetrievingLogs {
                logWarning("⚠️ Disconnected during download - NOT auto-reconnecting to avoid race condition")
                if Logger.shared.isDebugMode {
                    logDebug("[DISCONNECT] During active retrieval - this will cause DC_STATUS_IO/PROTOCOL errors. currentRetrievalDevice: \(self.currentRetrievalDevice?.name ?? "nil"), error: \(error?.localizedDescription ?? "none")")
                }
            } else if self.isConnecting {
                logWarning("⚠️ Disconnected during connection attempt - NOT auto-reconnecting")
            }
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if peripheral.name != nil {
            // Add the peripheral if:
            // 1. It's a stored device
            // 2. It's a supported device
            // 3. We haven't already added it
            if DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) != nil ||
               DeviceConfiguration.fromName(peripheral.name ?? "") != nil {
                addDiscoveredPeripheral(peripheral)
            }
        }
    }

    // MARK: - CBPeripheral Methods
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logError("Error discovering services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else {
            logWarning("No services found")
            return
        }
        
        for service in services {
            if isExcludedService(service.uuid) {
                continue
            }
            
            if let knownService = isKnownSerialService(service.uuid) {
                preferredService = service
                writeCharacteristic = nil
                notifyCharacteristic = nil
            }
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logError("Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else {
            logWarning("No characteristics found for service: \(service.uuid)")
            return
        }
        
        // Only accept characteristics from the preferred (known dive-computer)
        // service. Other services (e.g. GATT 0x1801 with Service Changed
        // indicate characteristic) can overwrite the correct write/notify
        // characteristic and cause ATT errors on Mares, Aqualung, etc.
        if let preferred = preferredService, service.uuid != preferred.uuid {
            if Logger.shared.isDebugMode {
                logDebug("[BLE CHARS] Skipping non-preferred service: \(service.uuid.uuidString)")
            }
            return
        }
        
        if Logger.shared.isDebugMode {
            for characteristic in characteristics {
                logDebug("[BLE CHARS] service=\(service.uuid.uuidString) char=\(characteristic.uuid.uuidString) props=\(characteristic.properties.rawValue)")
            }
        }
        
        for characteristic in characteristics {
            // Prefer .writeWithoutResponse over .write — Mares BlueLink Pro
            // has both a data char (.writeWithoutResponse) and a control char
            // (.write). Writing protocol data to the control char causes an
            // "Unknown ATT error".
            if characteristic.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = characteristic
            } else if writeCharacteristic == nil && characteristic.properties.contains(.write) {
                writeCharacteristic = characteristic
            }
            
            // Prefer .notify over .indicate for the same reason.
            if characteristic.properties.contains(.notify) {
                notifyCharacteristic = characteristic
                // Note: Do NOT call setNotifyValue here — enableNotifications()
                // is called separately by connectToBLEDevice (BLEBridge.m) after
                // service discovery completes. Subscribing twice can confuse some
                // BLE stacks (e.g. Shearwater).
            } else if notifyCharacteristic == nil && characteristic.properties.contains(.indicate) {
                notifyCharacteristic = characteristic
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Error receiving data: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else {
            return
        }
        
        queue.sync {
            // Enqueue each BLE notification as a separate element to preserve
            // packet boundaries.  readDataPartial dequeues one at a time.
            receivedPackets.append(data)
        }

        // Signal that data is available - wake up any waiting read
        dataAvailableSemaphore.signal()

        updateTransferStats(data.count)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Error writing to characteristic: \(error.localizedDescription)")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logError("Error changing notification state: \(error.localizedDescription)")
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // Signal any write() call waiting on canSendWriteWithoutResponse
        writeReadySemaphore.signal()
    }

    // MARK: - Private Helpers
    private func updateTransferStats(_ newBytes: Int) {
        totalBytesReceived += newBytes
        
        if let last = lastDataReceived {
            let interval = Date().timeIntervalSince(last)
            if interval > 0 {
                let currentRate = Double(newBytes) / interval
                averageTransferRate = (averageTransferRate * 0.7) + (currentRate * 0.3)
            }
        }
        
        lastDataReceived = Date()
    }
    
    private func isKnownSerialService(_ uuid: CBUUID) -> SerialService? {
        return knownSerialServices.first { service in
            uuid.uuidString.lowercased() == service.uuid.lowercased()
        }
    }
    
    private func isExcludedService(_ uuid: CBUUID) -> Bool {
        return excludedServices.contains(uuid.uuidString.lowercased())
    }
    
    private func isWriteCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.write) ||
               characteristic.properties.contains(.writeWithoutResponse)
    }
    
    private func isReadCharacteristic(_ characteristic: CBCharacteristic) -> Bool {
        return characteristic.properties.contains(.notify) ||
               characteristic.properties.contains(.indicate)
    }

    @objc public func close() {
        close(clearDevicePtr: false)
    }
}

// MARK: - Extensions
extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
