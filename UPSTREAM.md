# 来源与归属

本项目是面向 macOS 的非官方 HoDoKu 衍生项目。

1. [原版 HoDoKu](https://hodoku.sourceforge.net/en/index.php) 由 Bernhard Hobiger 创建，原版程序按 GNU GPL 第 3 版发布。原站网页材料另用 GNU FDL 1.3。
2. [PseudoFish/Hodoku 2.3.0](https://github.com/PseudoFish/Hodoku/releases/tag/2.3.0) 是后续 Java 维护版。其 [固定源码提交](https://github.com/PseudoFish/Hodoku/tree/49ccee8e47143bf453fb9ccf4b8fa4dc96efe0bf) 保留 Bernhard Hobiger 与 PseudoFish 的版权声明，并按 GPL 第 3 版或更新版本授权。
3. [HoDoKu macOS Java 版](https://github.com/LoveMu-498/hodoku-macos) 在这条 Java 版本线上增加中文界面、macOS 操作、批注与回放。其 [v2.3.4](https://github.com/LoveMu-498/hodoku-macos/releases/tag/v2.3.4) 可供查阅。原生迁移用另行冻结的 Java 实现进行行为对照。
4. HoDoKu macOS 原生版用 Swift 重建工作台，把解数、逻辑求解、评分与出题移植到 Rust，保留来源声明及相应行为。具体修改见 [CHANGES.md](CHANGES.md)。

继承代码保留 Bernhard Hobiger、PseudoFish 与既有贡献者归属。感谢 ddyer、ccv、Glenn Fowler、Robert Harder 和 Nathan Blomquist 对上游的贡献。Rust 的有界搜索保留了对 Glenn Fowler 求解实现的来源说明。原有 Java 组件的详细归属可在 [Java 版来源清单](https://github.com/LoveMu-498/hodoku-macos/blob/v2.3.4/UPSTREAM.md) 查阅。
