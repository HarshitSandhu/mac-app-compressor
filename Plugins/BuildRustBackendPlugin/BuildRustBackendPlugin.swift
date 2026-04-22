import Foundation
import PackagePlugin

@main
struct BuildRustBackendPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let outputDirectory = context.pluginWorkDirectory.appending(subpath: "RustBackend")
        let homeDirectory = ProcessInfo.processInfo.environment["HOME"] ?? ""

        return [
            .prebuildCommand(
                displayName: "Building Rust backend",
                executable: Path("/bin/bash"),
                arguments: [
                    "-c",
                    """
                    set -euo pipefail
                    PACKAGE_DIR="$1"
                    OUTPUT_DIR="$2"
                    TARGET_DIR="$OUTPUT_DIR/cargo-target"
                    HOME_DIR="$3"
                    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin:$HOME_DIR/.cargo/bin"
                    if command -v cargo >/dev/null 2>&1; then
                      CARGO_BIN="$(command -v cargo)"
                    elif [ -n "$HOME_DIR" ] && [ -x "$HOME_DIR/.cargo/bin/cargo" ]; then
                      CARGO_BIN="$HOME_DIR/.cargo/bin/cargo"
                    else
                      echo "cargo not found" >&2
                      exit 1
                    fi

                    mkdir -p "$OUTPUT_DIR"
                    "$CARGO_BIN" build --manifest-path "$PACKAGE_DIR/rust-backend/Cargo.toml" --target-dir "$TARGET_DIR"
                    "$CARGO_BIN" build --manifest-path "$PACKAGE_DIR/rust-backend/Cargo.toml" --target-dir "$TARGET_DIR" --release
                    printf '%s\n' "$TARGET_DIR/debug/compressor-backend" > "$OUTPUT_DIR/compressor-backend-debug-path.txt"
                    printf '%s\n' "$TARGET_DIR/release/compressor-backend" > "$OUTPUT_DIR/compressor-backend-release-path.txt"
                    """,
                    "build-rust-backend",
                    context.package.directory.string,
                    outputDirectory.string,
                    homeDirectory
                ],
                outputFilesDirectory: outputDirectory
            )
        ]
    }
}
