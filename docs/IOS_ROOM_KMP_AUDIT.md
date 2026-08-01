# Room KMP compatibility audit

Decision: keep Room as the shared schema owner. Do not move the database until the Android and iOS
builders and the complete version 8–22 migration matrix can run on macOS. SQLDelight is not selected,
so no replacement ADR is required.

## Inventory

The Android database is schema version 22 with 14 entities, 14 DAOs, 79 suspend DAO methods, 12
Flow or non-suspending declarations, and 14 explicit migrations covering every step from 8 to 22.
Versions 1–7 intentionally use the existing destructive fallback because their shipped schemas were
not exported consistently. That legacy behavior must not be broadened.

| File / object | Current API | KMP disposition | Required change before moving |
|---|---|---|---|
| `Entities.kt` | 14 Room entities, primitive/String columns | Compatible in principle | Move as one schema change; confirm Room Native generation for every index/default. |
| `ServerDao` | Flow reads; suspend CRUD/status updates | Compatible | Add Native DAO smoke tests. |
| `MetricHistoryDao` | Flow and suspend reads; bulk cleanup; indexed latest queries | Compatible, performance-sensitive | Preserve query plans and the `(serverId,timestamp)` index; benchmark Native SQLite. |
| `SshKeyDao` | Flow/list/insert/delete | Compatible, security-sensitive | Store encrypted payload metadata only; Keychain remains outside Room. |
| `CredentialProfileDao` | Flow/list/get/insert/delete | Compatible, security-sensitive | Map platform secret IDs; never introduce plaintext secrets. |
| `AlertRuleDao` | Flow/list/insert/delete/cleanup | Compatible | Test empty `NOT IN` arguments and Native invalidation. |
| `ActiveAlertDao` | Flow/list/insert-ignore/ack/mute/delete | Compatible, concurrency-sensitive | Preserve unique `(ruleId,serverId)` conflict behavior. |
| `AlertHistoryDao` | Flow/list/insert/aggregate/cleanup | Compatible | Validate aggregate projection mapping on Native. |
| `QuickScriptDao` | Flow/list/insert/delete | Compatible | Preserve user scripts byte-for-byte through migration/import. |
| `PortForwardDao` | Flow/list/insert/update/delete | Compatible | Keep socket/platform types out of entities. |
| `StackRegistryDao` | suspend list/upsert/delete | Compatible | Validate unique-index conflict semantics. |
| `WolTargetDao` | Flow/list/insert/update/delete | Compatible | Keep network permission in a platform adapter. |
| `NetworkShareDao` | Flow/list/insert/update/delete | Compatible, secret-sensitive | Write a security migration for the existing password field before production iOS use. |
| `AppSettingDao` | Flow/list/get/upsert/delete | Compatible | Version serialized values and exclude platform objects. |
| `PersistentSessionDao` | suspend list/upsert/delete | Compatible | Keep tmux name/server identity stable. |
| `AppDatabase` declaration | Android Room annotations and DAO accessors | KMP-capable after plugin/source-set conversion | Move only after builders and migration tests exist. |
| `getInstance(Context)` | Android `Room.databaseBuilder` singleton | Android-only | Replace with injected Android builder and iOS Native builder. |
| migrations 8–22 | `Migration` + `SupportSQLiteDatabase.execSQL` | Blocking | Convert to Room's KMP SQLite migration API; preserve SQL exactly. |
| destructive fallback 1–7 | Android builder option | Builder policy | Reproduce only for 1–7; never use a general fallback. |
| schema export/tests | JSON + Android `MigrationTestHelper` | Android tooling | Keep API29/API35 matrix and add macOS Native fixtures from the same schemas. |

## Migration gate

Database movement remains blocked until one PR proves all of the following on its exact head:

1. Android opens every exported start version and migrates to 22 on API 29 and API 35.
2. iOS/Native opens equivalent fixtures, applies 8–22 without destructive fallback, and validates
   tables, indices, defaults, representative data, and unique constraints.
3. Fresh databases on both platforms export equivalent schema contracts.
4. Cancellation and concurrent Flow collection do not close a database still owned by another store.
5. Network-share plaintext-secret handling has a written migration and rollback plan.

No database source was moved as part of this audit.
