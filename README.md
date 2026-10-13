# MultiFloat

iOS 越狱多浮窗 / 分屏插件（Phase 0 骨架）。

- 目标平台：iOS 17.3.1，arm64 / arm64e，rootless（var/jb）
- 注入进程：SpringBoard
- 架构：Logos 薄层（进程入口 / 事件转发）+ Swift Core（业务逻辑）
- 构建：Theos（本仓库 CI 自动产出 DEB）

## 目录结构

```
Makefile                      Theos tweak 构建入口（Phase 0 骨架）
control                       DEB 打包元数据
MultiFloat.plist              Substrate/ElleKit 加载过滤（com.apple.springboard）
Bridge/                       Logos <-> Swift 桥接面（不暴露私有类型）
  MFBridge.h
  MultiFloat-Bridging-Header.h
Logos/                        Logos 薄层
  SpringBoardHooks.xm         %ctor 入口（私有 Hook 全部 [VERIFY] 挂起）
  HookBridge.xm               桥接桩实现
Resources/
  com.example.multifloat.plist 偏好默认值（项目自有域，不复用 Stheno/TrollOpen）
Swift/                        Swift Core
  MultiFloatCore.swift        事件入口与依赖装配
  WindowManager.swift         浮窗生命周期操作
  FloatingWindow.swift        浮窗模型
  SceneManager.swift          Scene 事务适配层（协议隔离私有 API）
  LayoutEngine.swift          几何布局
  GestureController.swift     手势归一化
  StateMachine.swift          窗口状态机
  AppRegistry.swift           应用准入
  Preferences.swift           偏好（com.example.multifloat）
.github/workflows/build-deb.yml  CI：push 自动编译并上传 DEB
```

## 构建

无需 macOS：推送即由 GitHub Actions（macOS runner）安装 Theos + iOS SDK
后执行 `make package`，DEB 作为 artifact 上传。

本地构建（需要 macOS + Theos）：

```sh
make package
# 产物：packages/*.deb
```

## 证据纪律

所有私有 API 结论分三级标注，未验证代码不得进入构建：

- `[CONFIRMED]` — 有静态/动态证据支撑
- `[VERIFY]` — 待真机或反编译验证，当前以 TODO 挂起
- `[DISPROVEN]` — 已证伪

不写未验证的 `%hook` 签名、不使用样本地址、不猜测 ivar 布局。

## 当前状态

Phase 0 收尾（工程骨架 + 设计文档）。Phase 1 环境验证：
本仓库 CI 首次构建即为验证环境，重点确认 Theos Swift 工具链集成
（Bridging Header / module-name）与 Hook 后端二选一（substrate / ellekit）。
