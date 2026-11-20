# M2 正式构建合成样例

此目录仅包含已公开的纯合成测试资料，不含真实用户回放。`.hrep.b64` 是原文件的 Base64 表示，解码字节保持不变；正式验证器按 `manifest.json` 的字节数及 SHA-256 校验后，解码到隔离验证目录。`expected.json` 保留固定候选的原始预期结果。

- 18 项格式样例来自 [固定 M2 候选](https://github.com/LoveMu-498/hodoku-macos/tree/9b6ec58c47024cfaf8a96dbaa678fc6ba2448ae1/docs/replay-protocol/candidates/HRPL-FRAMEWORK-20261013-M2/fixtures)，原由 Windows W1 写出，M2 保留其字节。
- `windows-o11-return.hrep` 来自 [Windows O11 合成回执](https://github.com/LoveMu-498/hodoku-macos/pull/2#issuecomment-6137647805)，703 字节。
- `windows-m2-export.hrep` 来自 [Windows M2 应用回执](https://github.com/LoveMu-498/hodoku-macos/pull/2#issuecomment-6144641151)，32498 字节，包含旧数据部分观看和完整预览回退两种情况。

这些固定样例用于格式、实际应用读取/保存、绘制与隔离续解的回归验证。包含预计拒绝的坏数据，不可将全部文件可打开作为通过条件。本目录不是新协议版本，也不改变双方已确认的候选文件。
