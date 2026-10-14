# Adopt the starter

Use a fresh checkout and run the adoption script in preview mode:

```bash
python3 scripts/adopt-template.py \
  --package org.example.notes --app-name "Notes" \
  --project-name notes --symbol-prefix Notes \
  --host notes.example.org --scheme notes-app
```

Review the file list, then repeat the same command with `--apply`. Repeating an already-applied identity is a no-op. Python 3 is the only script dependency.

The script updates source packages and paths, namespaces/application IDs, `Sroka*` names, app labels, project/database names, App Link hosts, custom URI schemes, benchmark targets, and Room schema directories. It validates inputs, rejects file collisions and unsafe destination paths before writing, and restores source files if a write fails. Build caches, local configuration, scripts, and historical refresh reports are preserved. Use a fresh checkout for a different identity; overlapping values in an already-adopted identity are rejected.

When package or symbol names change it removes generated Baseline Profiles and screenshot references: their encoded class names are no longer valid. Regenerate and inspect them using [performance testing](PERFORMANCE_TESTING.md) and [screenshot testing](SCREENSHOT_TESTING.md). Retain and migrate Room schema history; renaming the identity of an already-shipped product requires a separate migration/distribution decision.

After adoption:

1. Run unit tests, lint, and debug/minified release assembly from README.
2. Replace launcher icons and follow [Replace Tasks](REPLACING_TASKS.md), including its one-time demo seed and preferences controls.
3. Replace the demo backend when the product needs networking; configure logging and environments at that point.
4. Publish your host's `/.well-known/assetlinks.json` with the correct package and signing certificate, or remove App Links. Custom schemes cannot be verified.
5. Review [security and backup defaults](SECURITY_DEFAULTS.md), follow [the release workflow](RELEASING.md), and check [localization](LOCALIZATION.md) and [the product checklist](TEMPLATE_CHECKLIST.md).
6. Regenerate visual references and profiles, then run the real app journey. CI class filters are updated by the script too.

Check the script itself with `python3 -m unittest discover -s scripts/tests -v`.
