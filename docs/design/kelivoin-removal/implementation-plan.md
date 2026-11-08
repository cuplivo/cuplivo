# KelivoIN 移除 + 修复迁移 + 备份文件命名（执行计划）

> 状态：**已落地（自动化门禁全绿，2026-11-08）**。§8 的手工验收尚未执行，落地记录见 §10。
> 分支：`fix/provider-kelivo-in`，基线 `fe8cafd2f`（master）。
> 关联：issue #1073、ADR-0001（fork 边界）、ADR-0018（本次决定）、ADR-0017（反向往回导入）、`docs/rebase-runbook.md` 规则 18。

## 0. 为什么做这件事（现状，已查证）

`KelivoIN` 是 upstream 的内建免费供应商。3.x 按设计删除了它（`857cf6a99`，#286），ADR-0001 至今写着
「no longer seeded or special-cased」。但 4.x 每次重基都把它带回来，而且带回来时只修了一半：

| 提交 | 事实 |
| --- | --- |
| `b1702b3a9`（4.4 基线） | upstream 重新 seed 该 provider；`docs/rebase-runbook.md:716` 把「补上 provider 列表」当常规基线修复，fork 边界就此丢失 |
| `87f613717`（4.3 重基，身份单元） | 提交信息写「seeding、defaults、prefill、migration、token 全部移除」，**树里只删了 token**；`settings_provider.dart:1473` 仍在 seed，并把 upstream 的 `api.psycheas.top` 扫成 `api.cuplivoas.top` |
| `c04deb38a`（v4.5.0 发布） | 三处 key 判定被扫成 `'cuplivoin'`，匹配不上 `KelivoIN`：落地形态是一个 disabled、base `api.openai.com`、零模型的空壳（字段可编辑） |
| `79696e6f6`（11-02，仅新线） | 把三处判定改回 `'kelivoin'` —— upstream 整套行为**重新激活**，死域名没跟着改回来 |

实测（临时探针，已删）：

```
DEFAULTS enabled=true base=https://api.cuplivoas.top/v1 apiKey="" models=[Qwen/Qwen3-8B, Qwen/Qwen3.5-4B, THUDM/GLM-4-9B-0414, auto]
SEEDED   enabled=true base=https://api.cuplivoas.top/v1 apiKey="" models=[同上]
```

- `cuplivoas.top` / `api.cuplivoas.top`：OS resolver 与 `1.1.1.1` 均无记录（NXDOMAIN）；`api.psycheas.top` 正常解析。
- upstream 的免密钥 token 已随 `87f613717` 删除：`api_key_manager.dart` 无 `_kelivoPayload`，
  `effectiveKeyForProvider` 只剩多 key 选择 + 用户自己的 key。`apiKey` 为 `''` → 请求发 `Bearer `（空）。

结论：master 上每个可达状态都坏，且 UI 不给退路（`provider_detail_page.dart` 对 `kelivoin` 锁住
name / apiKey / baseUrl / chatPath 并隐藏类型行，`providers_page.dart:509` 把它列为固定行，
`isUserAdded` 为 false 所以连删除都做不到）。

## 1. 目标与不变量

1. **本 fork 不再自带别人的免费服务与别人的凭证。** 内建行、seeding、默认值、预填模型、启动迁移、
   UI 特例全部删除，且**不允许再被下一次重基悄悄带回来**（§5 的常设闸门）。
2. **不留下任何「用户修不了」的状态。** 本 fork 自己写死的两个死域名配置在启动时清除，
   并同时清掉助手/会话里指向它的模型引用；真·Kelivo 配置保留为普通供应商。
3. **备份文件名跟着目标读者走**（ADR-0017 的「备份是对读者的一句声明」），读侧接受两套前缀。

## 2. 任务 A：删除内建 KelivoIN

### A.1 `lib/core/providers/settings_provider.dart`

| 行 | 现状 | 改法 |
| --- | --- | --- |
| 97 | `_builtInProviderKeysInOrder` 里的 `'KelivoIN',` | 删除该行 |
| 1567 | `ensureProviderConfig('KelivoIN', defaultName: 'KelivoIN');` | 删除 |
| 1577-1594 | pollinations 退役迁移块 | 整块替换为任务 B 的修复迁移 |
| 6883 | `if (k.contains('kelivoin')) return 'https://api.cuplivoas.top/v1';` | 删除 |
| 6925 | `if (s.contains('kelivoin')) return true;` | 删除 |
| 6985-7040 | openai 分支里的 KelivoIN 特例（4 个预填模型 + `modelOverrides`） | 整块删除 |

保留 `onProviderModelsRetired` 构造参数与 `main.dart:958` 的接线（任务 B 用它清引用）。

### A.2 `lib/features/provider/pages/provider_detail_page.dart`

| 行 | 改法 |
| --- | --- |
| 153 | 从固定 key 集里删 `'KelivoIN',`（→ `isUserAdded` 变 true：出现删除按钮，base URL 的 `restoreDefault` 关闭） |
| 844 | 删 `if (widget.keyName.toLowerCase() != 'kelivoin')` 条件，`_providerKindRow` 恢复显示 |
| 1100 | name 输入行 `enabled:` 去掉 kelivoin 条件 |
| 1105 | API key 行的 `if (... != 'kelivoin' && !_multiKeyEnabled)` 只留 `!_multiKeyEnabled` |
| 1138 | `ProviderBaseUrlField` 的 `enabled:` 去掉条件 |
| 1143 | apiPath 行的 `if (_kind == openai && ... != 'kelivoin' && !_useResp)` 只留 `!_useResp` |

### A.3 `lib/desktop/setting/providers_pane.dart`

| 行 | 改法 |
| --- | --- |
| 1646 | `enabled: widget.providerKey.toLowerCase() != 'kelivoin'` → 去掉条件 |
| 1919 | apiPath 的禁用集 `['openai','tensdaq','kelivoin']` 去掉 `'kelivoin'`（`openai`/`tensdaq` 是另一回事，不动） |

### A.4 `lib/features/provider/pages/providers_page.dart`

- 509：删除固定行 `_p('KelivoIN', 'KelivoIN', enabled: true, models: 0),`。

### A.5 保留：provider 头像

`lib/utils/brand_assets.dart:61`（`RegExp(r'kelivo')` → `kelivo.png`）与 `:258` 的资产引用**保留**，
`assets/icons/kelivo.png` 也保留：持久化的 `KelivoIN` 之后是一个普通供应商，仍拿这张头像；
ADR-0001（L79-80）本来就是这么写的。

### A.6 关掉 blast radius

| 被改的规则 | 所有调用点 | 变成什么 |
| --- | --- | --- |
| `_builtInProviderKeysInOrder` / `isBuiltInProvider` | `provider_detail_page`（删除按钮、`restoreDefault`）、`providers_pane`、`_cleanupProviderOrderAndGrouping:2399` | 持久化的 `KelivoIN` 归入动态尾部：**首次升级后它会在列表里移到末尾一次**，这是预期，写进 PR body |
| `ProviderConfig.defaultsFor('KelivoIN')` | 新建供应商、reset、两个测试 | 变成一个普通 openai 配置（base `api.openai.com`、models 空、enabled false）。B.3 的测试钉住「它不再是那个预填配置」 |
| `defaultEnabled` / `_defaultBase` | `defaultsFor` 内部 | 不再识别该 key，行为与任意自建 provider 相同 |

## 3. 任务 B：只清本 fork 自己写出来的坏配置

启动时（`_load`，原 1577 块的位置，seed 之后、`_cleanupProviderOrderAndGrouping()` 之前）执行一次
**状态判定**，不做一次性 flag —— 规则对状态幂等，备份恢复进来还会再触发。

| 状态 | base host | 是不是用户的选择 | 动作 |
| --- | --- | --- | --- |
| 全新安装 | — | — | seeding 已删，没有这个 key |
| upstream 退役的免费后端 | `pollinations.ai` / `*.pollinations.ai` | 不是 | 清引用 → 删配置 |
| 本 fork 扫描写死的死域名 | `api.cuplivoas.top` | 不是 | 清引用 → 删配置 |
| 真·Kelivo 配置 | `api.psycheas.top` | 是（外部基础设施） | 保留为**普通**供应商；用户自填自己的 key |
| v4.5.0 遗留的 OpenAI 空壳 | `api.openai.com`，models/apiKey 空 | 是（还可用） | 保留；现在可编辑可删除 |

最后一行**不写移除谓词**：要识别它只能靠「host + 空 key + 空 models + 名字」这种脆弱组合，
而它已经是普通供应商，用户两下就能删掉。

```dart
  /// Hosts this fork's own builds wrote into the retired built-in provider.
  ///
  /// Both are our mistakes, never a user's choice: `pollinations.ai` is the free
  /// backend upstream retired, and `api.cuplivoas.top` is what an identity sweep
  /// made of upstream's own host — a domain with no records at all. A config
  /// pointing at either can never answer, so it leaves together with every
  /// assistant and conversation reference to it.
  ///
  /// The key stays spelled `KelivoIN`: it is a persisted provider key, not a
  /// brand string, and a sweep that rewrites it makes this repair match nothing
  /// (see `79696e6f6`).
  static const _retiredProviderHosts = <String>[
    'pollinations.ai',
    'api.cuplivoas.top',
  ];

  static bool _isRetiredProviderHost(String? host) {
    if (host == null || host.isEmpty) return false;
    return _retiredProviderHosts.any(
      (retired) => host == retired || host.endsWith('.$retired'),
    );
  }

  Future<void> _retireDeadBuiltInProvider() async {
    final config = _providerConfigs['KelivoIN'];
    if (config == null) return;
    final host = Uri.tryParse(config.baseUrl)?.host.toLowerCase();
    if (!_isRetiredProviderHost(host)) return;
    // Selections first: a config removed while an assistant still names it
    // comes back as an empty default on the next read.
    await onProviderModelsRetired?.call('KelivoIN');
    await removeProviderConfig('KelivoIN');
  }
```

- `removeProviderConfig` 已经清掉 order / 分组 / 当前模型 / 标题 / 导演 / 主动陪伴等键；
  `onProviderModelsRetired`（`assistants.clearModelSelectionsForProvider`）清助手与会话级 override。
  两者的组合已被 `assistant_provider_cascade_delete_test` 覆盖，直接复用。
- 静默，不弹窗；用户侧的说明只出现在两个 changelog 的 `Removed` 里（UI 指南：可见文字是成本）。

## 4. 任务 C：备份文件名跟随目标读者

名字**不是协议**：云端（WebDAV PROPFIND / S3）与 Kelivo 自己的列表都按扩展名（`.zip` / `.kbackup`）过滤，
前缀只影响三处——用户眼里（云目录、保存对话框）、本 build 的恢复发现、临时目录回收。

### C.1 `lib/core/models/backup_target.dart`（名字跟着 target，一处派生）

```dart
  /// The name a backup file written for this target carries.
  ///
  /// Readers list by extension, so this is not a wire format: it is what the
  /// user sees in their cloud folder and what this build's recovery discovery
  /// matches. Writers use their target's prefix; [readableArchivePrefixes] is
  /// what readers accept, so a backup written before the naming changed is
  /// still discovered and reclaimed.
  String get archiveFilePrefix => switch (this) {
    BackupTarget.cuplivo => 'cuplivo_backup_',
    BackupTarget.kelivoV1_3_4 => 'kelivo_backup_',
  };

  /// Every prefix this build can read.
  static const Set<String> readableArchivePrefixes = {
    'kelivo_backup_',
    'cuplivo_backup_',
  };
```

### C.2 写侧：`lib/core/services/backup/data_sync.dart`

- `_prepareBackupArchive`（795 / 799）用 `target.archiveFilePrefix` 拼临时目录与输出名。
- 三个调用者核对过：`prepareBackupFile`（`cfg.target`）、`prepareRecoveryDatabaseArchive`（固定
  `cuplivo`）、`prepareLocalSnapshotArchive`（默认 `cuplivo`）。**本地快照的临时目录名会变成
  `cuplivo_backup_*`，但最终文件名由 `LocalSnapshotPaths.fileNameFor` 决定，仍是
  `kelivo-snapshot-<stamp>.zip`，用户看不到这次变化。**

### C.3 读侧：接受两套前缀

| 位置 | 改法 |
| --- | --- |
| `data_sync.dart:1189` `_backupTempTimestampFromName` | 先按 `readableArchivePrefixes` 去掉命中的前缀，再解析时间戳 |
| `data_sync.dart:1226-1236` 陈旧临时目录/文件回收 | 目录分支与 `.zip` 分支都用 `readableArchivePrefixes.any(name.startsWith)` |
| `data_sync.dart:1965-1969` WebDAV 名称取时间戳的正则 | `(?:kelivo|cuplivo)_backup_` |
| `recovery_file_discovery.dart:21-24` `isSnapshotArchive` | `^(?:kelivo-snapshot-|kelivo_backup_|cuplivo_backup_).+\.zip$`（或由常量拼） |

### C.4 明确不动

- `kelivo-snapshot-` 前缀：本地快照，`docs/rebase-runbook.md:173` 的白名单名字，且是老构建的恢复契约。
- `kelivo_backups`（默认云目录）、`.kelivo_backups_manifest.json`、`kelivo.db`、`.kelivo_restore/`、
  `kelivo_restore_*.zip`、`kelivo_decrypted_`（系统临时目录，转瞬即逝）：全是持久化路径或零用户价值。
  改了会让用户看不见自己已有的备份。

## 5. 测试

### 5.1 新增 `test/core/providers/kelivoin_removal_test.dart`

一张状态表，一格一条用例（AGENTS.md 的「新调用点要拿状态表，不是 happy path」）：

1. **全新装载**（空快照）：`providerConfigs` 不含 `'KelivoIN'`；`SettingsProvider.isBuiltInProvider('KelivoIN')`
   为 false；`ProviderConfig.defaultsFor('KelivoIN')` 的 `models` 为空、`baseUrl != 'https://api.cuplivoas.top/v1'`。
2. **pollinations**（`https://text.pollinations.ai/openai`）：配置被删除，`onProviderModelsRetired` 收到
   `'KelivoIN'`，助手与会话的引用被清空（复用 cascade 测试的 harness）。
3. **cuplivoas**（`https://api.cuplivoas.top/v1`）：同上，且 `providers_order_v1` / 分组里也不再有它。
4. **psycheas**（`https://api.psycheas.top/v1` + 假 key）：配置**保留**，`enabled`/`models`/`apiKey` 原样，
   但 `isBuiltInProvider` 为 false（普通供应商）。
5. **openai 空壳**（v4.5.0 形态）：保留，同样不是 built-in。

### 5.2 改造既有

| 文件 | 改法 |
| --- | --- |
| `test/core/providers/assistant_provider_cascade_delete_test.dart` | 用例名与 fixture 换成中性 provider；删掉 L154 对 `models contains 'auto'` 的断言（它现在钉的是坏行为），改为断言配置已被移除；机制（清引用）保留 |
| `test/settings_provider_business_preferences_test.dart:141` | `migratedOrder` 去掉 `'KelivoIN'` |
| `test/builtin_provider_test.dart` | 加一条：`KelivoIN` 不是内建、没有预填模型 |
| `test/core/services/backup/data_sync_backup_file_test.dart:1559-1573, 1901, 1962` | 临时名断言与假 PROPFIND 过滤改为接受两套前缀 |
| `test/core/services/backup/backup_temp_cleanup_test.dart` | 两种前缀的陈旧目录/文件都被回收 |
| `test/core/services/backup/recovery_file_discovery_test.dart` | `cuplivo_backup_*.zip` 被发现 |
| `test/core/services/backup/s3_bucket_list_fallback_test.dart` | 桶列表里两种前缀都可见（按扩展名） |
| 新增（可并入 data_sync 测试） | 「Cuplivo target 产出 `cuplivo_backup_*`、Kelivo target 产出 `kelivo_backup_*`」 |

### 5.3 证明守卫（AGENTS.md §7，先备份再注入，最后字节还原）

| 注入的违例 | 应该变红的断言 |
| --- | --- |
| 把 `ensureProviderConfig('KelivoIN', ...)` 加回 `_load` | 5.1 用例 1 |
| 把 `_retiredProviderHosts` 里的 `api.cuplivoas.top` 删掉 | 5.1 用例 3 |
| 让 `archiveFilePrefix` 两个 target 都返回 `kelivo_backup_` | C.2 的新用例 |

## 6. 文档

1. **新增 `docs/adr/0018-remove-built-in-kelivoin.md`**：fork 边界（别人的服务 + 别人的凭证）、
   为什么不能「保留但做成可用」、修复状态表、命名跟 target 走。ADR-0001 的 L70 与代码终于一致，那里的
   图标说明（L79-80）保持不变。
2. **`CHANGELOG.md` / `CHANGELOG_CN.md`**（同一提交，条目一致，Unreleased）：
   - `Removed`：内建免费供应商 KelivoIN 删除；指向它的旧配置（退役的 pollinations 后端、本 fork 曾
     写死的 `api.cuplivoas.top`）在启动时一并清除，助手与会话里的模型引用同时清空。
   - `Changed`：备份文件名跟随「备份目标」——写给 Kelivo 的是 `kelivo_backup_*.zip`，写给自己的是
     `cuplivo_backup_*.zip`；两边都能读取对方写过的旧文件。
3. **`docs/rebase-runbook.md`**：在「已删除且不许回来」清单里加 KelivoIN，写明机制（身份单元的提交
   信息声称移除、重基时树照旧带回）与常设闸门（`test/core/providers/kelivoin_removal_test.dart`，
   与规则 17 的 `kelivo_vocabulary_test` 同一体例）。
4. **`CONTEXT.md`**：品牌边界那节的持久化名单里补一句备份文件前缀（写 `cuplivo_backup_`，读两套）。

## 7. 门禁

```bash
dart analyze --fatal-infos lib test integration_test
dart format lib test integration_test          # 用 CI 固定的 Dart 3.13.0；本地版本不同按 AGENTS.md
flutter test test/core/providers test/core/services/backup test/core/database \
             test/features/provider test/features/backup \
             test/settings_provider_business_preferences_test.dart \
             test/builtin_provider_test.dart
flutter gen-l10n                               # 本次不动 ARB，必须是幂等的
```

`dependencies/markstream` 不受影响，不需要跑。全量套件只在合并时跑。

建议三段提交，每段各自过门禁：`fix(provider): KelivoIN 删除` / `fix(provider): 清掉死域名配置` /
`refactor(backup): 文件名跟随目标读者`。PR 标题走仓库惯例的英文一行式，body 里必须有：
问题（含 §0 的表）、为什么不能保留、命名决定、守卫证明、门禁数字。

## 8. 手工验收（自动化测不到的部分）

1. 全新 profile 启动 → 「供应商」页没有 KelivoIN 行；模型选择器里没有那四个免费模型。
2. 打一个含 `api.cuplivoas.top` 的 `provider_configs_v1` 快照 → 启动后该 provider 消失，
   原来选中它的助手/会话回到默认模型，无弹窗。
3. 打一个含 `api.psycheas.top` 的快照 → provider 仍在，且**字段可以编辑**、有删除按钮。
4. 备份页选「Cuplivo」导出 → 文件名 `cuplivo_backup_<ts>.zip`；选「Kelivo 1.3.4」→ `kelivo_backup_<ts>.zip`；
   两份都能在本 build 的恢复列表里看到。

## 9. 不做

- 不写兼容层、不留旧分支（AGENTS.md：不为向后兼容保留路径）。
- 不改 `kelivo-snapshot-` / `kelivo_backups` / `.kelivo_backups_manifest.json` / `kelivo.db`。
- 不为 v4.5.0 的 OpenAI 空壳写移除谓词（§3 最后一行）。
- 不 patch `dependencies/markstream`。

## 10. 落地记录（2026-11-08）

### 门禁（Dart 3.13.0 / Flutter 3.47.6，Windows）

| 门禁 | 结果 |
| --- | --- |
| `flutter pub get --enforce-lockfile`（新 worktree 首次解析） | 通过，`pubspec.lock` 无改动 |
| `dart analyze --fatal-infos lib test integration_test` | No issues found |
| `dart format`（15 个改动文件） | 2 个被格式化，其余不变 |
| `flutter gen-l10n` | 幂等：`lib/l10n/` 无变化（本次不动 ARB） |
| `flutter test test/core/providers test/core/services/backup test/core/database test/features/provider test/features/backup test/settings_provider_business_preferences_test.dart test/builtin_provider_test.dart` | **1797 通过，15 跳过，0 失败** |

### 守卫证明（AGENTS.md §7：注入前备份、注入后字节还原并比对 sha256）

| 注入的违例 | 变红的用例 | 实际断言 |
| --- | --- | --- |
| `_load` 里加回 `ensureProviderConfig('KelivoIN', …)` | §5.1 用例 1 | `containsKey('KelivoIN')` 期望 false，实际 true |
| `_retiredProviderHosts` 去掉 `api.cuplivoas.top` | §5.1 用例 3 | `retiredCalls` 期望 `['KelivoIN']`，实际 `[]` |
| `archiveFilePrefix` 两个 target 都返回 `kelivo_backup_` | §5.2 的 C.2 新用例 | 期望 `cuplivo_backup_` 开头，实际 `kelivo_backup_2026-11-08T01-25-07.299074.zip` |

三次注入后 `settings_provider.dart`（`d1ebfa09…`）与 `backup_target.dart`（`686469cd…`）都还原到
注入前的 sha256，备份目录已删除。

### 与计划的偏差

1. **`assistant_provider_cascade_delete_test.dart` 第一个用例换了触发方式。** 中性 key 下没有生产路径
   会触发退役，所以该用例改为直接执行退役的两步（`clearModelSelectionsForProvider` →
   `removeProviderConfig`），只钉「清引用 + 删配置」这个机制；KelivoIN 的完整触发链由新测试的
   用例 2/3 覆盖（含助手与会话引用、持久化、重新加载）。
2. **读侧前缀是派生的，不是复述的。** `readableArchivePrefixPattern` / `stripReadableArchivePrefix`
   由 `readableArchivePrefixes` 生成，WebDAV 时间戳正则、`isSnapshotArchive`、临时目录回收都取这一处；
   新用例断言 `values.map(archiveFilePrefix).toSet() == readableArchivePrefixes`，把「写出的名字一定是
   读得到的名字」变成测试。
3. **`recovery_file_discovery.dart` 的 `hasPriorData` 也接受两套前缀**（计划只列了 `isSnapshotArchive`）：
   它判断的是同一类证据，漏掉会让一次只写过 `cuplivo_backup_` 的安装看起来像首次启动。
4. **新增 `BackupTarget.cuplivo => 'cuplivo_backup_'` 之后，本地快照的临时工作目录名仍是
   `cuplivo_backup_*`**，§4.2 已说明该变化对用户不可见（最终文件名由 `LocalSnapshotPaths.fileNameFor`
   决定为 `kelivo-snapshot-<stamp>.zip`）。

### 未做

- §8 的四项手工验收（需要真机/桌面实际运行），以及计划 §7 建议的三段提交：改动目前都在工作区，
  拆分与提交待确认后执行。
