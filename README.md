# HoDoKu macOS 原生版

面向 Apple Silicon 的数独生成、解题与训练工具。支持按步阅读提示、用圈叉和自由链记录推理、回放一次解题过程，并从历史盘面继续作答。桌面应用使用 Swift、AppKit 和 SwiftUI，求解、评分和出题共用 Rust 引擎。

| 安装条件 | 首发预览 |
| --- | --- |
| 芯片 | Apple Silicon（arm64） |
| 构建部署目标 | macOS 11.0 |
| 首发实测 | 见该次 Release 的机型和系统记录 |
| 签名 | 本地签名（ad-hoc），未经 Apple 公证 |

从 [Releases](https://github.com/LoveMu-498/hodoku-macos-native/releases) 下载 Apple Silicon DMG，将 **HoDoKu Native** 拖入“应用程序”。应用自带必需运行库，可以离线运行，无需安装 Java、Rust、Homebrew 或 Xcode。安装前请先退出旧的原生试用版并备份其数据。使用同一原生数据目录可以续开已有进度。Java 版有自己的数据目录，原生版可按现有导入规则读取 Java 旧档。

[安装与数据说明](INSTALL.md)　[从源码构建](native/app/BUILD.md)　[变更记录](CHANGES.md)

本项目是 Bernhard Hobiger 的原版 HoDoKu 的非官方衍生项目，延续 PseudoFish 维护版及 HoDoKu macOS Java 版的作答与求解体验。原版、各阶段贡献者及组件归属见 [UPSTREAM.md](UPSTREAM.md)。应用按 GPL-3.0-or-later 发布，条款见 [COPYING](COPYING)，随包组件与对应源码见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
