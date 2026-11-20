# 许可、组件与对应源码

| 组件 | 来源及许可 |
| --- | --- |
| HoDoKu 应用与求解引擎 | GPL-3.0-or-later。完整许可证见 [COPYING](COPYING)，作者和移植归属见 [UPSTREAM.md](UPSTREAM.md) 与源码声明。 |
| 静态链接的 Rust 标准库 | 官方 arm64 Rust 1.91.1。标准库许可、版权及例外以包内 `Rust-COPYRIGHT-library.html` 为准。[对应 Rust 源码标签](https://github.com/rust-lang/rust/tree/1.91.1) |
| Swift 并发兼容库 | 由 Apple Swift 工具链通过 `swift-stdlib-tool` 选入。Swift Apache 2.0 和 Runtime Library Exception 见包内 `Swift-LICENSE.txt`。[Swift 源码与许可](https://github.com/swiftlang/swift) |
| 系统字体、音效和系统框架 | 应用运行时使用 macOS 提供的组件。 |

每个原生 DMG 的对应源码、构建脚本及 SHA-256 见同一次 Release。构建依赖和运行依赖分开说明；Apple SDK、Xcode 与 Rust 编译器通过各自的官方渠道取得。合成回放测试数据的来源列于 [夹具目录](docs/replay-protocol/fixtures/README.md)。
