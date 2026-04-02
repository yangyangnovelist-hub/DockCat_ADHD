# Upstream Inventory

本目录存放当前项目直接拉取到本地的上游仓库。它们不再只是“参考资料”，而是后续替换本地实现的正式来源。

## 当前已拉取

- `pet-therapy`
  - 本地路径：`ThirdParty/Upstreams/pet-therapy`
  - 仓库：`raman0c17/pet-therapy`
  - 许可证：`MIT`
  - 接入方式：本地 path package + 源码复用
  - 目标：`Pets`、`OnScreen` 桌宠引擎
  - 当前状态：桌宠启动已切到 `OnScreen` / `Pets`，并补了边缘出生点与纵向位置适配

- `whisper`
  - 本地路径：`ThirdParty/Upstreams/whisper`
  - 仓库：`openai/whisper`
  - 许可证：`MIT`
  - 接入方式：Python CLI / 本地子进程
  - 目标：语音转文本
  - 当前状态：`WhisperTranscriber` 已接入主工程，证书链环境已适配，`base` 模型样例转写通过

- `duckling`
  - 本地路径：`ThirdParty/Upstreams/duckling`
  - 仓库：`facebook/duckling`
  - 许可证：仓库元数据未声明 SPDX，源码内 LICENSE 为 `BSD`
  - 接入方式：HTTP 子进程 / 本地服务桥接
  - 目标：自然语言时间解析
  - 当前状态：`DucklingRuntime` 已接入主工程，本机首次 `stack build` / GHC provisioning 正在进行

## 已完成接入并清理原始上游的模块

以下上游源码已通过 Bridge 层完成抽取，原始仓库副本已删除（仅保留 Bridge 封装）：

- `BongoCat-mac` → `ThirdParty/Bridges/BongoCatInputBridge`
- `reminders-menubar` → `ThirdParty/Bridges/RemindersMenubarBridge`
- `vikunja` → `ThirdParty/Bridges/VikunjaQuickAddBridge`
- `AppFlowy` → `ThirdParty/Bridges/AppFlowyDocumentBridge`

## 约束

- 当前项目新增代码只能做装配、适配、桥接
- 若上游已有同类实现，不再写第二套本地版本
- 带 `GPL-3.0` / `AGPL-3.0` 的上游，在发布前必须明确许可证策略
