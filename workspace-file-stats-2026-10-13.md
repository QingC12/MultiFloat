# 工作区文件统计报告

- 统计时间：2026-10-13 14:04 (GMT+8)
- 统计范围：`C:/Users/Administrator/WorkBuddy AI/iOS插件`（含隐藏目录）

## 1. 总览

| 指标 | 数值 |
|---|---|
| 文件总数 | **197** 个 |
| 顶层目录数 | 4 个（analysis / MultiFloat / work / .workbuddy-ai） |
| 总磁盘占用 | 约 63 MB（按文件字节合计约 65 MB） |
| 文本总行数 | 153,932 行（其中扫描 JSON 数据占 133,174 行，净文档/代码约 2.1 万行） |
| 二进制文件 | 14 个（10 个 dylib + 4 个可执行） |
| 最近批量修改 | 2026-10-13 09:25（31 个文件同一时间戳） |

## 2. 目录构成

| 目录 | 文件数 | 占用 | 内容性质 |
|---|---|---|---|
| `analysis/` | 84 | 60.9 MB | 逆向分析：30 篇设计/报告文档 + 3 个扫描脚本 + 51 个拆包样本文件 |
| `.workbuddy-ai/` | 90 | 1.1 MB | 工具资产：reverse-skill 技能包 88 个文件 + 2 篇工作记忆日志 |
| `MultiFloat/` | 17 | 17.5 KB | 插件本体源码（Theos 工程骨架） |
| `work/` | 5 | 11.3 KB | 任务管理文档（ios-multifloating-split 4 篇 + master-route 1 篇） |
| 根目录 | 1 | — | `exec-approvals.json`（权限审批配置） |

## 3. 文件类型分布

| 扩展名 | 数量 | 说明 |
|---|---|---|
| `.md` | 68 | 分析文档 23 + 技能文档 38 + 任务文档 5 + 记忆日志 2 |
| `.ps1` | 33 | reverse-skill 的 PowerShell 脚本（安装/测试/工具链） |
| `.plist` | 26 | 插件配置、偏好设置、本地化资源 |
| `.dylib` | 10 | 逆向样本动态库（Stheno 6 + TrollOpen 4） |
| `.swift` | 9 | MultiFloat 核心源码 |
| `.sh` | 9 | reverse-skill 的 Shell 脚本 |
| `.py` | 7 | Mach-O 扫描脚本（analysis/tools 3 + 技能 4） |
| `.png` | 7 | 偏好设置面板图标 |
| `.strings` | 6 | 本地化字符串（en / zh-Hans） |
| `.json` | 6 | Hook 扫描数据（2 个大文件）+ 路由/索引配置 |
| `.txt` | 5 | 逆向分析报告 |
| `.xm` | 3 | Logos Hook 源码（2）+ Hook 模板（1） |
| `.h` | 2 | Objective-C 桥接头文件 |
| 无扩展名 | 6 | control、Makefile、2 个 libexec 可执行、2 个 PreferenceBundle 可执行 |

## 4. 体积 Top 10

| 排名 | 文件 | 大小 |
|---|---|---|
| 1 | `TrollOpenJB.dylib` | 52.7 MB（占全工作区 81%） |
| 2 | `TrollOpenJBPrefs`（偏好面板可执行） | 3.1 MB |
| 3 | `analysis/hook-scan.json` | 3.1 MB（116,206 行） |
| 4 | `Stheno.dylib` | 2.2 MB |
| 5 | `analysis/hook-targets.json` | 445 KB（16,968 行） |
| 6 | `SthenoPreference`（偏好面板可执行） | 268 KB |
| 7 | `SthenoIdentityHandoffRelease.dylib` | 203 KB |
| 8 | `SthenoFix.dylib` | 171 KB |
| 9 | `SthenoKeyboard.dylib` | 171 KB |
| 10 | `TrollOpenKeyboard.dylib` | 170 KB |

## 5. 代码与文档明细

**MultiFloat 插件源码（433 行）**

| 文件 | 行数 | 职责 |
|---|---|---|
| `MultiFloatCore.swift` | 100 | 核心门面 |
| `WindowManager.swift` | 63 | 窗口管理 |
| `SceneManager.swift` | 53 | 场景管理 |
| `FloatingWindow.swift` | 37 | 悬浮窗 |
| `LayoutEngine.swift` | 36 | 布局引擎 |
| `GestureController.swift` | 32 | 手势控制 |
| `SpringBoardHooks.xm` | 24 | SpringBoard Hook |
| `StateMachine.swift` / `AppRegistry.swift` | 各 21 | 状态机 / 应用注册 |
| `Preferences.swift` | 18 | 偏好读取 |
| `HookBridge.xm` | 15 | Logos-Swift 桥接 |
| `MFBridge.h` / 桥接头文件 | 9 / 4 | 头文件 |

**分析文档（analysis/ 根目录 30 个，约 3,540 净行）**：23 篇设计文档（分屏架构、悬浮窗状态机、手势系统、场景生命周期、Logos Hook 设计、Theos 工程布局、TrollOpen Hook 映射等）+ 4 篇分析报告（hook-chain / multi-floating-split-chain / skill-audit / static-analysis）+ 2 个 Hook 扫描 JSON + 1 个 Hook 模板。

**工具资产（.workbuddy-ai/skills/reverse-skill/，88 个文件）**：reverse-engineering（26）、ida-reverse（10）、mobile-reverse（3）、scripts（38，含 33 个 ps1 + 4 个 sh + 1 个 py）、路由与索引配置。

**任务文档（work/，5 篇）**：ios-multifloating-split 的 README / scope / timeline / workitems + master-route 的 route-scope。

## 6. 观察与建议

1. **体积高度集中**：`TrollOpenJB.dylib` 单文件 52.7 MB，占工作区 81%；`analysis/deb_packages/`（58 MB / 51 文件）占 89%。这些是静态拆包样本，若不参与日常构建，建议移出工作区单独归档，或纳入 `.gitignore` / Git LFS。
2. **数据文件体量大**：`hook-scan.json`（3.1 MB / 11.6 万行）与 `hook-targets.json`（445 KB / 1.7 万行）是机器生成数据，建议改为按需生成而非入库。
3. **时间戳分层清晰**：源码与文档集中在 2026-10-13 09:25 批量更新；deb_packages 内文件多为归档时间戳（1970 epoch / 2026-01-28），说明样本为外部拷入，未参与迭代。
4. **无本地 Git 元数据**：工作区内未发现 `.git` 目录，与"CI 推送构建"的工作方式一致；本地仅保留源码与文档，产物 deb 不落盘。
5. **MultiFloat 工程结构完整**：Swift 源码 9 个 + Logos Hook 2 个 + 桥接头 2 个 + Makefile/control/plist 齐备，433 行代码与 23 篇设计文档的比例约为 1:19，文档驱动特征明显。
