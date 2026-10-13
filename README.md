# MultiFloat

iOS 越狱多浮窗 / 分屏插件（Phase 0 骨架）。

- 目标设备：**iPhone 15 Pro Max（A17，arm64e）**
- 目标系统：**iOS 17.3.1**
- 越狱环境：**roothide（工具 Relaxin）**
- 注入进程：SpringBoard
- 架构：Logos 薄层（进程入口 / 事件转发）+ Swift Core（业务逻辑）
- 构建：roothide/theos + GitHub Actions（本地无 macOS，CI 唯一编译途径）

## 打包约定（勿随意更改）

| 项 | 值 | 原因 |
|---|---|---|
| `ARCHS` | `arm64e` | 设备为 A17（arm64e），不再产出 arm64 切片 |
| `THEOS_PACKAGE_SCHEME` | `roothide` | 文件按 roothide 布局，deb 架构 `iphoneos-arm64e` |
| Theos 来源 | `roothide/theos` | 上游 theos 不支持 roothide scheme |
| 签名 | Procursus `ldid`（ad-hoc） | 占位签名（`.unsigned`）在 roothide 上会崩 SpringBoard |
| 日志位置 | `/var/mobile/` | Filza 直接可见，不受 roothide 路径重定向影响 |

## 目录结构

```
Makefile                      Theos 构建入口（arm64e / roothide）
control                       DEB 元数据（Architecture: iphoneos-arm64e）
MultiFloat.plist              Substrate/ElleKit 加载过滤（com.apple.springboard）
Bridge/                       Logos <-> Swift 桥接面（不暴露私有类型）
Logos/                        Logos 薄层
  SpringBoardHooks.xm         %ctor 入口（私有 Hook 全部 [VERIFY] 挂起）
  HookBridge.xm               注入存活日志（写入 /var/mobile/MultiFloat.log）
Resources/                    偏好默认值（com.example.multifloat，自有域）
Swift/                        Swift Core（窗口/场景/布局/状态机/偏好）
scripts/verify_deb.py         CI 强校验：架构 / roothide 布局 / ad-hoc 签名
.github/workflows/build-deb.yml  CI：push 自动编译 + 校验 + 上传 DEB
Probe/                        运行期探针（独立 Theos 工程，只读采样）
  Makefile  control  MultiFloatProbe.plist  Probe.xm
```

## 构建

推送到 `main` 即由 GitHub Actions 完成编译、校验与打包，DEB 作为 artifact 上传。

本地构建（需 macOS + roothide/theos + ldid）：

```sh
make package THEOS_PACKAGE_SCHEME=roothide
# 产物：packages/*.deb
python3 scripts/verify_deb.py packages/*.deb
```

## 证据纪律

所有私有 API 结论分三级标注，未验证代码不得进入构建：

- `[CONFIRMED]` — 有静态/动态证据支撑
- `[VERIFY]` — 待真机或反编译验证，当前以 TODO 挂起
- `[DISPROVEN]` — 已证伪

不写未验证的 `%hook` 签名、不使用样本地址、不猜测 ivar 布局。

## 运行期探针（MultiFloatProbe）

本地无 macOS/IDA 时，用设备自身的运行期真值补齐 `[VERIFY]` 项：

- 注入 SpringBoard 后延迟 12 秒采样，**不 Hook、不改对象状态**
- `%ctor` 先写纯 POSIX 心跳 `/var/mobile/MultiFloatProbe-heartbeat.log`，
  采样分 4 段且每段落盘 → 即使崩溃也能定位阶段、已产出数据不丢
- 输出到 `/var/mobile/`：
  - `MultiFloatProbe-summary.log` — 环境实况 + **13 个 selector 的真实定义类与 type encoding**
  - `MultiFloatProbe-methods.log` — 候选类方法/ivar 明细
  - `MultiFloatProbe-heartbeat.log` — 阶段面包屑

## 当前状态

Phase 0 收尾（骨架 + 设计文档），已按 roothide / arm64e 校正打包链路。
下一步：用探针取得的真值把 selector 从 `[VERIFY]` 升级为 `[CONFIRMED]`，
再实现 `MultiFloatSceneAdapter` 与第一个真实 Hook。
