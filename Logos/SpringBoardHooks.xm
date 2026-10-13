//
//  SpringBoardHooks.xm — 已停用（0.3.0 起不在 Makefile 的编译列表里）
//
//  原因：本版不装任何 hook（自绘浮窗 + 借 SpringBoard 宿主视图即可满足功能），
//        而 hook 后端必须靠 dlsym(RTLD_DEFAULT) 解析，是唯一没被真机验证过的环节。
//  保留文件是为了不丢历史上下文；重新启用时必须：
//    1) 把 BackendResolved 通过 dlsym(RTLD_DEFAULT, "MSHookMessageEx") 拿到；
//    2) 每个 hook 前先过 /var/mobile/MF-hooks-gate.txt 闸门；
//    3) hook 体里不改行为，先只落日志跑一轮。
//
//  已从探针中确认为真实存在、将来可能用到的入口（签名见 analysis/blueprint-v3-2026-10-13.md）：
//    SBMainWorkspace   -_handleOpenApplicationRequest:options:activationSettings:origin:withResult:  v56@0:8@16@24@32@40@?48
//    SBSceneManagerCoordinator -_createSceneForApplication:withOptions:completion:                   v40@0:8@16@24@?32
//    SBSceneManager    -fetchOrCreateApplicationSceneHandleForRequest:                                @24@0:8@16
//
//  openInSplit: / sceneHandle:reuseExistingScene: / minimize / fullscreen / closeCurrentFloatingWindow
//  经全类扫描确认【无任何类定义】—— 系统没有现成分屏接口，必须自己写。
//
