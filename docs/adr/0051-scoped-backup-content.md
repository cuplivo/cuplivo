# Scoped Backup Content (备份内容六位)

Backups used to be gated by two booleans (`includeChats`/`includeFiles`) with `settings.json` and `skills/` always packed. Issue #306's page redesign needed honest content scoping, so the scope became a six-bit `BackupContentScope` stored in both channel configs (`WebDavConfig`/`S3Config`): 聊天记录及助手 (chats + assistants keys split out of settings.json), 设置项, 附件 (upload+images), 工作区 (workspaces), 技能 (skills), 字体与头像 (fonts+avatars). We deliberately split settings.json section-wise by key whitelist because assistants (`assistants_v1`/`assistant_memories_v1`) live inside that atom today; `settings_meta.json` only carries the written keys so the LWW merge stays key-exact.

Status: accepted

## Considered Options

- **Restore-side admission (zip stays whole)**: zero compatibility risk but the scope wouldn't shrink payloads; rejected — file sections are the payload-heavy part and must be filterable at pack time.
- **Keep assistants glued to 设置项**: avoids the split; rejected — the user explicitly wants "聊天记录及助手".

## Consequences

- Overwrite-restore semantics extend (not newly break) the existing "wipe, then write what's included": a scope-restricted ZIP restored with overwrite on an **old build** loses the excluded keys/sections. Merge is safe either way (fill-absent + LWW). Documented, accepted; defaults are all-true.
- Legacy config JSON maps: `includeChats` → chats bit, `includeFiles` → attachments+workspaces+fontsAndAvatars, settings/skills stay true (old builds always packed them). `toJson` keeps emitting the legacy keys so old builds still see their two toggles.
- Kelivo-兼容导出 (`BackupFormat.kelivoLegacy`) and LAN sync keep whole-pack semantics (legacy importer/peers), never scope-restricted.
- The old "skills/ always packed" rule is gone: skills now follow the 技能 bit end-to-end (pack + restore + incremental preview). CONTEXT.md's backup sections were rewritten accordingly.
