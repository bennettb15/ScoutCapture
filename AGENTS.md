# ScoutCapture release baseline

- Before making changes or building a release, fetch the remote and verify the most recently released or uploaded version and build against the Xcode project settings. Start from that version's latest source, never an older checkout or worktree.
- If the current worktree is behind the verified release source, update or create a fresh branch from the correct commit before editing. Recheck the version and build in the finished app bundle before installing or distributing it.

# Build storage

- Prefer `/Users/brian/Documents/Codex` for Codex generated project work; it is redirected to the Samsung external SSD.
- Keep large ScoutCapture temporary clones, build output, test results, archives, and logs on the Samsung external SSD under `/Volumes/Samsung 4TB/Codex/tmp/ScoutCapture`.
- Set Xcode DerivedData to `/Volumes/Samsung 4TB/Codex/tmp/DerivedData` when a custom path is supported. Do not create new large work directories directly under `/tmp` or `/private/tmp`.
- If the external SSD is not mounted, ask before running a large build or test instead of falling back to internal storage.
