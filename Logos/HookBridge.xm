#import <Foundation/Foundation.h>
#import <unistd.h>
#import <fcntl.h>
#import <stdio.h>
#import <string.h>
#import <time.h>
#import "../Bridge/MFBridge.h"

// Phase 0 桥接桩：此文件不访问任何私有框架对象。
// [VERIFY] Theos Swift 集成与目标 ABI 确认后，再用已验证的 Swift 桥接替换。

// 注入存活证据：唯一能在设备端确认 dylib 已被 SpringBoard 加载的手段。
// 用纯 POSIX 写入（不依赖 ObjC/自动释放池），把 %ctor 阶段的崩溃风险降到最低。
// 日志落在 /var/mobile/MultiFloat.log，Filza 直接可见。
static void MFWriteLoadLog(void) {
    int fd = open("/var/mobile/MultiFloat.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char buf[256];
    int n = snprintf(buf, sizeof(buf),
                     "t=%ld pid=%d bundle=com.apple.springboard MultiFloat 0.2.0 loaded\n",
                     (long)time(NULL), getpid());
    if (n > 0) { ssize_t w = write(fd, buf, (size_t)n); (void)w; }
    close(fd);
}

void MFCoreInitialize(void) {
    // TODO VERIFY SWIFT BRIDGE INITIALIZATION
    MFWriteLoadLog();
}

void MFCoreNotifyEvent(NSString *eventName) {
    (void)eventName;
    // TODO VERIFY EVENT BRIDGE CONTRACT
}
