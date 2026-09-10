# ADR-0063: Assistant Gradient Artwork Uses a Fixed Palette (助手渐变固定调色板)

Status: accepted

助手动态渐变背景（移植上游 Kelivo `44c84e0`）在 `lib/features/chat/widgets/chat_gradient_background.dart` 中以固定亮/暗两套色值绘制：线性底色 5 色 + 4 个径向色块，共约 18 个字面量。这直接触碰 AGENTS.md §1.5 的硬约束——新 UI 颜色必须使用主题 token（scheme 角色 / `AppSemanticColors` / 主题常量），刻意固定的颜色必须带 `color-gate: ignore` 标记。本 ADR 记录这个例外的边界与理由。

## Decision

- **渐变是艺术作品（artwork），不是主题色**：渐变背景的用途是替代图片壁纸作为聊天底纹，语义上等同于一张内置壁纸/插画。它的色板随 `Theme.of(context).brightness` 在亮/暗两套固定值之间切换，不读取 `ColorScheme`，不受 M3 Custom Theme、动态色（Android 12+）、或任何主题调色板影响。
- **所有权单点**：固定色值只允许存在于 `chat_gradient_background.dart` 的 `_GradientArtwork`；每个字面量必须带 `// color-gate: ignore` 标记（`tool/check_colors.py` 人工门禁可见）。
- **禁止外溢**：其它任何聊天背景/overlay/mask 颜色继续走主题 token（`cs.surface`、`cs.shadow`、`AppSemanticColors`）。本例外不适用于渐变周边的 UI（设置卡片、滑杆、预览边框等）。
- **测试锁色**：`chat_gradient_background_test.dart` 的像素断言锚定了亮色下底色 RGB 下限与 pinned 副本对齐，任何调色板改动都会显式失败，迫使改动回到本 ADR 复审。

## Compatibility (兼容性)

- 切换主题/Custom Theme/动态色时，渐变视觉**保持不变**（仅亮暗模式切换色板）。这是有意行为：渐变是对图片壁纸的替代，不是主题装饰。
- 用户升级或回退版本不影响该决定；无需数据迁移。

## Considered (rejected)

- **全部从主题 token 派生**（底色用 `surface`、色块用 `primary/secondary/tertiary`）：彻底符合 §1.5，且能跟主题变色。但会偏离上游移植的视觉身份，需要额外的调和算法（保证对比度、避免与气泡/文字冲突），并为纯装饰背景引入主题耦合；验收要求是「移植上游」而非「重新设计」。
- **种子色 + HSL 偏移生成**：看似两全，但把「固定作品」变成了运行时生成逻辑，调色结果难以测试与复现（YAGNI）。
- **每助手可调渐变色**：上游未提供，需求未要求；滑杆只调相位与偏移。若未来需要，应作为新的 ADR 评估（存储、UI、对比度约束都会翻倍）。
