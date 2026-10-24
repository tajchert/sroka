# Redesign ledger (see RULINGS.md)

| Task | Status | Commit / notes |
|---|---|---|
| T1 theme + mark | todo | |
| T0a core library (pending flag, Resyncing, search) | todo | |
| T0b core transfer (import/export) | done | see notes below |
| T2 auth | todo | |
| T3 library list + search + nav | todo | |
| T4 share sheet + tags | todo | |
| T5 reader | todo | |
| T6 settings + import + export | todo | |
| Review + gate | todo | |

## Notes from tasks

### T0b (import/export core)
- Model (`core/model/Transfer.kt`): `ImportFormat(wire)` {POCKET_CSV, POCKET_HTML, INSTAPAPER_CSV, NETSCAPE_HTML}, `ExportFormat(wire, extension)` {CSV, JSON}, `JobStatus` {QUEUED, RUNNING, DONE, FAILED} (`isFinished`), `ImportJob(id, status, format, total: Int?, done, skipped, error, createdAt, updatedAt)`.
- Network: `SrokaApi.createImport(source: File, fileName: String, mimeType: String, format: ImportFormat): ApiResult<JobDto>`, `getImport(id): ApiResult<JobDto>`, `export(format: ExportFormat, dest: File): ApiResult<ExportFileDto(fileName, bytes)>`. Any other `SrokaApi` stub must implement these three.
- Domain `DataTransferRepository`: `startImport(uri: String, format): ImportStartResult` (Started(job) | Failed(ImportError)), `activeImport(): Flow<ImportJob?>`, `dismissImport()`, `export(format): ExportResult` (Ready(path, fileName, bytes) | Failed(ExportError)), `fileInfo(uri): PickedFile?(name, sizeBytes: Long?)`, `MAX_IMPORT_BYTES`.
- Active job is stored in the user-preferences DataStore (key `active_import`, `ImportJobStore`); `LocalDataWiper` clears it on sign-out/delete. Worker `ImportProgressWorker` (unique name `sroka-import-<jobId>`, tagged `sroka`); polling logic is `pollUntilFinished` + `ImportTracker`.
- Notification channel "Imports"; texts in `core/data/.../values/strings_transfer.xml`. `ic_stat_sroka.xml` copied from core:designsystem (c652171) into `core/data/res/drawable` (no module dependency); `SyncNotifications` switched to it too. If the glyph changes in designsystem, copy it again.
- Notes for T6: the UI should request POST_NOTIFICATIONS itself (core:ui `NotificationPermission`); the worker keeps polling without it. Gradle config cache held a stale JDK path in this worktree; I ran with `--no-configuration-cache`.
