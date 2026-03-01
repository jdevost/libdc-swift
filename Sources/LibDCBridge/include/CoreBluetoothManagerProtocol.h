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
@end

#else
// If we're compiling pure C (without Objective-C), provide an empty protocol definition
typedef void * CoreBluetoothManagerProtocol;
#endif

#endif /* CoreBluetoothManagerProtocol_h */ 