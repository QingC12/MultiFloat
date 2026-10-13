#import <Foundation/Foundation.h>
#import <unistd.h>
#import "../Bridge/MFBridge.h"

// Phase 0 bridge only. No private framework object is accessed here.
// [VERIFY] Replace these no-op functions with the verified Swift bridge after
// Theos Swift integration and target iOS ABI are confirmed.

// 注入存活日志：设备端唯一可观测证据，用于确认 dylib 已被 SpringBoard 加载。
// 只保留最近 40 行，避免日志无限增长。仅使用类方法，兼容 ARC / MRC。
static void MFAppendLoadLog(NSString *line) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dir = @"/var/mobile/Library/Logs";
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:@"MultiFloat.log"];

        NSString *existing = [NSString stringWithContentsOfFile:path
                                                       encoding:NSUTF8StringEncoding
                                                          error:NULL];
        NSMutableArray *lines = [NSMutableArray arrayWithArray:
            (existing.length > 0) ? [existing componentsSeparatedByString:@"\n"] : [NSArray array]];
        while (lines.count > 40) {
            [lines removeObjectAtIndex:0];
        }
        [lines addObject:line];
        NSString *joined = [lines componentsJoinedByString:@"\n"];
        [joined writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        // 同步一份到 Filza / 文件 App 容易取到的位置
        NSString *mediaDir = @"/var/mobile/Media/MultiFloatProbe";
        [fm createDirectoryAtPath:mediaDir withIntermediateDirectories:YES attributes:nil error:NULL];
        [joined writeToFile:[mediaDir stringByAppendingPathComponent:@"MultiFloat.log"]
                   atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {
        NSLog(@"[MultiFloat] load log failed: %@", e);
    }
}

void MFCoreInitialize(void) {
    // TODO VERIFY SWIFT BRIDGE INITIALIZATION
    MFAppendLoadLog([NSString stringWithFormat:
        @"[MultiFloat 0.1.1] MFCoreInitialize OK pid=%d bundle=%@",
        getpid(),
        [[NSBundle mainBundle] bundleIdentifier]]);
}

void MFCoreNotifyEvent(NSString *eventName) {
    (void)eventName;
    // TODO VERIFY EVENT BRIDGE CONTRACT
}
