# 群聊：别人的话怎么进模型（伪代码）

> 真机验收记录（`dirty:499df492251c773b`）：群里某个助手回复时，开头自发写了
> `[STEM Mentor v5]`。根因不在提示词，在注入方式。

## 1. 现在的注入（缺陷）

`GroupTranscript.forSpeaker` 把**所有**助手消息重建成 `role: 'assistant'`，正文前拼一行 `[名字]`：

```
role: assistant
content: "[STEM Mentor v5]\n今天先看论文。"
```

三个后果：

1. **身份错位**。对模型而言 assistant 序列就是“我说过的话”。别人的回复成了我的台词，
   反过来也一样；“你刚才说过……”“这不是你写的”这类指令全部指向错误的人。
2. **格式传染**。assistant 轮统一以 `[名字]` 开头，模型把这一行当成轮次格式，
   于是自己的回复也以 `[STEM Mentor v5]` 开头。
3. **评审 / 拒答失效**。需要“这不是我的话”的判断（审稿、反驳、承认错误）
   全部建立在错误的归属上。

## 2. 改后的不变量

- **I1** 只有 speaker 本人的发言是 `assistant`。
- **I2** 其余发言（用户、其他成员）一律 `user`，且每条非本人发言带**分界**。
- **I3** 下游“最后一条用户消息”仍然指**用户本人**最近一次发言
  （图片挂载、搜索关键词、视频附加都挂在这里）。
- **I4** 别人的 thinking、工具卡、图片、版本选择不重放（`publicText` 已剥离，保持）。
- **I5** 导演用的 `forDirector`、标题用的 `titleLine`、UI、存档格式全不变；
  `senderId` 仍是作者的唯一真相。

## 3. 角色表

| 作者 | 角色 | 内容 |
| --- | --- | --- |
| speaker 自己 | `assistant` | 原文（剥掉 thinking），无名字行 |
| 用户 | `user` | 原样，无包裹 |
| 其他成员 | `user` | `<group_message from="名字">` … `</group_message>` |

用户消息保持原样是刻意的：附件、图片 part、修订都在它身上，包一层会让下游的
附件路由失去锚点。区别靠“有没有包裹”表达，而不是再加一个角色。

## 4. 伪代码

```dart
// group_transcript.dart
static String _envelope(String name, String text) =>
    '<group_message from="$name">\n$text\n</group_message>';

static List<ChatMessage> forSpeaker(
  List<ChatMessage> messages, {
  required String speakerId,
  required Assistant? Function(String? senderId) resolve,
}) => [
  for (final m in messages)
    switch (m.role) {
      // 我自己的话：原样留在 assistant，不加名字
      'assistant' when m.senderId == speakerId =>
        _rebuild(m, role: 'assistant', content: publicText(m)),
      // 别人的话：翻转成 user，套信封
      'assistant' => _rebuild(
          m,
          role: 'user',
          content: _envelope(speakerName(m.senderId, resolve), publicText(m)),
        ),
      // 用户消息原样
      _ => m,
    },
];

// 只换 role/content，保留 id/timestamp/conversationId/modelId/providerId/
// groupId/version/senderId，丢掉 parts：跨 provider 的 tool_call_id 与图片都不合法。
static ChatMessage _rebuild(
  ChatMessage m, {
  required String role,
  required String content,
}) => ChatMessage(
  id: m.id,
  role: role,
  content: content,
  timestamp: m.timestamp,
  conversationId: m.conversationId,
  modelId: m.modelId,
  providerId: m.providerId,
  groupId: m.groupId,
  version: m.version,
  isStreaming: false,
  senderId: m.senderId,
);
```

进程内标记，让下游分得出“谁说的”：

```dart
// message_builder_service.buildApiMessages —— ChatMessage → map 的唯一位置
final message = <String, dynamic>{
  'role': role,
  'content': content,
  if (source.senderId != null) 'senderId': source.senderId,
};
```

“最后一条用户发言”收敛成一个函数，四个 provider 都改用它：

```dart
/// 最后一条“人”说的话：跳过带 senderId 的群成员消息。
/// 群聊里别人的话在角色上是 user，语义上不是用户。
int lastHumanUserIndex(List<Map<String, dynamic>> messages) {
  for (var i = messages.length - 1; i >= 0; i--) {
    if (messages[i]['role'] == 'user' && messages[i]['senderId'] == null) {
      return i;
    }
  }
  return -1;
}
```

## 5. 谁在读“最后一条 user”（影响面）

| 位置 | 现在 | 改后 |
| --- | --- | --- |
| `openai/chat_completions_api.dart:283` `lastUserIndex` | 最后一个 `role == 'user'` | `lastHumanUserIndex` |
| `openai/openai_request_shaping.dart:36` `_lastUserText` | 同上，取内置搜索关键词 | 同上 |
| `claude/claude_history.dart:585` `isLast && role == 'user'` | 用户图片挂载 | 同上 |
| `google_common.dart:443 / 920` | 用户图片挂载 | 同上 |
| `google_common.dart:523 / 1006` | YouTube 视频附加 | 同上 |
| `message_builder_service.processUserMessagesForApi` | `lastUserImagePaths` | 跟随同一个 index |

不改这一处的后果是可复现的：群里用户发一张图，A 说一句，B 回一句——
最后一条 user 是 B 的话，用户的图挂到 B 的消息上，模型看不到图。

覆盖层（instructions、world book、memory 注入）读的是 `ChatMessage` 与
conversation，不读 apiMessages 的角色序列，因此不受影响。

## 6. 提示词随之改（`rosterDirective`）

现在的第三句“每条成员回复以方括号名字开头”必须删掉，换成：

```
You are "X", one member of the group chat "Y".
Messages from other members reach you as user turns wrapped in
<group_message from="Name">…</group_message>. A user turn without that
wrapper was written by the user.
Write your own reply only: no wrapper, no name prefix, no dialogue for others.
```

`Already replied in this round: …` 那句保留。

## 7. 失败模式

| 症状 | 根因 | 防线 |
| --- | --- | --- |
| 用户发的图模型看不到 | 图片挂在“最后一条 user”，而它是别人的话 | I3 + `lastHumanUserIndex` |
| 内置搜索词取自别人的话 | 同上 | 同上 |
| 回复仍以 `[名字]` 开头 | 分界被当成可续格式 | 信封 + 提示词明说不加前缀 |
| 一轮里连续多条 `user` 被拒 | 用户 + 两个成员连排 | Anthropic / OpenAI 接受连续同角色；Gemini 逐条 `user`（按一轮 smoke 测） |
| 别人的 tool_call 串进请求 | 跨 provider 复用 id | parts 被丢弃（现状） |
| 归档后重启，历史归属变了 | 角色是读时决定的，不写库 | 无需迁移（I5） |

## 8. 测试

- `forSpeaker` 三角色逐格断言：自己的话 → `assistant` 且无信封；别人的话 →
  `user` 且带 `from="名字"`；用户的话 → 原样。
- 信封不出现在 speaker 自己的轮里。
- `lastHumanUserIndex`：本人 + 两条别人的话 → 仍指回本人；没有本人发言 → `-1`。
- 图片路由：本人带图、别人插话后，图片仍挂本人那条（适配器层）。
- 请求体里没有 `senderId`（序列化断言，标记只活在进程内）。
- 导演 / 标题输出与改动前逐字节一致。

## 9. 备选（不推荐）

分界改用 `[名字]` 首行（沿用现有格式、省 token、改动最小）：与“格式传染”只差一步，
模型更容易把自己的回复接着写成 `[名字]` 开头。

## 10. 落地记录

按这份伪代码实现，跑偏了三处（都是落地时才看见的细节）：

1. **标记换名**：map 里用 `_groupPeerSender` 而不是 `senderId`。openai chat completions 的
   `outMsg` 会整表复制后再删内部键，多一个普通键名就多一次泄漏机会；带下划线前缀后它和
   `_kelivo_media_paths` 是同一类东西，剥离点也放在同一批 `outMsg.remove(...)` 里。
2. **群成员的 user 轮不发 revision id**。一份 `internalRevisionIdKey` 会被
   `processUserMessagesForApi` 认成"用户真的说了这句"，从而对它跑附件解析、user 作用域的
   regex、以及 `lastUserIdx`。群成员的话这三件都不该发生，所以 `buildApiMessages` 在
   `senderId != null` 时只写标记，不写 revision id —— 顺带让"最后一条用户消息"在
   生成前就已经指向本人。
3. **调用点比文档多一个**：`openai_provider` 的 Responses 路径自己算了一次
   `lastResponsesUserIndex`，文档表里漏了它，一并换掉。

测试：`group_transcript_test` 按三角色逐格断言；新增 `message_authorship_test`（5 条）；
`message_builder_service_test` 加"群成员 turn 带标记且不占 revision id"；
`chat_completions_skip_image_parsing_test` 加"标记不进请求体"（断言的正是第 1 条的泄漏面）。

