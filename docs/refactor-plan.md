# ScoutCapture refactor plan

## Starting point

- Branch: `codex/refactor-test`, based on source commit `4e04061` (app version 1.2, build 19).
- The original `main` working tree has separate local edits and is not used for these changes.
- The prechange simulator test run produced 1,108 passes and 105 failures before one test stalled and the run was stopped. Those failures precede this refactor. The full suite is not yet a reliable pass/fail gate.

## Completed on the refactor branch

1. **Preset ownership.** One shared `DetailTypesModel` now serves standard and fast capture. The second model and its duplicate persistence logic were removed. Focused tests cover cross-view edits, persistence, and fast capture's Overview selection.
2. **Credential exposure check.** A value-redacting scanner checks tracked files and optionally a built app for recognizable privileged keys. A pull request workflow runs the source scan. The current source and Build 19 / refactor app bundles contain no recognized privileged credentials. The Supabase publishable key remains in the app as a public client identifier.
3. **ZIP export code.** Three in-memory ZIP writers and duplicate entry readers were consolidated into `StoredZipArchive`. Focused tests and an independent ZIP reader verified archive paths, file contents, and checksums. ZIP32 bounds now fail explicitly.
4. **Export memory use.** Export enumeration keeps file URLs rather than all photo bytes. The active export paths stream ZIP contents in 64 KiB chunks and copy staged photos at the file level.

## Next steps, in order

1. **Restore a trustworthy test baseline.** Group and reproduce the 105 prechange failures, identify any shared simulator or test-data contamination, and establish a fast smoke gate plus a full-suite gate. Do not attribute existing failures to the refactor.
2. **Finish archive integration.** Exercise an export with a realistic large photo set, compare its layout with Build 19, and move the separate temporary migration ZIP writer onto the shared archive machinery. Keep ZIP32 limits visible to users or add ZIP64 support if real sessions can exceed them.
3. **Split `AppState` by responsibility.** Extract session lifecycle and synchronization policies behind narrow interfaces, one behavior at a time, with characterization tests for state transitions and offline retry. Avoid a whole-file rewrite of the 63,000-line type.
4. **Consolidate configuration.** Put feature flag defaults, environment overrides, and diagnostics redaction behind one typed configuration layer. Preserve existing rollout gates.
5. **Remove remaining duplication.** Consolidate repeated report packaging helpers, export path checks, and file naming rules once the test baseline can detect behavior changes.
6. **Protect security boundaries.** Review deployed Supabase RLS and storage policies against the checked-in migrations; verify service-role credentials remain only in server environments. The repository and app bundle scan cannot prove the live database policies are deployed or correct.
7. **Add continuous verification.** Run the chosen smoke suite, archive tests, and credential scan on pull requests. Add a built-app credential scan in a build environment with enough storage.

Each extraction should be a separate commit with a build, focused behavior tests, and a review of user-visible export or capture behavior before merging to `main`.
