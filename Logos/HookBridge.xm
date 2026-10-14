//
//  HookBridge.xm — 唯一的进程入口
//
//  本版一个 hook 都不装。理由（诚实记录）：
//    a) 功能不需要 hook 就能做（自绘浮窗 + 借 SpringBoard 的宿主视图）；
//    b) 不装 hook 就不需要 substrate/ellekit 后端 —— 记忆里已确认
//       MSHookMessageEx 只能靠 dlsym(RTLD_DEFAULT) 拿，固定路径 dlopen 不可靠；
//       v0.4.0 的 hooks 段就是全项目唯一没被证明安全的段，干脆不用。
//  以后要加手势/按钮触发时，再按 dlsym(RTLD_DEFAULT) 的方式补，且必须加闸门。
//
#import "MFInternal.h"

%ctor {
    @autoreleasepool {
        MFLogRawC("=== MultiFloat 0.38.0 加载 ===\n");

        // 先把"上一轮崩在哪一步"读出来：这一步必须在任何 UI 之前，
        // 因为它要的结果会被浮窗的启动流程引用，而且它会把步骤日志轮转留档。
        NSString *crashedStep = MFStepRotateAndAnalyze();
        if (crashedStep.length > 0) {
            MFFloatSetBootCrashStep(crashedStep);
        }

        MFFloatBootstrap();
    }
}
