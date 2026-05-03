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
    /// True once at least one BLE notification has been received from the
    /// device on the current connection.  Used by `readDataPartial` to apply
    /// a longer timeout floor (5 s) on the very first read so sleepy devices
    /// (notably Aqualung i300C) get enough time to respond to the initial
    /// VERSION query before libdivecomputer's 1 s default fires.
    private var hasReceivedFirstPacket: Bool = false
    
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
            logDebug("[BLE DISCOVER] Completed in \(String(format: "%.2f", elapsed))s - writeChar: \(writeCharacteristic?.uuid.uuidString ?? "nil"), notifyChar: \(notifyCharacteristic?.uuid.uuidString ?? "nil")")
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
        // 30 s gives the user enough time to complete first-time BLE pairing
        // (entering the passkey shown by iOS on the dive computer).
        let timeout = Date(timeIntervalSinceNow: 30.0)
        while !notifyCharacteristic.isNotifying {
            if Date() > timeout {
                logError("Timeout waiting for notifications to enable (30s)")
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
    /// device-name-based handshake required by Oceanic / Aqualung models
    /// (e.g. i300C, i550C, i770R, i200C), which embed digits of the serial
    /// number in the advertised name (e.g. "FH020399") and rely on it
    /// during the READMEMORY command.  Returning an empty string causes
    /// the dive computer to answer with NAK (0xA5) instead of ACK + data.
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

        // If using write-without-response, briefly wait for the peripheral to
        // signal readiness.  This provides back-pressure when the BLE transmit
        // buffer is full.  However, we must NOT hard-fail on timeout because
        // canSendWriteWithoutResponse can get stuck false on some BLE stacks
        // (e.g. after connection parameter renegotiation) even though the
        // peripheral is perfectly able to accept data.  In that case we fall
        // back to writing anyway — CoreBluetooth will buffer internally.
        if characteristic.properties.contains(.writeWithoutResponse) {
            if !peripheral.canSendWriteWithoutResponse {
                // Brief wait (up to 500ms) for the transmit buffer to drain
                let deadline = Date(timeIntervalSinceNow: 0.5)
                while !peripheral.canSendWriteWithoutResponse {
                    if Date() > deadline {
                        // Fall through and write anyway — don't hard-fail
                        logWarning("[BLE WRITE] canSendWriteWithoutResponse still false after 500ms, writing anyway (\(data?.count ?? 0) bytes)")
                        break
                    }
                    // Wait for peripheralIsReady(toSendWriteWithoutResponse:) callback
                    let result = writeReadySemaphore.wait(timeout: .now() + .milliseconds(50))
                    if result == .timedOut {
                        continue
                    }
                }
            }
            if Logger.shared.isDebugMode {
                logDebug("[BLE WRITE] canSendWriteWithoutResponse=\(peripheral.canSendWriteWithoutResponse), writing \(data?.count ?? 0) bytes")
            }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
        return true
    }
    
    @objc public func readDataPartial(_ requested: Int32) -> Data? {
        let requestedInt = Int(requested)
        let startTime = Date()
        // Use the timeout set by libdivecomputer via ble_set_timeout.
        // If timeout is -1 (no timeout set), default to 3s for safety.
        // If timeout is 0, it means "poll" — return immediately if no data.
        let effectiveTimeoutMs = self.bleTimeoutMs
        var timeoutInterval: TimeInterval = effectiveTimeoutMs <= 0 ? 3.0 : Double(effectiveTimeoutMs) / 1000.0
        // First-read floor: until we have received at least one notification
        // on this connection, give the device up to 5 s to answer.
        //
        // The Aqualung i300C (and likely other Pelagic OEMs) reliably ignores
        // the first protocol query after a fresh BLE link is established.
        // The cure is a connect → fail → reconnect cycle: the second
        // connection finds the device responsive within ~10 ms.
        //
        // The 5 s value is empirically required: shorter floors (2 s) leave
        // the peripheral in a half-disconnected state when the immediate
        // reconnect kicks in, causing the second `connectToBLEDevice` to
        // time out at its 10 s peripheral-ready wait.  5 s gives CoreBluetooth
        // enough time to release the previous connection cleanly so the
        // retry lands on a fresh peripheral.
        //
        // Once the first packet is in, drop back to libdc's configured
        // timeout so mid-transfer stalls fail fast as expected.
        if !hasReceivedFirstPacket && timeoutInterval < 5.0 && effectiveTimeoutMs != 0 {
            timeoutInterval = 5.0
        }

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
            logDebug("readDataPartial timeout after \(String(format: "%.1f", timeoutInterval))s (requested \(requestedInt) bytes, configured timeout: \(effectiveTimeoutMs) ms, peripheral state: \(peripheralState), isRetrievingLogs: \(isRetrievingLogs))")
        }
        return nil
    }
    
    // MARK: - Device Management
    @objc public func close(clearDevicePtr: Bool = false) {
        // Guard against re-entrant calls. free_device_data() closes the
        // libdivecomputer iostream, whose close callback invokes this
        // method again with clearDevicePtr=false. Without this guard the
        // inner call schedules its own asyncAfter that resets
        // isDisconnecting to false before didDisconnectPeripheral runs,
        // causing spurious auto-reconnect.
        if isDisconnecting {
            return
        }
        let closeStartTime = Date()
        if Logger.shared.isDebugMode {
            logDebug("[BLE CLOSE] Starting close(clearDevicePtr: \(clearDevicePtr)) on thread: \(Thread.isMainThread ? "main" : "background"), peripheral: \(peripheral?.name ?? "nil"), state: \(peripheral?.state.rawValue ?? -1)")
        }
        
        // Reset timeout to default for next connection
        self.bleTimeoutMs = -1
        // Note: hasReceivedFirstPacket is reset further below, AFTER
        // free_device_data() runs, so the exit-command read issued during
        // teardown still benefits from the flag being `true` (set by the
        // successful download).  Resetting it here would force the exit
        // command to wait the full 5 s floor on devices that don't ack
        // their close packet (notably i300C, which auto-disables BT after
        // a successful sync).
        // isDisconnecting MUST be true before cancelPeripheralConnection so
        // didDisconnectPeripheral sees it and skips auto-reconnect.  Use sync
        // (not async) to guarantee ordering, with a main-thread guard to
        // avoid deadlock.
        let setFlags = {
            self.isDisconnecting = true
            self.isPeripheralReady = false
            self.connectedDevice = nil
        }
        if Thread.isMainThread { setFlags() } else { DispatchQueue.main.sync(execute: setFlags) }
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
                // device_data_t was allocated by C calloc() in
                // open_ble_device_with_identification.  It MUST be freed by
                // the matching C allocator — never UnsafeMutablePointer
                // .deallocate(), which uses Swift's allocator and produces
                // "pointer being freed was not allocated" + heap corruption.
                // free_device_data also closes the libdc device, iostream
                // and context, and releases model/fingerprint buffers that
                // would otherwise leak.
                // Check before free — pointer is invalid after free_device_data.
                let hadDevice = devicePtr.pointee.device != nil
                free_device_data(devicePtr)
                // dc_device_close (called inside free_device_data) sends a
                // protocol-level shutdown command (e.g. Shearwater "exit
                // command mode" packet).  The BLE writeValue is asynchronous,
                // so we must give the BLE stack time to flush the write
                // before cancelPeripheralConnection tears down the link.
                // Without this delay the dive computer never receives the
                // shutdown and stays stuck on "Sending Dive" / "WAIT CMD".
                if hadDevice {
                    Thread.sleep(forTimeInterval: 0.5)
                }
                self.openedDeviceDataPtr = nil
            }
        }
        
        if let peripheral = self.peripheral {
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            DispatchQueue.main.async {
                self.peripheral = nil
            }
            centralManager.cancelPeripheralConnection(peripheral)
        }

        // Reset first-packet flag here (after teardown) so the next open
        // re-applies the 5 s floor on its initial read.  See the comment
        // at the top of close() for why this is deferred.
        hasReceivedFirstPacket = false

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
        
        if Thread.isMainThread {
            self.peripheral = peripheral
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.peripheral = peripheral
            }
        }
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
        DispatchQueue.main.async {
            self.isPeripheralReady = false
            self.connectedDevice = nil
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
            self.peripheral = nil
        }
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
        // Set isPeripheralReady synchronously so that callers busy-waiting on
        // this flag (e.g. connectToBLEDevice in BLEBridge.m) see it immediately
        // when the RunLoop processes this callback.  The @Published wrapper will
        // still notify SwiftUI/Combine observers on the main thread.
        self.isPeripheralReady = true
        self.connectedDevice = peripheral
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logError("Failed to connect to \(peripheral.name ?? "Unknown Device"): \(error?.localizedDescription ?? "No error description")")
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
                    logInfo("Attempting to reconnect to stored device after brief delay")
                    // 500 ms delay gives CoreBluetooth and the dive computer time to tear
                    // down the previous connection. Without this, sleepy devices (i300C)
                    // can fail the second connect with a 10 s peripheral-ready timeout.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        _ = DeviceConfiguration.openBLEDevice(
                            name: storedDevice.name,
                            deviceAddress: storedDevice.uuid
                        )
                    }
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
        // service.  Other services such as GATT 0x1801 expose generic
        // characteristics (e.g. "Service Changed" indicate) that would
        // otherwise overwrite our real write/notify selection and produce
        // "Unknown ATT error" on the next protocol write.
        if let preferred = preferredService, service.uuid != preferred.uuid {
            return
        }

        // Two-pass selection.
        //
        // Several dive computers expose multiple characteristics with the
        // same property bits in the same service.  Examples:
        //
        //   • Aqualung i300C / Pelagic OEMs:  one .writeWithoutResponse +
        //     one .write data char, plus an auth-nonce .notify char in
        //     addition to the protocol-data .notify char.
        //   • Mares BlueLink Pro: a data channel and a control/config
        //     channel both with write capability.
        //
        // The previous single-pass loop overwrote the selection on every
        // matching characteristic, so for the i300C we ended up subscribed
        // to the auth-nonce characteristic (UUID A60B8E5C…) instead of the
        // data characteristic.  All READMEMORY replies were silently
        // dropped, producing "Failed to receive the answer" / -6.
        //
        // Pass 1: pick the FIRST .writeWithoutResponse / .notify we see.
        // Pass 2: only if no preferred match was found, fall back to the
        //         FIRST .write / .indicate characteristic.
        for characteristic in characteristics {
            if writeCharacteristic == nil &&
               characteristic.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = characteristic
            }
            if notifyCharacteristic == nil &&
               characteristic.properties.contains(.notify) {
                notifyCharacteristic = characteristic
                // Note: Do NOT call setNotifyValue here — enableNotifications()
                // is called separately by connectToBLEDevice (BLEBridge.m) after
                // service discovery completes. Subscribing twice can confuse some
                // BLE stacks (e.g. Shearwater).
            }
        }
        for characteristic in characteristics {
            if writeCharacteristic == nil &&
               characteristic.properties.contains(.write) {
                writeCharacteristic = characteristic
            }
            if notifyCharacteristic == nil &&
               characteristic.properties.contains(.indicate) {
                notifyCharacteristic = characteristic
            }
        }

        if Logger.shared.isDebugMode {
            logDebug("[BLE DISCOVER] Service \(service.uuid) characteristics:")
            for c in characteristics {
                logDebug("  - \(c.uuid) props=\(c.properties.rawValue)")
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
        // Mark that the device has answered at least once so subsequent
        // reads use libdc's configured timeout (no 5 s first-read floor).
        hasReceivedFirstPacket = true

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
