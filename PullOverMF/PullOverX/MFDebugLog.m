//
//  MFDebugLog.m
//  PullOverMF —— 文件日志（本 fork 新增）
//
//  为什么需要它：上游 PullOver-X 全项目只有 1 处 NSLog，日志只进系统 syslog，
//  设备上（尤其 roothide + 无终端环境）根本拿不到，排查等于盲人摸象。
//  本 fork 提供 MFLog()：直接写文件，Filza 打开即看。
//
//  路径：/var/mobile/PullOverMF.log（与 MultiFloat 的日志同级，用户已知位置）
//  轮转：启动时若已超过 2MB → 重命名为 .old（最多保留一份历史）
//  写入：无缓冲（setvbuf _IONBF），崩溃前最后一条也在盘上
//
//  ⚠️ 0.1.3 重要修正：时间戳与文件打开**全部改为纯 C**（time/strftime/fopen）。
//  原因：0.1.2 的 constructor 里调用 MFLog，内部用 NSDateFormatter + [UIDevice...]，
//  而 dylib 的 constructor 在 SpringBoard 极早期执行，Foundation/UIKit 尚未完全就绪，
//  直接崩掉 → 整个 tweak 未加载 → **桌面连手柄都不显示**。
//  现在提供两条通道：
//    · MFLogRawC(const char *) —— 纯 C，零 Foundation 依赖，constructor 阶段唯一安全选择
//    · MFLog(NSString *, ...) —— 正常运行期使用（内部同样不碰 NSDateFormatter）
//

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <time.h>
#import <pthread.h>

#define MF_LOG_PATH       "/var/mobile/PullOverMF.log"
#define MF_LOG_MAX_BYTES  (2 * 1024 * 1024)

static pthread_mutex_t MFLogLock = PTHREAD_MUTEX_INITIALIZER;
static FILE *MFLogFile = NULL;

/// 纯 C 时间戳：MM-DD HH:MM:SS.mmm —— 不依赖 Foundation，constructor 阶段可用
static void MFLogStamp(char *buffer, size_t size) {
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        ts.tv_sec = time(NULL);
        ts.tv_nsec = 0;
    }
    struct tm parts;
    time_t seconds = ts.tv_sec;
    localtime_r(&seconds, &parts);
    strftime(buffer, size, "%m-%d %H:%M:%S", &parts);
    size_t used = strlen(buffer);
    if (used + 6 < size) {
        snprintf(buffer + used, size - used, ".%03ld", (long)(ts.tv_nsec / 1000000));
    }
}

/// 打开（并按需轮转）日志文件 —— 纯 C
static void MFLogEnsureOpen(void) {
    if (MFLogFile != NULL) {
        return;
    }
    FILE *probe = fopen(MF_LOG_PATH, "ab");
    if (probe != NULL) {
        long size = ftell(probe);
        fclose(probe);
        if (size > MF_LOG_MAX_BYTES) {
            remove(MF_LOG_PATH ".old");
            rename(MF_LOG_PATH, MF_LOG_PATH ".old");
        }
    }
    MFLogFile = fopen(MF_LOG_PATH, "a");
    if (MFLogFile != NULL) {
        setvbuf(MFLogFile, NULL, _IONBF, 0);
        char stamp[64];
        MFLogStamp(stamp, sizeof(stamp));
        fprintf(MFLogFile, "\n===== PullOverMF 日志会话开始 (%s) =====\n", stamp);
    }
}

/// 纯 C 日志（constructor / 极早期唯一安全入口）
void MFLogRawC(const char *message) {
    if (message == NULL) {
        return;
    }
    pthread_mutex_lock(&MFLogLock);
    MFLogEnsureOpen();
    if (MFLogFile != NULL) {
        char stamp[64];
        MFLogStamp(stamp, sizeof(stamp));
        fprintf(MFLogFile, "%s %s\n", stamp, message);
    }
    pthread_mutex_unlock(&MFLogLock);
}

/// 常规日志（正常运行时使用）。内部**不碰 NSDateFormatter**，且对 Foundation 调用加 @try
void MFLog(NSString *format, ...) {
    if (format == nil) {
        return;
    }

    char *utf8 = NULL;
    @try {
        va_list args;
        va_start(args, format);
        NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        const char *chars = [message UTF8String];
        if (chars != NULL) {
            size_t length = strlen(chars) + 1;
            utf8 = (char *)malloc(length);
            if (utf8 != NULL) {
                memcpy(utf8, chars, length);
            }
        }
    } @catch (NSException *exception) {
        utf8 = NULL;
    }

    if (utf8 == NULL) {
        return;
    }
    MFLogRawC(utf8);
    free(utf8);
}
