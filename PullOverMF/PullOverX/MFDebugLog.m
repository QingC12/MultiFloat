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

#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>
#import <pthread.h>

#define MF_LOG_PATH       "/var/mobile/PullOverMF.log"
#define MF_LOG_MAX_BYTES  (2 * 1024 * 1024)

static NSString *MFLogTimestamp(void) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:[NSDate date]];
}

/// 写一行日志到 /var/mobile/PullOverMF.log（线程安全、无缓冲）
void MFLog(NSString *format, ...) {
    if (format == nil) {
        return;
    }

    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&lock);

    static FILE *logFile = NULL;
    if (logFile == NULL) {
        @autoreleasepool {
            NSString *path = @MF_LOG_PATH;
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:NULL];
            if (attributes != nil && [attributes fileSize] > MF_LOG_MAX_BYTES) {
                NSString *rotated = [path stringByAppendingString:@".old"];
                [fileManager removeItemAtPath:rotated error:NULL];
                [fileManager moveItemAtPath:path toPath:rotated error:NULL];
            }
        }
        logFile = fopen(MF_LOG_PATH, "a+");
        if (logFile != NULL) {
            setvbuf(logFile, NULL, _IONBF, 0);
            fprintf(logFile, "\n===== PullOverMF 日志会话开始 =====\n");
        }
    }

    if (logFile != NULL) {
        @autoreleasepool {
            va_list args;
            va_start(args, format);
            NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
            va_end(args);
            const char *chars = [message UTF8String];
            if (chars != NULL) {
                fprintf(logFile, "%s %s\n", [MFLogTimestamp() UTF8String], chars);
            }
        }
    }

    pthread_mutex_unlock(&lock);
}
