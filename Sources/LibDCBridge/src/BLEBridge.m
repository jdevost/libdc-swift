#import "BLEBridge.h"
#import "configuredc.h"
#import <Foundation/Foundation.h>

static id<CoreBluetoothManagerProtocol> bleManager = nil;

void initializeBLEManager(void) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    bleManager = [CoreBluetoothManagerClass shared];
}

ble_object_t* createBLEObject(void) {
    ble_object_t* obj = malloc(sizeof(ble_object_t));
    obj->manager = (__bridge void *)bleManager;
    obj->timeout_ms = -1; // Default: no timeout (wait forever)
    return obj;
}

void freeBLEObject(ble_object_t* obj) {
    if (obj) {
        free(obj);
    }
}

bool connectToBLEDevice(ble_object_t *io, const char *deviceAddress) {
    if (!io || !deviceAddress) {
        NSLog(@"[BLE] Invalid parameters passed to connectToBLEDevice");
        return false;
    }
    
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    NSString *address = [NSString stringWithUTF8String:deviceAddress];
    
    NSLog(@"[BLE] Connecting to device: %@", address);
    
    bool success = [manager connectToDevice:address];
    if (!success) {
        NSLog(@"[BLE] ERROR: connectToDevice returned false");
        return false;
    }
    
    // Wait for connection to complete by checking peripheral ready state
    NSDate *timeout = [NSDate dateWithTimeIntervalSinceNow:10.0]; // 10 second timeout
    while ([[NSDate date] compare:timeout] == NSOrderedAscending) {
        // Check if peripheral is ready using protocol method
        if ([manager getPeripheralReadyState]) {
            NSLog(@"[BLE] Peripheral is ready for communication");
            break;
        }
        // Small sleep to avoid busy-waiting
        [NSThread sleepForTimeInterval:0.1];
    }
    
    // Final check if we're actually ready
    if (![manager getPeripheralReadyState]) {
        NSLog(@"[BLE] ERROR: Timeout (10s) waiting for peripheral to be ready");
        [manager close];
        return false;
    }

    success = [manager discoverServices];
    if (!success) {
        NSLog(@"[BLE] ERROR: Service discovery failed");
        [manager close];
        return false;
    }
    NSLog(@"[BLE] Service discovery succeeded");

    success = [manager enableNotifications];
    if (!success) {
        NSLog(@"[BLE] ERROR: Failed to enable notifications");
        [manager close];
        return false;
    }
    NSLog(@"[BLE] Notifications enabled, connection fully established");
    
    return true;
}

bool discoverServices(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    return [manager discoverServices];
}

bool enableNotifications(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    return [manager enableNotifications];
}

dc_status_t ble_set_timeout(ble_object_t *io, int timeout) {
    if (!io) return DC_STATUS_INVALIDARGS;

    int old_timeout = io->timeout_ms;
    io->timeout_ms = timeout;

    // Forward timeout to the Swift BLEManager so readDataPartial uses it
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    [manager setTimeout:timeout];

    if (get_libdc_loglevel() >= DC_LOGLEVEL_DEBUG) {
        NSLog(@"[BLE TIMEOUT] set_timeout: %d ms -> %d ms", old_timeout, timeout);
    }

    return DC_STATUS_SUCCESS;
}

dc_status_t ble_ioctl(ble_object_t *io, unsigned int request, void *data, size_t size) {
    // DC_IOCTL_BLE_GET_NAME = DC_IOCTL_IOR('b', 0, 0) = 0x40006200
    // The Oceanic protocol requires the BLE device name to perform a
    // handshake (extracts the serial number from the name).  Without
    // this, downloads fail with NAK responses.
    const unsigned int BLE_GET_NAME = 0x40006200;
    if (request == BLE_GET_NAME) {
        if (!data || size == 0) {
            return DC_STATUS_INVALIDARGS;
        }
        Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
        id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
        NSString *name = [manager getDeviceName];
        if (!name || name.length == 0) {
            bridge_log("[BLE IOCTL] GET_NAME: no device name available\n");
            return DC_STATUS_UNSUPPORTED;
        }
        const char *utf8 = [name UTF8String];
        size_t len = strlen(utf8);
        if (len >= size) {
            len = size - 1;
        }
        memcpy(data, utf8, len);
        ((char *)data)[len] = '\0';
        bridge_log("[BLE IOCTL] GET_NAME: '%s' (%zu bytes)\n", (char *)data, len);
        return DC_STATUS_SUCCESS;
    }

    return DC_STATUS_UNSUPPORTED;
}

dc_status_t ble_sleep(ble_object_t *io, unsigned int milliseconds) {
    [NSThread sleepForTimeInterval:milliseconds / 1000.0];
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_read(ble_object_t *io, void *buffer, size_t requested, size_t *actual)
{
    if (!io || !buffer || !actual) {
        NSLog(@"[BLE READ] ERROR: Invalid arguments (io=%p, buffer=%p, actual=%p)", io, buffer, actual);
        return DC_STATUS_INVALIDARGS;
    }

    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];

    // Return one BLE packet at a time to preserve packet boundaries for SLIP framing
    NSData *partialData = [manager readDataPartial:(int)requested];

    if (!partialData || partialData.length == 0) {
        *actual = 0;
        // This is the most common cause of DC_STATUS_PROTOCOL errors upstream:
        // readDataPartial timed out (3s) returning nil, which we report as IO error.
        // In debug mode, log every occurrence to help correlate with protocol failures.
        if (get_libdc_loglevel() >= DC_LOGLEVEL_DEBUG) {
            NSLog(@"[BLE READ] Timeout/empty: readDataPartial returned %@ (requested %zu bytes) -> DC_STATUS_IO",
                  partialData == nil ? @"nil" : @"empty", requested);
        }
        return DC_STATUS_IO;
    }
    memcpy(buffer, partialData.bytes, partialData.length);
    *actual = partialData.length;
    return DC_STATUS_SUCCESS;
}

dc_status_t ble_write(ble_object_t *io, const void *data, size_t size, size_t *actual) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    NSData *nsData = [NSData dataWithBytes:data length:size];
    
    if ([manager writeData:nsData]) {
        *actual = size;
        return DC_STATUS_SUCCESS;
    } else {
        *actual = 0;
        NSLog(@"[BLE WRITE] ERROR: writeData returned false (%zu bytes)", size);
        return DC_STATUS_IO;
    }
}

dc_status_t ble_close(ble_object_t *io) {
    Class CoreBluetoothManagerClass = NSClassFromString(@"CoreBluetoothManager");
    id<CoreBluetoothManagerProtocol> manager = [CoreBluetoothManagerClass shared];
    [manager close];
    return DC_STATUS_SUCCESS;
}
