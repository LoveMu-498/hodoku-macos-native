# 安装 HoDoKu Native

1. 确认 Mac 使用 Apple Silicon。在对应 Release 核对实测系统、签名状态与 DMG 的 SHA-256。
2. 若已安装原生试用版，正常退出该应用，备份整个 `~/Library/Application Support/HoDoKu Native Candidate/` 数据文件夹。
3. 打开 DMG，将 `HoDoKu Native.app` 拖到“应用程序”，然后从“应用程序”中打开。普通使用无需安装其他工具，可以离线作答。
4. 首发预览经过本地签名，未经 Apple 公证。macOS 可能阻止直接打开。确认下载来源和校验值后，按 [Apple 的打开说明](https://support.apple.com/102445)处理当前应用的提示。

应用沿用原生试用版的数据目录。Java 版数据位于 `~/Library/Application Support/HoDoKu/`，两版可分别使用。原生版有独立进度时优先继续原生作答；只有旧 Java 会话时可按现有规则只读导入并另存原生进度。
