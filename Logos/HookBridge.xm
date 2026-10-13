#import <Foundation/Foundation.h>
#import "../Bridge/MFBridge.h"

// Phase 0 bridge only. No private framework object is accessed here.
// [VERIFY] Replace these no-op functions with the verified Swift bridge after
// Theos Swift integration and target iOS ABI are confirmed.

void MFCoreInitialize(void) {
    // TODO VERIFY SWIFT BRIDGE INITIALIZATION
}

void MFCoreNotifyEvent(NSString *eventName) {
    (void)eventName;
    // TODO VERIFY EVENT BRIDGE CONTRACT
}
