# ADR-0018: The built-in KelivoIN provider leaves, and the configs it wrote leave with it

**Status:** Accepted (2026-11-08)
**Deciders:** cuplivo

## Context

`KelivoIN` is upstream's built-in free provider: a hosted gateway with a prefilled model list, seeded
on first launch and special-cased in every provider screen. Cuplivo 3.x deleted it by design
(`857cf6a99`, #286), and [ADR-0001](0001-v4-restart-identity.md) has said since the restart that it is
"no longer seeded or special-cased". The code and that sentence did not agree, because every re-base
brought it back — and brought it back half-repaired:

| commit | what shipped |
| --- | --- |
| `b1702b3a9` (the 4.4 baseline) | upstream re-seeds the provider; `docs/rebase-runbook.md` treats "restore the provider list" as a routine baseline repair, so the fork boundary quietly left the tree |
| `87f613717` (the 4.3 re-base, identity unit) | the message says seeding, defaults, prefill, migration and token were all removed; the tree deleted **only** the token, and still seeded the config — and swept upstream's `api.psycheas.top` into `api.cuplivoas.top` |
| `c04deb38a` (the v4.5.0 release) | three key comparisons were swept to `'cuplivoin'`, which matches nothing: the landed shape was a disabled shell on `api.openai.com` with no models |
| `79696e6f6` (11-02) | the three comparisons were changed back to `'kelivoin'`, reactivating upstream's whole behaviour — on the dead host the rename had already written |

Measured on this line: `api.cuplivoas.top` has no DNS record at all (OS resolver and `1.1.1.1`), and
`api.psycheas.top` resolves but the free credential that made it usable was deleted at `87f613717`
(`api_key_manager.dart` has no `_kelivoPayload`, `effectiveKeyForProvider` returns the user's own key
or nothing). A config that reached the provider therefore sent `Bearer ` with an empty key. And no
reachable state could be repaired from the UI: `provider_detail_page.dart` locked name, API key, base
URL and chat path for that key and hid the type row, `providers_page.dart` listed it as a fixed row,
and `isUserAdded` was false, so it could not be deleted either.

## Decisions

1. **This fork ships no one else's free service and no one else's credential.** The built-in row,
   the seeding, the defaults, the prefilled models and the UI special cases are deleted, and the key
   is removed from `_builtInProviderKeysInOrder`. `ProviderConfig.defaultsFor('KelivoIN')` is now what
   it is for any other key: an ordinary OpenAI-compatible config — `api.openai.com`, no models,
   disabled. ADR-0001's sentence becomes true by construction, and the provider icon
   (`assets/icons/kelivo.png`, the `kelivo` regex in `brand_assets.dart`) stays, because a persisted
   `KelivoIN` is now just a provider that happens to be called that.

2. **The repair is a state decision on every load, not a one-shot flag.** A persisted config that
   points at a host *this line wrote* is removed, and every assistant and conversation selection that
   names it is cleared first (a config removed while something still selects it comes back as an
   empty default on the next read):

   | state | base host | whose choice | action |
   | --- | --- | --- | --- |
   | fresh install | — | — | nothing to do: nothing is seeded |
   | upstream's retired free backend | `pollinations.ai` / `*.pollinations.ai` | not the user's | clear references, then remove the config |
   | the dead host this fork wrote | `api.cuplivoas.top` | not the user's | clear references, then remove the config |
   | a real Kelivo config | `api.psycheas.top` | the user's (external infrastructure) | keep it as an **ordinary** provider; the user supplies the key |
   | the v4.5.0 OpenAI shell | `api.openai.com`, empty key and models | the user's (it still works) | keep it; it is editable and deletable now |

   The rule is idempotent, so a restored backup meets it again instead of carrying a dead config in
   silently. The last row deliberately has **no** removal predicate: recognising it would take a
   fragile "host + empty key + empty models + name" conjunction, and it is already an ordinary
   provider a user can delete in two taps. `removeProviderConfig` already clears order, grouping,
   title/director/proactive-care selections; `onProviderModelsRetired` (wired in `main.dart` to
   `assistants.clearModelSelectionsForProvider`) clears assistant and conversation overrides. The
   cascade is covered by `assistant_provider_cascade_delete_test`, so the repair reuses it instead of
   re-implementing it.

   Silent, with no dialog: the only user-facing statement is the `Removed` entry in the changelogs —
   visible text is a cost, and the state after the repair needs no explanation.

3. **Why not keep it and make it work.** A fork that ships a third party's free gateway sends its
   users' prompts to a server Cuplivo neither operates nor pays for, on terms neither controls — the
   same reason the built-in `kelivo` search service was removed in the identity unit. "Making it
   usable" would mean shipping *our* credential, which is worse: a secret in a public repository, and
   a bill attached to somebody else's usage. The honest minimal state is a normal provider the user
   configures, which is exactly what a persisted config becomes here.

4. **The key stays spelled `KelivoIN`.** It is a persisted provider key, not a brand string. A sweep
   that rewrites it is what made both `c04deb38a` (a shell nothing could match) and the missing half
   of `79696e6f6` (behaviour back, host gone); this repair matches on the key, so a rename makes it
   match nothing at all.

5. **A removal the identity unit merely claims needs a gate.** The message of `87f613717` described
   the removal while the tree kept the seeding, and the next baseline re-seeded it again.
   `test/core/providers/kelivoin_removal_test.dart` is the mechanical check — one case per row of the
   table in decision 2 — and it carries the same standing role for this removal that
   `kelivo_vocabulary_test.dart` carries for the backup vocabulary (runbook rule 17, now rule 18).

6. **A backup file is named for its reader.** The target a backup is written for now also decides the
   file prefix: `cuplivo_backup_*` for this build, `kelivo_backup_*` for Kelivo 1.3.4. It is not a
   wire format — WebDAV, S3 and Kelivo's own list filter by extension (`.zip` / `.kbackup`) — but it
   is what the user sees in their cloud folder and what this build's recovery discovery matches, and
   a name that says "kelivo" about an archive written for Cuplivo was the same confusion in a
   smaller place. Readers accept both prefixes, so an archive written before this change is still
   discovered, reclaimed and restorable. The local snapshot keeps its `kelivo-snapshot-<stamp>.zip`
   name: that one is a recovery contract with older builds.

## Consequences

- A persisted `KelivoIN` becomes a dynamic provider on the first launch after upgrading, so it moves
  to the end of the provider list once. That is expected, not a defect.
- `SettingsProvider.isBuiltInProvider('KelivoIN')` is false, which is what turns on the delete button,
  re-enables the base URL field and restores the provider-kind row in the detail page; "restore
  default" is off, as for any user-added provider.
- A user who was relying on the free models sees them disappear with the config. There is nothing to
  restore: the service is unreachable and its credential was never shipped to this line.
- A backup file's name now tells the truth about which build can import it, and both namings remain
  readable, so no existing archive is orphaned by the change.

## Not in scope

- No removal predicate for the v4.5.0 OpenAI shell (decision 2, last row).
- No rename of the other persisted `kelivo` names — `kelivo_backups` (the default cloud folder),
  `.kelivo_backups_manifest.json`, `kelivo.db`, `.kelivo_restore/`, `kelivo_restore_*.zip`,
  `kelivo_decrypted_*`: renaming them would hide a user's own existing backups from them.
- No compat layer for the removed code path, and no patch to `dependencies/markstream`.
