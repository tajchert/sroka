# October 2026 Android refresh

The stable dependency audit on 5 October 2026 found three outdated pins:
Core KTX 1.19.0 → 1.19.1, Kover 0.9.9 → 0.9.11, and Gradle 9.7.1 → 9.8.0.
The other stable pins were current. Room moved separately from 2.8.5 to
Room 3.0.3, and the explicitly accepted screenshot plugin remains alpha16.

## Implemented changes

- Room 3 runtime, compiler, testing library, and plugin; explicit platform SQLite
  driver 2.7.1. Database filename, schema version 2, historical schemas, and
  identity hash remain compatible with existing installations.
- Existing Navigation 3 1.2.0 routes, deep links, adaptive scenes, and scoped
  ViewModels retained and regression-tested.
- Benchmark/Baseline Profile 1.5.0, Profile Installer 1.4.1, UI Automator 2.4.0.
  Two real generated profiles cover startup and opening Create task. The
  benchmark module compares cold launches with and without profile compilation.
- Four new screenshot references: long task cards in light/dark themes,
  dark-mode form validation, and long task details with larger fonts.

## Verification

Full unit tests, debug lint/assembly, release lint/minified assembly, and both
benchmark APK variants passed. Regular assembly reused the configuration cache
and did not invoke profile generation. Compiled profiles are present in release
and benchmark APKs.

On the API 37.1 emulator: all five Room compatibility/DAO tests, nine feature
instrumentation tests, and both profile generator methods passed. All 46
screenshot comparisons passed, and the new images were visually inspected.
An independent code review found an optimization inheritance issue in the
benchmark variant; it was corrected, rebuilt, and reviewed again.

Both startup measurements rejected the emulator with the standard unsuppressed
`EMULATOR` error. Physical-device timings remain to be collected; no performance
improvement is claimed. See [performance testing](PERFORMANCE_TESTING.md).

## Release references

- [AndroidX release list](https://developer.android.com/jetpack/androidx/versions/all-channel)
- [Room 3 releases](https://developer.android.com/jetpack/androidx/releases/room3)
- [Navigation 3 releases](https://developer.android.com/jetpack/androidx/releases/navigation3)
- [Benchmark releases](https://developer.android.com/jetpack/androidx/releases/benchmark)
- [Screenshot testing releases](https://developer.android.com/studio/preview/compose-screenshot-testing-release-notes)
- [Gradle releases](https://gradle.org/releases/)
