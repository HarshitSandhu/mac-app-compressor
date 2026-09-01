# Mac App Compressor

Mac App Compressor is a native macOS app for archiving rarely used apps so they take less disk space until you need them again.

The UI is written in Swift. The archive/restore backend is implemented as a Rust companion binary that the Swift app invokes over a JSON command interface. That keeps the macOS UI native while moving the core compression workflow toward a backend that can be shared across future platforms.

`swift build` and `swift run` now build the Rust backend automatically through a local SwiftPM build plugin.
The plugin builds both Rust debug and release binaries, and the Swift app prefers the matching backend profile for debug vs. release app builds.

It archives whole app bundles. It does not compress apps in place because changing files inside a signed `.app` can break code signatures, updates, or launch behavior.

## What It Does

- Lets you manually choose an app from Applications.
- Shows archived apps in a main window.
- Shows current compression or restore progress.
- Creates a compressed DMG archive using macOS `hdiutil` with LZFSE compression.
- Verifies the archive before touching the original app.
- Moves the original app to Trash after verification.
- Restores archived apps to their original paths.
- Tracks archives in a local manifest.
- Cancels a running archive or restore and cleans up after itself.
- Removes entries from the list, with or without deleting the archive file.

## What It Does Not Do

- It does not manage system apps in `/System/Applications`.
- It does not modify files inside app bundles.
- It does not archive app data, caches, preferences, or documents.
- It does not empty Trash for you.
- It does not require the whole app to run as root.

## Storage

Archives and the manifest live under:

```text
~/Library/Application Support/Compressor
```

Archives are stored in:

```text
~/Library/Application Support/Compressor/Archives
```

The manifest is stored at:

```text
~/Library/Application Support/Compressor/manifest.json
```

## Build

```bash
cd mac-app-compressor
swift build
swift build -c release
```

## Run

```bash
cd mac-app-compressor
swift run Compressor
```

The menu-bar item is named `Compressor`.
The main Compressor window opens on launch. Closing the window keeps the app running; use the menu-bar item to reopen it.

## Test

```bash
cd mac-app-compressor
cargo test --manifest-path rust-backend/Cargo.toml
swift test
```

`swift test` needs full Xcode — `XCTest` does not ship with the Command Line Tools, so with only those installed it fails at `import XCTest`. CI runs both suites on a macOS runner.

If you want the Swift app to use a backend binary from somewhere else, set `COMPRESSOR_BACKEND_BIN` to its absolute path before launching the app.

## Restore Behavior

Restore puts the app back at its original path. If another app already exists there, Compressor refuses to overwrite it.

Archives are left in place after restore, so an app can be restored again if its copy is deleted later. Restore is offered whenever the archive exists and the original path is free — including after a failed or cancelled attempt.

Use Remove to take an entry off the list. It asks whether to delete the archive file too, and warns when the archive is the only copy Compressor knows about.

## Cancelling

Archive and restore can be cancelled while they run. The backend runs as its own process group, so cancelling also stops the `hdiutil` or `ditto` work it started. A cancelled archive deletes its partial archive and leaves the original app untouched; a cancelled restore removes the half-copied bundle and leaves the archive intact.

## Disk Space Note

After an app is archived, the original is moved to Trash. macOS may not reclaim the full disk space until Trash is emptied.

## Manual Test Scenarios

1. Archive a small app from `~/Applications`.
2. Restore the same app.
3. Archive an app from `/Applications` that requires admin permission.
4. Cancel the admin prompt and confirm no manifest corruption.
5. Delete an archive manually and confirm the menu reports it as missing.
6. Try to archive `/System/Applications/Calculator.app` and confirm it is rejected.
7. Try to restore when an app already exists at the target path and confirm overwrite protection.
8. Cancel an archive midway and confirm the original app stays in place with no archive left behind.
9. Cancel a restore midway and confirm no partial app bundle is left at the destination.
10. Corrupt an archive file, attempt a restore, and confirm the entry becomes Failed and stays retryable.
11. Remove an entry with and without deleting the archive.

## Known Limitations

- Large apps can take time to archive or restore.
- Admin prompts are required for protected paths such as `/Applications`.
- Compression and restore progress is shown by phase, not by exact percentage.
- App data in `~/Library` is intentionally not touched, so total disk savings may be smaller than full app uninstallers.
