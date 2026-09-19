# Cuplivo v4.0.0 发布就绪移交单

> 状态：**发布就绪，移交人工执行**。本文件是给发布操作者的最后清单。决策记录：`website/docs/adr/0004`。

## 已完成（由会话执行）

| 门 | 结果 |
|---|---|
| `dart analyze --fatal-infos lib test` | 零问题 |
| `flutter test` 全量 | 5961 通过 / 18 败 = **精确基线**（auth 17 + root chmod 1，均为上游预存）——无新增失败 |
| 版本 | `pubspec.yaml` = `4.0.0+41` |
| 分支 | `cuplivo-v4` 已推送 `origin`（cuplivo/cuplivo.git，新建分支） |
| GHA dry-run | `build-stable-44.yml` workflow_dispatch（`publish_release=false` 语义：dry-run 不发布）已触发，run 35422679699 in_progress（历史成功先例 17m25s） |
| 文档 | ADR-0004、README×2 解冻、CHANGELOG 4.0.0、迁移指南、AGENTS 身份 |

## 人工发布步骤（操作者执行）

1. 确认 GHA run 35422679699 全绿（产物命名 `Cuplivo_<platform>_<version>_<abi/ext>`，应用 ID `com.cup11.cuplivo` 不变）。
2. 复核 `CHANGELOG.md` 与 `docs/v4-data-migration.md`（已接受损失：回收站/墓碑不迁移、LAN 同步历史重置）。
3. 打 tag（建议 `v4.0.0+41`）并推送。
4. 触发 `build-stable-44.yml`（可带 `publish_release=true`）或直接在 GitHub Releases 页新建 Release：标题 `Cuplivo v4.0.0 — Re-baseline release`，正文取 `CHANGELOG.md` 的 4.0.0 条目。
5. 公告渠道（QQ 群 1101061750 等）引用 README 顶部 v4 状态块。

## 手测清单（发布前抽查）

- [ ] 全新安装：首启正常建库（schema v6）。
- [ ] v3.x 旧安装覆盖升级：首启迁移完成、会话/消息/助手/世界书（含分组）齐全；迁移失败场景重启可重试。
- [ ] 消息回复、群聊、OCR/文档、Ta 的来信各冒烟一次。
- [ ] 增量备份→恢复闭环；LAN 同步两台设备配对成功（历史为空属预期）。
- [ ] 多 AI 对比：≥2 模型、assistant 消息菜单「启动对比」、卡片采纳/丢弃/重试、synthesize 模式。
- [ ] 桌面设置各 pane 渲染无异常（备份/代理）。
