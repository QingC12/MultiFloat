#import "POSceneSession.h"

// 【M1 / S1】纯状态容器：属性全部自动合成，无业务逻辑。
// 业务逻辑仍由 ContextHostManager 持有，本类只负责「让状态可以每窗一份」。
//
// 【M1 / S3】新增「窗口认领账本」（sessionBundleId + 认领集合）：
//   只做记账与自省，**不参与任何业务判定** ⇒ 单窗阶段行为零变化。
//   为什么用「集合」而不是「计数器」：窗口槽 key 天然去重（同一片重复布防不应翻倍计数），
//   集合语义让「重复认领 = 幂等」成为结构保证，而不是靠调用方小心。
@implementation POSceneSession {
    NSMutableSet<NSString *> *_mfWindowClaims;   // 已认领的窗口槽 key（幂等集合）
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mfWindowClaims = [NSMutableSet set];
        _sessionCreatedAt = [NSDate timeIntervalSinceReferenceDate];
    }
    return self;
}

- (NSUInteger)windowClaimCount {
    return _mfWindowClaims.count;
}

- (NSUInteger)mf_claimWindow:(NSString *)windowKey {
    if (windowKey.length && _mfWindowClaims) {
        [_mfWindowClaims addObject:[windowKey copy]];
    }
    return _mfWindowClaims.count;
}

- (NSUInteger)mf_releaseWindow:(NSString *)windowKey {
    if (windowKey.length && _mfWindowClaims) {
        [_mfWindowClaims removeObject:windowKey];
    }
    return _mfWindowClaims.count;
}

- (void)mf_releaseAllWindows {
    [_mfWindowClaims removeAllObjects];
}

- (NSArray<NSString *> *)mf_claimedWindowKeys {
    NSArray<NSString *> *keys = _mfWindowClaims.allObjects;
    if (keys.count == 0) {
        return @[];
    }
    return [keys sortedArrayUsingSelector:@selector(compare:)];
}
@end
