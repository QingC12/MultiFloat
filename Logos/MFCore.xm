//
//  MFCore.xm — 日志 / 配置 / 崩溃自解除闸门 / 安全消息发送
//
//  本文件不做任何 UI、不装任何 hook，只提供可被安全调用的基础设施。
//  所有函数在参数异常时必须"返回而不是崩"，因为调用方在 SpringBoard 主进程里。
//
#import "MFInternal.h"

#pragma mark - ---------- 版本 ----------

NSString *MFVersionString(void) {
    return @"0.3.0";
}

#pragma mark - ---------- 日志 ----------

static void MFWriteBothPaths(const char *utf8) {
    if (utf8 == NULL) return;
    // /var/mobile/Media/... 在"文件"App 与 Filza 里都好找；/var/mobile 是用户既定目录
    mkdir("/var/mobile/Media/MultiFloat", 0755);
    static const char *paths[2] = {
        "/var/mobile/MultiFloat.log",
        "/var/mobile/Media/MultiFloat/MultiFloat.log",
    };
    size_t len = strlen(utf8);
    for (int i = 0; i < 2; i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) continue;
        ssize_t written = write(fd, utf8, len);
        (void)written;
        close(fd);
    }
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

void MFWriteDefaultConfigIfNeeded(void) {
    NSString *path = @"/var/mobile/MultiFloat.plist";
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    NSDictionary *def = @{
        @"enabled"        : @NO,
        @"mode"           : @"host",                  // host = 真承载；shell = 只有外壳
        @"targetBundleID" : @"com.apple.mobilesafari",
        @"showDelay"      : @12,
        @"windowLevel"    : @1010,
    };
    BOOL ok = [def writeToFile:path atomically:YES];
    MFLog(@"[cfg] 写出默认配置 %@ ok=%d（enabled=false，纯惰性）", path, (int)ok);
}

#pragma mark - ---------- 崩溃自解除闸门 ----------

static const char *const kMFAttemptPath = "/var/mobile/MF-float-attempt.txt";

BOOL MFAttemptExists(void) {
    return access(kMFAttemptPath, F_OK) == 0;
}

void MFAttemptWrite(const char *mode) {
    int fd = open(kMFAttemptPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        MFLogRawC("[gate] !! 无法写出 attempt 标记（本轮没有崩溃保护）\n");
        return;
    }
    char buf[160];
    const char *m = (mode != NULL) ? mode : "?";
    int n = snprintf(buf, sizeof(buf), "mode=%s t=%ld pid=%d\n", m, (long)time(NULL), (int)getpid());
    if (n > 0) {
        ssize_t written = write(fd, buf, (size_t)n);
        (void)written;
    }
    close(fd);
    MFLogRawC("[gate] attempt 标记已写：若下次启动仍存在 => 上一轮崩了 => 本轮自动跳过\n");
}

void MFAttemptClear(void) {
    unlink(kMFAttemptPath);
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
