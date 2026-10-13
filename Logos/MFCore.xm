//
//  MFCore.xm — 日志 / 配置 / 崩溃自解除闸门 / 承载步骤追踪 / 安全消息发送
//
//  本文件不做任何 UI、不装任何 hook，只提供可被安全调用的基础设施。
//  所有函数在参数异常时必须"返回而不是崩"，因为调用方在 SpringBoard 主进程里。
//
#import "MFInternal.h"

#pragma mark - ---------- 版本 ----------

NSString *MFVersionString(void) {
    return @"0.5.0";
}

#pragma mark - ---------- 底层落盘 ----------

/// 一次性 open→write→close，保证崩溃前该行已经在盘上（不做缓冲）
static void MFRawAppend(const char *path, const char *utf8, size_t len) {
    if (path == NULL || utf8 == NULL || len == 0) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    ssize_t written = write(fd, utf8, len);
    (void)written;
    close(fd);
}

static void MFWriteBothPaths(const char *utf8) {
    if (utf8 == NULL) return;
    // /var/mobile/Media/... 在"文件"App 与 Filza 里都好找；/var/mobile 是用户既定目录
    mkdir("/var/mobile/Media/MultiFloat", 0755);
    size_t len = strlen(utf8);
    MFRawAppend("/var/mobile/MultiFloat.log", utf8, len);
    MFRawAppend("/var/mobile/Media/MultiFloat/MultiFloat.log", utf8, len);
}

void MFLogRawC(const char *utf8) {
    MFWriteBothPaths(utf8);
}

void MFLogLine(NSString *line) {
    if (line == nil) return;
    NSString *full = [NSString stringWithFormat:@"t=%ld pid=%d ver=%@ %@\n",
                      (long)time(NULL), (int)getpid(), MFVersionString(), line];
    const char *utf8 = full.UTF8String;
    if (utf8 == NULL) return;
    MFWriteBothPaths(utf8);
    NSLog(@"[MultiFloat] %@", line);
}

#pragma mark - ---------- 配置 ----------

static NSArray *MFConfigCandidatePaths(void) {
    return @[ @"/var/mobile/MultiFloat.plist", @"/var/mobile/Media/MultiFloat.plist" ];
}

BOOL MFConfigBool(NSDictionary *cfg, NSString *key, BOOL fallback) {
    if (cfg == nil || key == nil) return fallback;
    id v = cfg[key];
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return fallback;
}

NSInteger MFConfigInt(NSDictionary *cfg, NSString *key, NSInteger fallback) {
    if (cfg == nil || key == nil) return fallback;
    id v = cfg[key];
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    return fallback;
}

NSString *MFConfigString(NSDictionary *cfg, NSString *key) {
    if (cfg == nil || key == nil) return nil;
    id v = cfg[key];
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

NSDictionary *MFLoadConfig(void) {
    for (NSString *path in MFConfigCandidatePaths()) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([dict isKindOfClass:[NSDictionary class]]) {
            MFLog(@"[cfg] loaded %@ keys=%lu", path, (unsigned long)dict.count);
            return dict;
        }
        MFLog(@"[cfg] %@ 解析失败，跳过", path);
    }
    return nil;
}

//  0.5.0 的默认配置：**装上就显示外壳，但绝不承载**。
//    enabled    = true    —— 总显示开关（0.4.0 这里误设为 false，直接导致"改了 hostEnabled 却毫无反应"）
//    hostEnabled= false   —— 真承载开关（只有它为 true 才可能碰 SpringBoard 的宿主视图）
//    hostStep   = 6       —— 承载链路最多走到第几步（1..6，测试用；默认走满）
//    mode       = "shell" —— 纯展示用，**不再参与任何判断**（见 MFInternal.h 里 she'll 事故记录）
//
//  为什么 0.5.0 把 enabled 默认改成 true：
//    0.4.0 的注释写着"防线 1 默认 hostEnabled=false：装上只显示外壳"，
//    但代码里 enabled 也写成了 false —— 装上连外壳都不显示，与设计意图自相矛盾，
//    用户改 hostEnabled 时也被这个隐形的总开关挡住（真机事故：浮窗完全不出现）。
//    0.3.0 已真机证明"只显示外壳"是安全的（可拖可缩放，连续多轮 respring 无崩），
//    所以总开关默认打开安全；真正危险的 hostEnabled 仍然默认关。
void MFWriteDefaultConfigIfNeeded(void) {
    NSString *path = @"/var/mobile/MultiFloat.plist";
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    NSDictionary *def = @{
        @"enabled"        : @YES,                      // 总显示开关：装上就显示外壳
        @"mode"           : @"shell",                  // 仅展示
        @"hostEnabled"    : @NO,                       // 真承载：默认关
        @"hostStep"       : @6,                        // 承载最多走到第几步
        @"targetBundleID" : @"com.apple.mobilesafari",
        @"showDelay"      : @12,
        @"windowLevel"    : @1010,
    };
    BOOL ok = [def writeToFile:path atomically:YES];
    MFLog(@"[cfg] 写出默认配置 %@ ok=%d（enabled=true 显示外壳 / hostEnabled=false 不承载）", path, (int)ok);
}

/// 0.3.0 的 plist 只有 5 个键，缺 hostEnabled/hostStep。
/// 与其让用户用 Filza 手打新键名（键盘自动更正随时会把键值改坏），
/// 不如我们把这几个键原地补上，用户只需要把 false 改成 true。
void MFUpgradeConfigIfNeeded(NSDictionary *cfg) {
    if (cfg == nil) return;
    if (cfg[@"hostEnabled"] != nil && cfg[@"hostStep"] != nil) return;

    for (NSString *path in MFConfigCandidatePaths()) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![onDisk isKindOfClass:[NSDictionary class]]) continue;

        NSMutableDictionary *up = [onDisk mutableCopy];
        if (up[@"hostEnabled"] == nil) up[@"hostEnabled"] = @NO;
        if (up[@"hostStep"]    == nil) up[@"hostStep"]    = @6;
        if (up[@"mode"]        == nil) up[@"mode"]        = @"shell";
        BOOL ok = [up writeToFile:path atomically:YES];
        MFLog(@"[cfg] 补齐 0.4.0 新键于 %@ ok=%d（hostEnabled=false / hostStep=6）", path, (int)ok);
        return;
    }
}

/// 0.5.0 真机事故的修复：用户把 hostEnabled 改成 true，却漏了 enabled 这个总开关
/// （它俩名字太像），于是 tweak 完全惰性、连外壳都不显示，用户以为"改了开关没反应"。
/// 与其再被这样绊一次，启动时直接把这种自相矛盾的配置修好：
///     enabled=false 且 hostEnabled=true  =>  用户意图显然是"要用" => 把 enabled 补成 true。
/// 只补总显示开关，**绝不自动打开 hostEnabled**（真承载开关必须由用户显式打开）。
/// 返回可能被修正过的配置（调用方必须用返回值继续判断），无需修正时原样返回。
NSDictionary *MFRepairConfigContradiction(NSDictionary *cfg) {
    if (cfg == nil) return cfg;
    BOOL enabled  = MFConfigBool(cfg, @"enabled", NO);
    BOOL hostWanted = MFConfigBool(cfg, @"hostEnabled", NO);
    if (enabled || !hostWanted) return cfg;   // 不矛盾，什么都不做

    MFLogRawC("[cfg] !! 配置自相矛盾：enabled=false 但 hostEnabled=true\n"
              "[cfg]    （这就是“改了 hostEnabled 却没出现浮窗”的原因：enabled 是总开关，优先于一切）\n"
              "[cfg]    已自动把 enabled 补成 true；hostEnabled 保持你自己的选择不变。\n");

    NSMutableDictionary *fixed = [cfg mutableCopy];
    fixed[@"enabled"] = @YES;
    for (NSString *path in MFConfigCandidatePaths()) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        BOOL ok = [fixed writeToFile:path atomically:YES];
        MFLog(@"[cfg] 回写修正后的配置 %@ ok=%d（enabled=true）", path, (int)ok);
        break;
    }
    return fixed;
}

#pragma mark - ---------- 崩溃自解除闸门 ----------

static const char *const kMFAttemptPath = "/var/mobile/MF-float-attempt.txt";

BOOL MFAttemptExists(void) {
    return access(kMFAttemptPath, F_OK) == 0;
}

void MFAttemptWrite(const char *why) {
    int fd = open(kMFAttemptPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        MFLogRawC("[gate] !! 无法写出 attempt 标记（本轮没有崩溃保护）\n");
        return;
    }
    char buf[200];
    const char *w = (why != NULL) ? why : "?";
    int n = snprintf(buf, sizeof(buf), "why=%s t=%ld pid=%d\n", w, (long)time(NULL), (int)getpid());
    if (n > 0) {
        ssize_t written = write(fd, buf, (size_t)n);
        (void)written;
    }
    close(fd);
    MFLog(@"[gate] attempt 标记已写（%s）：下一次启动若它还在 => 本轮崩了 => 本轮不再承载", w);
}

void MFAttemptClear(void) {
    unlink(kMFAttemptPath);
}

#pragma mark - ---------- 承载步骤追踪（崩溃归因）----------

static const char *const kMFStepPath      = "/var/mobile/MF-host-step.txt";
static const char *const kMFStepPrevPath  = "/var/mobile/MF-host-step-prev.txt";
static const char *const kMFAttribPath    = "/var/mobile/MF-crash-attribution.txt";

static void MFStepWrite(const char *prefix, NSString *tag) {
    if (tag == nil) return;
    char buf[220];
    int n = snprintf(buf, sizeof(buf), "%s %s t=%ld pid=%d\n",
                     prefix, tag.UTF8String, (long)time(NULL), (int)getpid());
    if (n > 0) MFRawAppend(kMFStepPath, buf, (size_t)n);
}

void MFStepMark(NSString *tag) { MFStepWrite(">>>", tag); }
void MFStepOk(NSString *tag)   { MFStepWrite("<<<", tag); }

void MFStepReset(void) {
    unlink(kMFStepPath);
}

/// 把整个文件读进内存（步骤日志很短，上限 256KB 足够）
static NSMutableData *MFReadWholeFile(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return nil;
    NSMutableData *out = [NSMutableData data];
    char chunk[4096];
    ssize_t got = 0;
    size_t total = 0;
    while ((got = read(fd, chunk, sizeof(chunk))) > 0) {
        [out appendBytes:chunk length:(NSUInteger)got];
        total += (size_t)got;
        if (total > (256u * 1024u)) break;   // 保险丝
    }
    close(fd);
    return out;
}

NSString *MFStepRotateAndAnalyze(void) {
    if (access(kMFStepPath, F_OK) != 0) return nil;

    NSMutableData *data = MFReadWholeFile(kMFStepPath);
    NSString *crashed = nil;

    if (data.length > 0) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text == nil) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];

        NSString *pending = nil;      // 最后一个还没配对的 >>> 步名
        for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (line.length == 0) continue;
            // 形如 ">>> S4-vc t=… pid=…"
            NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
            if (parts.count < 2) continue;
            NSString *head = parts[0];
            NSString *tag  = parts[1];
            if ([head isEqualToString:@">>>"]) {
                pending = tag;
            } else if ([head isEqualToString:@"<<<"] && pending != nil && [tag isEqualToString:pending]) {
                pending = nil;
            }
        }
        crashed = pending;
    }

    // 无论有没有结论，都把这一轮日志留档，然后开新的一轮
    if (crashed.length > 0) {
        NSString *why = [NSString stringWithFormat:
                         @"crashedStep=%@\n说明：上一轮承载走到 %@ 之后进程消失，"
                         @"也就是说崩点就在这一步（或其内部的异步副作用）。\n"
                         @"t=%ld\n",
                         crashed, crashed, (long)time(NULL)];
        [why writeToFile:@(kMFAttribPath) atomically:YES
                encoding:NSUTF8StringEncoding error:NULL];
        MFLog(@"[gate] ★ 崩溃归因：上一轮崩在步骤 %@（详见 /var/mobile/MF-crash-attribution.txt）", crashed);
    }

    // 留档 + 清空
    [[NSFileManager defaultManager] removeItemAtPath:@(kMFStepPrevPath) error:NULL];
    [[NSFileManager defaultManager] moveItemAtPath:@(kMFStepPath)
                                            toPath:@(kMFStepPrevPath)
                                             error:NULL];
    return crashed;
}

#pragma mark - ---------- 安全消息发送 ----------

id MFMsg(id obj, SEL sel) {
    if (obj == nil || sel == NULL) return nil;
    if (![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

id MFMsg1(id obj, SEL sel, id a) {
    if (obj == nil || sel == NULL) return nil;
    if (![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(obj, sel, a);
}

NSString *MFStr(id obj, SEL sel) {
    id v = MFMsg(obj, sel);
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

BOOL MFBoolProp(id obj, SEL sel) {
    if (obj == nil || sel == NULL) return NO;
    if (![obj respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
}

NSInteger MFIntProp(id obj, SEL sel) {
    if (obj == nil || sel == NULL) return 0;
    if (![obj respondsToSelector:sel]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel);
}

NSArray *MFIterate(id collection) {
    if (collection == nil) return @[];
    if ([collection isKindOfClass:[NSArray class]]) return (NSArray *)collection;
    if ([collection isKindOfClass:[NSSet class]]) return [(NSSet *)collection allObjects];
    if ([collection isKindOfClass:[NSDictionary class]]) return [(NSDictionary *)collection allValues];
    if ([collection respondsToSelector:@selector(allObjects)]) {
        id all = MFMsg(collection, @selector(allObjects));
        if ([all isKindOfClass:[NSArray class]]) return (NSArray *)all;
    }
    if ([collection respondsToSelector:@selector(objectEnumerator)]) {
        NSMutableArray *out = [NSMutableArray array];
        NSEnumerator *e = [collection objectEnumerator];
        for (id o in e) {
            if (o != nil) [out addObject:o];
        }
        return out;
    }
    return @[];
}

id MFClassSharedInstance(NSString *name) {
    if (name == nil) return nil;
    const char *cname = name.UTF8String;
    if (cname == NULL) return nil;
    Class cls = objc_getClass(cname);
    if (cls == Nil) return nil;
    for (NSString *selName in @[@"sharedInstance", @"sharedInstanceIfExists"]) {
        SEL sel = NSSelectorFromString(selName);
        if (![cls respondsToSelector:sel]) continue;
        id inst = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
        if (inst != nil) return inst;
    }
    return nil;
}

BOOL MFClassHasInstanceMethod(NSString *className, NSString *selName) {
    if (className == nil || selName == nil) return NO;
    Class cls = objc_getClass(className.UTF8String);
    if (cls == Nil) return NO;
    return class_getInstanceMethod(cls, NSSelectorFromString(selName)) != NULL;
}
