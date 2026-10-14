# Replace the Tasks sample

First [adopt the project identity](ADOPTING.md), then replace the sample in small compiling steps. Names and paths below describe the original checkout; adoption changes package paths and `Sroka*` names.

## Where the sample is connected

| Area | Files or modules to change |
|---|---|
| Feature UI and routes | `feature/tasks/api` and `feature/tasks/impl`, including `navigation/TasksNavGraph.kt` |
| App composition | `app/build.gradle.kts` feature dependencies and `app/.../navigation/SrokaNavHost.kt` entry provider and starting route |
| Incoming links | Tasks deep-link files in the feature API, `MainActivity.kt`, and the app manifest's intent filters |
| Task storage | Task model in `core:model`; entities, DAO, database, migrations, and schema exports in `core:database` |
| Data and domain | Task repository/mappers and `DataModule.kt` in `core:data`; task use cases in `core:domain` |
| Demo backend | Task DTO/interface/fake and `di/NetworkModule.kt` in `core:network` |
| Initial demo data | `DemoTaskSeed.kt` and `.addCallback(DemoTaskSeed)` in `core:database/.../di/DatabaseModule.kt` |
| Development host | `samples/tasks-app`, its settings include, and any coverage exclusions that mention it |
| Tests and profiles | Task fixtures in `core:testing`, feature/app tests, screenshots, and Tasks journeys in `benchmark` |
| Build configuration | Module includes in `settings.gradle.kts`, type-safe project references, and CI task/class filters |

## Suggested sequence

1. Add your feature's API routes, implementation, navigation contribution, and focused tests. Connect it in the app and make its route the starting destination. Features depend on other features' APIs, not implementations.
2. Replace or remove Tasks deep-link resolution and manifest filters together. Update cold/warm-start navigation tests. Follow [Deep links](DEEP_LINKS.md) for validation and App Link setup.
3. Remove the demo seed callback and object when your product no longer needs them. Removing the callback does not delete already-stored demo rows. For disposable development data, clearing the app is explicit; a shipped app needs a migration/data-cleanup decision.
4. Replace the task data/domain/network bindings with product contracts. Keep Room as the source of truth if retaining this pattern. For networking, add actual permissions, transport dependencies, environment selection, and a backend binding deliberately; see [Security defaults](SECURITY_DEFAULTS.md) and [Sync](SYNC.md).
5. Decide where preferences belong. Theme and sorting controls currently live in the Tasks implementation. Move reusable theme/preferences controls before deleting that feature; both hosts currently observe preferences.
6. Remove the old feature and optional Tasks host only after no consumers reference them. Update settings, module dependencies, Hilt bindings, test fixtures, and root coverage configuration. Remove core modules only when nothing uses them.
7. Replace functional/profile journeys and CI class filters. Remove stale generated profiles and screenshot references, then regenerate and inspect them for the new UI. See [Performance](PERFORMANCE_TESTING.md) and [Screenshots](SCREENSHOT_TESTING.md).

Search for remaining sample references, inspecting each result rather than performing a blanket deletion:

```bash
rg -n 'Task|tasksEntries|TasksDeepLinks' app core feature samples benchmark settings.gradle.kts .github
```

Retain exported Room schemas and migration tests whenever an existing database must remain compatible. Never use destructive migration to make the replacement compile. Run [verification](TESTING.md#commands), applicable device tests, and the product journey after the transition. Update the README's implemented-feature inventory and relevant guides.
