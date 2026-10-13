# ScoutCapture refactor plan

## Starting point

- Branch: `codex/refactor-test`, based on source commit `4e04061` (app version 1.2, build 19).
- The original `main` working tree has separate local edits and is not used for these changes.
- The prechange simulator test run produced 1,108 passes and 105 failures before one test stalled and the run was stopped. One property-status failure reproduced in isolation (`testCachedExportedFreshRemoteOccupiedByOtherBlocksEntry`, cache status was `nil` instead of `occupied`). Tracing showed a startup authentication callback arriving after its fixture installed a fake user; that callback cleared the organization scope and status cache. Cancelling the startup callback when observation stops and stopping the unused observer in this fixture made the isolated test pass. The other prechange failures remain unclassified, so the full suite is not yet a reliable pass/fail gate.

## Test baseline investigation

After cancelling the stale authentication startup callback in the property-status test fixture, the full `Phase2C27FZ4PropertyStatusDiagnosticsTests` class ran to completion: **75 tests, 58 passing cases, 17 failing cases (35 failed assertions)**. The isolated case that first exposed the callback race passes, along with two neighboring entry tests. The initial failing cases clustered as follows:

| Area | Failing cases | Examples |
| --- | ---: | --- |
| Cross-device ownership, lock, and badge state | 7 | Same user on another device treated as owner by an older test, but current code treats the device as the owner when one is recorded; pending-export badge and lock expectations also differ. |
| No-ZIP release and local reconciliation | 3 | Stale draft or released status remains visible; one persistent-data reconciliation assertion checked before a scheduled refresh completed. |
| User-facing lock wording | 6 | Tests expect older phrases such as “on device”; the app now renders a short bullet-separated description. |
| Missing-row preflight reason | 1 | The app reports `fresh_read_missing_row`; the test expects `missing_property_status_row`. |

Source history confirmed that the six lock-message tests expected older copy. After updating only those assertions, the full class reran with **64 passing and 11 failing cases (27 failed assertions)**. The missing-row test expected an older diagnostic reason and now passes in isolation. Four pending-export tests expected both a Pending Export badge and a Lock badge; Build 19 intentionally shows the Pending Export badge while still blocking entry, and all four pass with that expectation. The persistent-data reconciliation test checked before the app's 180 ms debounce; after waiting for the actual refresh, it passes. **Five behavioral cases remain unaddressed**: cross-device draft ownership and no-ZIP release and draft badges. Review their product rules and fixtures before changing runtime behavior or assertions. This class is one slice of the earlier 105-failure Build 19 run; the other failures are still unclassified.

## Completed on the refactor branch

1. **Preset ownership.** One shared `DetailTypesModel` now serves standard and fast capture. The second model and its duplicate persistence logic were removed. Focused tests cover cross-view edits, persistence, and fast capture's Overview selection.
2. **Credential exposure check.** A value-redacting scanner checks tracked files and optionally a built app for recognizable privileged keys. A pull request workflow runs the source scan. The current source and Build 19 / refactor app bundles contain no recognized privileged credentials. The Supabase publishable key remains in the app as a public client identifier.
3. **ZIP export code.** Three in-memory ZIP writers and duplicate entry readers were consolidated into `StoredZipArchive`. Focused tests and an independent ZIP reader verified archive paths, file contents, and checksums. ZIP32 bounds now fail explicitly.
4. **Export memory use and migration ZIP.** Export enumeration keeps file URLs rather than all photo bytes. The active export paths stream ZIP contents in 64 KiB chunks, copy staged photos at the file level, and read only the ZIP directory during validation. The temporary migration export now uses the same streaming ZIP writer while preserving its directory entries and per-entry progress updates. Focused ZIP tests pass.

## Next steps, in order

1. **Restore a trustworthy test baseline.** Group and reproduce the 105 prechange failures, identify any shared simulator or test-data contamination, and establish a fast smoke gate plus a full-suite gate. Do not attribute existing failures to the refactor.
2. **Validate archive integration at realistic size.** Exercise an export with a large photo set and compare its layout with Build 19. Keep ZIP32 limits visible to users or add ZIP64 support if real sessions can exceed them. The migration importer still has a separate ZIP reader; consolidate only after checking import compatibility and path validation.
3. **Split `AppState` by responsibility.** Extract session lifecycle and synchronization policies behind narrow interfaces, one behavior at a time, with characterization tests for state transitions and offline retry. Avoid a whole-file rewrite of the 63,000-line type.
4. **Consolidate configuration.** Put feature flag defaults, environment overrides, and diagnostics redaction behind one typed configuration layer. Preserve existing rollout gates.
5. **Remove remaining duplication.** Consolidate repeated report packaging helpers, export path checks, and file naming rules once the test baseline can detect behavior changes.
6. **Protect security boundaries.** Review deployed Supabase RLS and storage policies against the checked-in migrations; verify service-role credentials remain only in server environments. The repository and app bundle scan cannot prove the live database policies are deployed or correct.
7. **Add continuous verification.** Run the chosen smoke suite, archive tests, and credential scan on pull requests. Add a built-app credential scan in a build environment with enough storage.

Each extraction should be a separate commit with a build, focused behavior tests, and a review of user-visible export or capture behavior before merging to `main`.
