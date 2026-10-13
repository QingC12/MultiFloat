#import <Foundation/Foundation.h>
#import "../Bridge/MFBridge.h"

// Phase 0 Logos entry skeleton.
// Logos only owns process entry and event forwarding.
// Do not add a private method hook until its owner/signature/runtime behavior
// are verified for the target iOS build.

%ctor {
    MFCoreInitialize();

    // [VERIFY owner]
    // [VERIFY signature]
    // [VERIFY runtime behavior]
    // Known selectors from offline analysis, intentionally not implemented:
    // _handleOpenApplicationRequest:options:activationSettings:origin:withResult:
    // _handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:
    // _handleUntrustedOpenRequestForApplication:options:activationSettings:origin:withResult:
    // _openURLCore:display:animating:activationSettings:origin:withResult:
    // openInSplit:
    // sceneHandle:reuseExistingScene:
    // createSceneWithDefinition:initialParameters:
    // destroyScene:withTransitionContext:
}
