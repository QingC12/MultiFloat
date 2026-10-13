//
//  MFInternal.h — MultiFloat 内部共享接口
//
//  目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
//
//  设计约束（来自前三轮真机验证，勿推翻）：
//   1. 绝不依赖固定路径 dlopen ellekit/substrate；本版根本不装 hook，零后端依赖。
//   2. 一切落盘用 POSIX write，崩溃前最后一行必须已写进文件。
//   3. 默认惰性：没有 /var/mobile/MultiFloat.plist 或 enabled=false 时不做任何事。
//   4. 崩溃自解除：动真格之前先写标记文件，下一进程见到标记就跳过。
//
#ifndef MF_INTERNAL_H
#define MF_INTERNAL_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <time.h>
#include <sys/stat.h>

// ---- 版本 ----
NSString *MFVersionString(void);

// ---- 日志 ----
void MFLogLine(NSString *line);
void MFLogRawC(const char *utf8);

// ---- 配置 ----
NSDictionary *MFLoadConfig(void);
void MFWriteDefaultConfigIfNeeded(void);

// ---- 崩溃自解除闸门 ----
BOOL MFAttemptExists(void);
void MFAttemptWrite(const char *mode);
void MFAttemptClear(void);

// ---- 运行期消息发送（全部带 respondsToSelector 守卫）----
id MFMsg(id obj, SEL sel);
id MFMsg1(id obj, SEL sel, id a);
NSString *MFStr(id obj, SEL sel);
BOOL MFBoolProp(id obj, SEL sel);
NSInteger MFIntProp(id obj, SEL sel);

/// 把 NSArray / NSSet / NSDictionary / 任何有 allObjects / objectEnumerator 的容器统一成 NSArray
NSArray *MFIterate(id collection);
/// 取类的单例（依次尝试 sharedInstance / sharedInstanceIfExists）
id MFClassSharedInstance(NSString *name);
/// 这个 selector 在类的实例方法表里存在吗
BOOL MFClassHasInstanceMethod(NSString *className, NSString *selName);

// ---- 对外入口 ----
void MFFloatBootstrap(void);

/// 格式化日志宏（Clang 的 , ##__VA_ARGS__ 在无参时自动吃掉逗号）
#define MFLog(fmt, ...) MFLogLine([NSString stringWithFormat:(fmt), ##__VA_ARGS__])
/// 无参日志（不带 % 占位符时用，避免零变参宏参的边界告警）
#define MFLogS(text)    MFLogLine(text)

#endif /* MF_INTERNAL_H */
