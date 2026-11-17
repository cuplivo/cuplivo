# 工具契约 + job 伪代码（修订 A）

## 1. 模型看到的面（英文描述）

```jsonc
{
  "name": "generate_image",
  "description": "Generate an image with another model to support your reply. The tool is non-blocking: you immediately get asset_id and uri, and you may place uri in your reply as a Markdown image placeholder. You will not see the finished image; never claim that you have seen it, and there is no need to say you cannot — just keep the reply flowing.",
  "parameters": {
    "type": "object",
    "properties": {
      "prompt": {
        "type": "string",
        "description": "Complete description of the picture: subject, setting, style, lighting. This is everything the image model sees."
      },
      "aspect_ratio": {
        "type": "string",
        "enum": ["auto", "1:1", "3:2", "2:3", "16:9"],
        "default": "auto",
        "description": "Only set it when the layout of the picture matters. auto lets the backend choose."
      },
      "reference_image_ids": {
        "type": "array",
        "items": { "type": "string" },
        "description": "Optional. Reference or keep editing an image already in this conversation. Ids outside this conversation are rejected."
      }
    },
    "required": ["prompt"]
  }
}
```

返回只有三个字段，**没有 `visible_to_you`**：

```
{ "status": "pending", "asset_id": "img_7f3a", "uri": "/data/assets/img_7f3a.png" }
```

- 不给图、不给 base64 —— 模型拿到的是承诺，可以立刻在正文里写 `![](uri)`。
- 不写"你看不到"，也不写"别看"：只在工具描述里说一次，正文保持连贯。

## 2. 三个悬而未决的点，这一版的答案

| 问题 | 答案 |
|---|---|
| 模型能不能看图？ | 能，但**只走已有的看图工具**（`view_image` / 工作区看图），和别的图一视同仁。不强制开启，也不特殊照顾。没开就看不到，也不需要声明。 |
| 拼下一个请求时，这个占位图要发回去吗？ | **不发。** `state != null` 的图片块在出站序列化时被跳过：没有字节的东西不能当图发给模型。完成后它就是一个普通 `ImagePart`，按既有规则参与后续请求。 |
| 比例有了，画质呢？ | **只给比例，不给画质。** 比例是构图决策，模型有理由决定；画质是成本决策，属于用户/计费，不由模型调。要统一也应该是"都不给"，而不是"都给"。 |

## 3. job 伪代码（异步）

```
adapter.generate(job) -> Future<Uint8List>        # 唯一异步边界；两个后端各自实现

create(idemKey, owner, prompt, refs, ratio):
    if job = jobs[idemKey]: return existing       # 幂等：重渲染不新建、不重复计费
    if refs not all in owner.conversation: raise BadRefs
    job = Job(kind: image, owner, prompt, refs, ratio,
              assetPath: allocateAsset(idemKey))  # 路径在 create 时定死，之后不改
    jobs[idemKey] = job
    writePart(ImagePart(uri: job.assetPath, assetId, jobId, state: pending))
    return {status: pending, asset_id, uri}

start(job):                                       # 不阻塞工具调用，由 job 自己跑完
    job.state = running
    try:
        bytes = await adapter.generate(job)       # 可能 30s，也可能 180s；见 §4
        if jobs[job.id].state != running: return  # 期间被取消/中断 → 丢弃这次结果，不覆盖终态
        writeFile(job.assetPath, bytes)
        job.state = completed
        updatePart(job.partId, uri: job.assetPath, state: null)   # 骨架换图
    catch e:
        job.state = failed(e.kind)                # timeout | provider_error | no_image
        updatePart(job.partId, state: failed)
    finally:
        jobs.remove(job.id)

cancel(job):
    if job.state.isActive:
        job.state = cancelled
        updatePart(job.partId, state: cancelled)  # start() 里那次 state 检查会丢弃迟到结果

onAppStart():
    for part in parts where part.state == pending:
        part.state = interrupted                  # 进程没了 → job 也没了
        updatePart(part)                          # 不自动续跑，用户点重试才新建
```

不变式：

1. `idemKey` 决定 job 身份；同一 key 永远同一个 job、同一个 assetPath。
2. 终态（completed / failed / cancelled / interrupted）一定写回 part —— 任何时候看到一张空图，都能从 part 解释原因。
3. `start()` 的 `state != running` 检查是**异步**的：超时或内部取消可能发生在 `await` 期间，结果必须丢。
4. 重启只做 `interrupted`，从不自动重跑。

## 4. 并发与超时

- **不加并发上限。** 上一版写"每会话 2 个"是拍脑袋：真正会乱花的是模型连环调用，而"莫名其妙被拒"更伤用户。工具描述里写一次"一次一张"就够。
- **超时给足**：默认 **300s**，并按 provider 的既有超时配置可覆盖。180s 的模型不该被 120s 掐死；超时只是兜底，兜的是"永远不返回"，不是"慢"。
- **界面不提供取消**（2026-11-17 收口）：和重试一样属于"和正在进行的请求较劲"，300s 兜底。`ImageJobManager.cancel` 保留在内部（有单测），只是没有入口。

## 5. 两个后端（同一个 adapter）

| | images/generations 形状 | Gemini chat-completions 形状 |
|---|---|---|
| 请求 | POST `/images/generations`，`prompt`、`size` | 普通 chat，消息带 `prompt` + 参考图 |
| 返回 | `b64_json` / `url` | 正文里的 markdown 图片链接（可能指图床） |
| 取字节 | base64 解码；url 再下载 | 取第一个 `![](url)` 再下载 |
| 参考图 | `/images/edits`（multipart） | 作为 image part 一起发 |
| 失败 | HTTP 错误 / 空 data | 回复里没有图片链接 = `no_image`，不能把正文当图 |

## 6. "part" 与既有基建的关系

- **part 就是现有的 `ImagePart`**：存在 `message_part_rows(kind='image', payload=JSON)` 里，渲染、导出、发给模型都走它。
- job 是内存里的活对象；它的状态**镜像**进 part 的 `jobId` / `state` 两个字段（已落地）。没有新表、没有新列，schema 仍 5。
- 于是三处一致：渲染器看 part 决定画骨架还是图；出站序列化看 `state` 决定发不发；重启看 part 决定标不标 `interrupted`。

## 7. 失败模式

| 情况 | 表现 |
|---|---|
| 未配置绘图模型 | 工具返回「未配置：设置 → 默认模型 → 绘图模型」，不建 job |
| 参考图越界 | 返回「只能引用本对话里的图」，不建 job |
| 后端超时（>300s） | 卡片「生成失败」+ 原因，没有按钮 |
| Gemini 回复里没有图 | `no_image`，同上 |
| 用户取消 | 界面无入口；内部取消写「已取消」，迟到结果丢弃 |
| 进程被杀 | 下次进对话：part=pending 且无 job → 「已中断」，没有按钮 |
