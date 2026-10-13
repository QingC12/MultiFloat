//
//  MFInternal.h — MultiFloat 内部共享接口
//
//  目标环境：[CONFIRMED] iPhone 15 Pro Max / iOS 17.3.1 / arm64e / roothide (Relaxin)
//
//  设计约束（来自真机多轮验证，勿推翻）：
//   1. 绝不依赖固定路径 dlopen ellekit/substrate；本版根本不装 hook，零后端依赖。
//   2. 一切落盘用 POSIX write，崩溃前最后一行必须已写进文件。
//   3. 默认惰性：没有 /var/mobile/MultiFloat.plist 或 enabled=false 时不做任何事。
//   4. 崩溃自解除：动真格之前先写标记文件，下一进程见到标记就跳过。
//   5. 【0.4.0 新增】承载链路每一步都写 `>>> 步名` / `<<< 步名 ok`。
//      崩溃后，最后一个没有配对的 `>>>` 就是崩点 —— 下一轮启动自动写成归因文件。
//   6. 【0.4.0 新增 · 血泪教训】绝不用"用户手打的字符串"当开关。
//      0.3.0 真机事故：用户在 Filza 里把 mode 写成 shell，iOS 键盘自动更正成 she'll，
//      于是 `isEqualToString:@"shell"` 判定失败 → 走进了 host 分支 → 每次启动自动承载 → 崩循环。
//      现在所有行为开关一律用 **布尔/整数**；字符串只做展示。
//   7. 【0.5.0 新增 · 又一个事故】两个布尔开关名字太像也会出事。
//      0.4.0 真机：用户只把 hostEnabled 改成 true，漏了 enabled 总显示开关，
//      于是 tweak 完全惰性、浮窗根本不出。修法：默认 enabled=true（装上就显示外壳），
//      并在启动时自动修复 "enabled=false 且 hostEnabled=true" 这种自相矛盾。
//   8. 【0.7.0 新增 · 只认公开可验证的实现】别再自己猜私有 API 的用法。
//      0.6.0 用 `[[UIScenePresentationManager alloc] _initWithScene:scene]` 自造 presenter 管理器
//      → 链路全通、不崩、但不渲染（presenter 进不了 hosting 状态，露出黑底）。
//      唯一被公开源码验证过的写法（khanhduytran0/FrontBoardAppLauncher，LiveContainer 多任务同款）是
//          FBScene *scene = ...;                       // 要么用已存在的，要么自己 createSceneWithDefinition:
//          presenter = [scene.uiPresentationManager createPresenterWithIdentifier:sceneID];
//          [presenter modifyPresentationContext:^(ctx){ ctx.appearanceStyle = 2; }];
//          [presenter activate];
//          [view addSubview:presenter.presentationView];
//      **manager 必须来自 scene 自己**，不能自己 alloc。
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
/// 老版本写下的 plist 缺 0.4.0 的新键时，原地补齐（避免用户手打键名被键盘自动更正坑到）
void MFUpgradeConfigIfNeeded(NSDictionary *cfg);

/// 【0.5.0 新增】修复自相矛盾的配置：enabled=false 但 hostEnabled=true
/// => 说明用户改开关时漏了总开关，这里把 enabled 补成 true 并回写磁盘。
/// 返回可能被修正过的配置，**调用方必须用返回值继续判断**（无需修正时原样返回）。
NSDictionary *MFRepairConfigContradiction(NSDictionary *cfg);

/// 配置读取一律走这三个，缺键/类型不符时返回 fallback（绝不返回垃圾值）
BOOL        MFConfigBool(NSDictionary *cfg, NSString *key, BOOL fallback);
NSInteger   MFConfigInt(NSDictionary *cfg, NSString *key, NSInteger fallback);
NSString   *MFConfigString(NSDictionary *cfg, NSString *key);

// ---- 崩溃自解除闸门 ----
BOOL MFAttemptExists(void);
void MFAttemptWrite(const char *why);
void MFAttemptClear(void);

// ---- 承载步骤追踪（崩溃归因）----
/// 每个危险调用【之前】写一行 `>>> tag t=… pid=…`
void MFStepMark(NSString *tag);
/// 该调用【返回之后】写一行 `<<< tag ok`
void MFStepOk(NSString *tag);
/// 启动时调用：分析上一轮的步骤日志，若最后一个 `>>>` 没有配对 => 那就是崩点。
/// 有结论时写 /var/mobile/MF-crash-attribution.txt 并把步骤日志轮转留档。
/// 返回崩点步名（nil = 上一轮没有崩在步骤里）。
NSString *MFStepRotateAndAnalyze(void);
/// 开一轮新的承载：清空步骤日志
void MFStepReset(void);

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
/// 把"上一轮崩在哪一步"告诉浮窗层，让浮窗启动后能在状态栏里显示它
void MFFloatSetBootCrashStep(NSString *step);

/// 格式化日志宏（Clang 的 , ##__VA_ARGS__ 在无参时自动吃掉逗号）
#define MFLog(fmt, ...) MFLogLine([NSString stringWithFormat:(fmt), ##__VA_ARGS__])
/// 无参日志（不带 % 占位符时用，避免零变参宏参的边界告警）
#define MFLogS(text)    MFLogLine(text)

#endif /* MF_INTERNAL_H */
