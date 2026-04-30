#ifndef CoreBluetoothManagerProtocol_h
#define CoreBluetoothManagerProtocol_h

#ifdef __OBJC__
#import <Foundation/Foundation.h>

@protocol CoreBluetoothManagerProtocol <NSObject>
+ (id)shared;
- (BOOL)connectToDevice:(NSString *)address;
- (BOOL)getPeripheralReadyState;
- (BOOL)discoverServices;
- (BOOL)enableNotifications;
- (BOOL)writeData:(NSData *)data;
- (NSData *)readDataPartial:(int)requested;
- (void)setTimeout:(int)timeoutMs;
- (void)close;
/// Returns the connected peripheral's advertised Bluetooth name (e.g.
/// "FH020399"), or an empty string if no peripheral is connected.
/// Required by libdivecomputer's DC_IOCTL_BLE_GET_NAME for Oceanic /
/// Aqualung models (i300C, i550C, i770R, etc.) that embed digits of the
/// serial number in the advertised name and use it during the protocol
/// handshake.  Without this the READMEMORY command is answered with NAK
/// (0xA5) instead of an ACK + payload.
- (NSString *)getDeviceName;
@end

#else
// If we're compiling pure C (without Objective-C), provide an empty protocol definition
typedef void * CoreBluetoothManagerProtocol;
#endif

#endif /* CoreBluetoothManagerProtocol_h */ 