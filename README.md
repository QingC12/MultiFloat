# PullOverMF

个人用悬浮分屏插件（GPL-3.0，fork 自 mlgm66/PullOver-X），只注入 SpringBoard。

- 设备：iPhone 15 Pro Max（A17，arm64e）/ iOS 17.3.1 / roothide
- 构建：roothide/theos + GitHub Actions（本地无 macOS，CI 唯一编译途径）

## 打包约定（勿随意更改）

| 项 | 值 | 原因 |
|---|---|---|
| `ARCHS` | `arm64e` | 设备为 A17（arm64e），不再产出 arm64 切片 |
| `THEOS_PACKAGE_SCHEME` | `roothide` | 文件按 roothide 布局，deb 架构 `iphoneos-arm64e` |
| Theos 来源 | `roothide/theos` | 上游 theos 不支持 roothide scheme |
| 签名 | Procursus `ldid`（ad-hoc） | 占位签名（`.unsigned`）在 roothide 上会崩 SpringBoard |
| 日志位置 | `/var/mobile/PullOverMF.log` | Filza 直接可见，不受 roothide 路径重定向影响 |

## 目录结构

```
PullOverMF/                插件本体（Theos：Makefile / control / plist / PullOverX 源码）
scripts/                   CI 用校验脚本（setter_check.py / verify_deb.py）
.github/workflows/         build-pullovermf.yml（唯一构建流水线）
```

> 本仓库已移除 MultiFloat 早期工程（Bridge/Logos/Swift/Probe 等仅保留于 git 历史）。
