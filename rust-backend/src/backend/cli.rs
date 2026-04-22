use anyhow::{Context, Result, anyhow, bail};
use libc::{W_OK, access};
use serde::{Deserialize, Serialize};
use std::env;
use std::ffi::CString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

pub fn run() -> Result<()> {
    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        bail!("missing command");
    };

    match command.as_str() {
        "list" => {
            let options = CommonOptions::parse(args.collect())?;
            let store = ManifestStore::new(options.base_dir);
            write_json(&ListResponse {
                apps: store.load()?.apps,
            })?;
        }
        "summary" => {
            let app_path = required_value(&mut args, "--app-path")?;
            validate_existing_app(Path::new(&app_path))?;
            let size_bytes = size_of_item(Path::new(&app_path))?;
            write_json(&SummaryResponse {
                size_bytes,
                formatted: format_bytes(size_bytes),
            })?;
        }
        "archive" => {
            let options = ArchiveOptions::parse(args.collect())?;
            let mut backend = CompressorBackend::new(options.base_dir);
            let app = backend.archive(Path::new(&options.app_path))?;
            emit_result(Some(app))?;
        }
        "restore" => {
            let options = RestoreOptions::parse(args.collect())?;
            let mut backend = CompressorBackend::new(options.base_dir);
            backend.restore(options.app_id)?;
            emit_result::<ManagedApp>(None)?;
        }
        _ => bail!("unknown command: {command}"),
    }

    Ok(())
}

#[derive(Debug)]
struct CommonOptions {
    base_dir: PathBuf,
}

impl CommonOptions {
    fn parse(args: Vec<String>) -> Result<Self> {
        let mut base_dir = None;
        let mut iter = args.into_iter();
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--base-dir" => {
                    base_dir = Some(PathBuf::from(next_arg(&mut iter, "--base-dir")?));
                }
                other => bail!("unknown argument: {other}"),
            }
        }

        Ok(Self {
            base_dir: base_dir.unwrap_or_else(default_base_directory),
        })
    }
}

#[derive(Debug)]
struct ArchiveOptions {
    base_dir: PathBuf,
    app_path: String,
}

impl ArchiveOptions {
    fn parse(args: Vec<String>) -> Result<Self> {
        let mut base_dir = None;
        let mut app_path = None;
        let mut iter = args.into_iter();
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--base-dir" => {
                    base_dir = Some(PathBuf::from(next_arg(&mut iter, "--base-dir")?));
                }
                "--app-path" => {
                    app_path = Some(next_arg(&mut iter, "--app-path")?);
                }
                other => bail!("unknown argument: {other}"),
            }
        }

        Ok(Self {
            base_dir: base_dir.unwrap_or_else(default_base_directory),
            app_path: app_path.context("missing --app-path")?,
        })
    }
}

#[derive(Debug)]
struct RestoreOptions {
    base_dir: PathBuf,
    app_id: Uuid,
}

impl RestoreOptions {
    fn parse(args: Vec<String>) -> Result<Self> {
        let mut base_dir = None;
        let mut app_id = None;
        let mut iter = args.into_iter();
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--base-dir" => {
                    base_dir = Some(PathBuf::from(next_arg(&mut iter, "--base-dir")?));
                }
                "--app-id" => {
                    app_id = Some(Uuid::parse_str(&next_arg(&mut iter, "--app-id")?)?);
                }
                other => bail!("unknown argument: {other}"),
            }
        }

        Ok(Self {
            base_dir: base_dir.unwrap_or_else(default_base_directory),
            app_id: app_id.context("missing --app-id")?,
        })
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct ManagedApp {
    id: Uuid,
    display_name: String,
    bundle_identifier: Option<String>,
    original_path: String,
    archive_path: String,
    original_size_bytes: i64,
    archive_size_bytes: i64,
    created_at: String,
    last_restored_at: Option<String>,
    status: CompressionStatus,
}

impl ManagedApp {
    fn with_status(&self, status: CompressionStatus, restored_at: Option<String>) -> Self {
        Self {
            id: self.id,
            display_name: self.display_name.clone(),
            bundle_identifier: self.bundle_identifier.clone(),
            original_path: self.original_path.clone(),
            archive_path: self.archive_path.clone(),
            original_size_bytes: self.original_size_bytes,
            archive_size_bytes: self.archive_size_bytes,
            created_at: self.created_at.clone(),
            last_restored_at: restored_at.or_else(|| self.last_restored_at.clone()),
            status,
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum CompressionStatus {
    Archived,
    Restoring,
    Restored,
    Failed,
}

#[derive(Debug, Serialize, Deserialize, Default)]
struct ArchiveManifest {
    apps: Vec<ManagedApp>,
}

impl ArchiveManifest {
    fn archived_app_for_original_path(&self, path: &Path) -> Option<&ManagedApp> {
        let normalized = normalized_path(path);
        self.apps.iter().find(|app| {
            normalized_path(Path::new(&app.original_path)) == normalized
                && app.status == CompressionStatus::Archived
        })
    }

    fn upsert(&mut self, app: ManagedApp) {
        if let Some(index) = self.apps.iter().position(|existing| existing.id == app.id) {
            self.apps[index] = app;
        } else {
            self.apps.push(app);
        }
    }

    fn update_status(
        &mut self,
        id: Uuid,
        status: CompressionStatus,
        restored_at: Option<String>,
    ) -> Result<()> {
        let Some(index) = self.apps.iter().position(|app| app.id == id) else {
            bail!("app not found in manifest: {id}");
        };
        let app = self.apps[index].clone();
        self.apps[index] = app.with_status(status, restored_at);
        Ok(())
    }

    fn app_by_id(&self, id: Uuid) -> Option<&ManagedApp> {
        self.apps.iter().find(|app| app.id == id)
    }
}

struct ManifestStore {
    manifest_path: PathBuf,
    archive_directory: PathBuf,
}

impl ManifestStore {
    fn new(base_dir: PathBuf) -> Self {
        Self {
            manifest_path: base_dir.join("manifest.json"),
            archive_directory: base_dir.join("Archives"),
        }
    }

    fn ensure_directories_exist(&self) -> Result<()> {
        fs::create_dir_all(&self.archive_directory)
            .with_context(|| format!("failed to create {}", self.archive_directory.display()))
    }

    fn load(&self) -> Result<ArchiveManifest> {
        self.ensure_directories_exist()?;
        if !self.manifest_path.exists() {
            return Ok(ArchiveManifest::default());
        }

        let data = fs::read(&self.manifest_path)
            .with_context(|| format!("failed to read {}", self.manifest_path.display()))?;
        serde_json::from_slice(&data).map_err(|error| anyhow!("manifest is corrupt: {error}"))
    }

    fn save(&self, manifest: &ArchiveManifest) -> Result<()> {
        self.ensure_directories_exist()?;
        let data = serde_json::to_vec_pretty(manifest)?;
        fs::write(&self.manifest_path, data)
            .with_context(|| format!("failed to write {}", self.manifest_path.display()))
    }
}

struct CompressorBackend {
    store: ManifestStore,
}

impl CompressorBackend {
    fn new(base_dir: PathBuf) -> Self {
        Self {
            store: ManifestStore::new(base_dir),
        }
    }

    fn archive(&mut self, app_path: &Path) -> Result<ManagedApp> {
        let app_path = normalized_path(app_path);
        emit_progress(
            &format!("Validating {}", app_path.file_name().unwrap_or_default().to_string_lossy()),
            "Checking the selected application.",
        )?;
        validate_existing_app(&app_path)?;

        let manifest = self.store.load()?;
        if manifest.archived_app_for_original_path(&app_path).is_some() {
            bail!("This app is already archived: {}", app_path.display());
        }

        emit_progress(
            &format!("Measuring {}", app_path.file_name().unwrap_or_default().to_string_lossy()),
            "Calculating the original size.",
        )?;
        let original_size = size_of_item(&app_path)?;
        let app_id = Uuid::new_v4();
        let archive_path = archive_path_for(&self.store.archive_directory, &app_path, app_id)?;
        let display_name = app_path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        let volume_name = app_path
            .file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();

        emit_progress(
            &format!("Compressing {display_name}"),
            "Creating a compressed archive. Large apps can take a while.",
        )?;
        run_command(
            "/usr/bin/hdiutil",
            &[
                "create",
                "-srcfolder",
                app_path.to_str().unwrap_or_default(),
                "-format",
                "ULFO",
                "-volname",
                &volume_name,
                archive_path.to_str().unwrap_or_default(),
            ],
        )?;

        emit_progress(
            &format!("Verifying {display_name}"),
            "Checking that the archive can be read.",
        )?;
        verify_archive(&archive_path)?;
        let archive_size = size_of_item(&archive_path)?;

        let app = ManagedApp {
            id: app_id,
            display_name: display_name.clone(),
            bundle_identifier: bundle_identifier(&app_path)?,
            original_path: app_path.to_string_lossy().to_string(),
            archive_path: archive_path.to_string_lossy().to_string(),
            original_size_bytes: original_size,
            archive_size_bytes: archive_size,
            created_at: iso8601_now(),
            last_restored_at: None,
            status: CompressionStatus::Archived,
        };

        emit_progress(
            &format!("Moving {display_name} to Trash"),
            "The archive is verified. Removing the original app.",
        )?;
        move_to_trash(&app_path)?;

        emit_progress("Updating archive list", "Saving Compressor's manifest.")?;
        let mut manifest = manifest;
        manifest.upsert(app.clone());
        self.store.save(&manifest)?;

        Ok(app)
    }

    fn restore(&mut self, app_id: Uuid) -> Result<()> {
        let mut manifest = self.store.load()?;
        let app = manifest
            .app_by_id(app_id)
            .cloned()
            .with_context(|| format!("app not found: {app_id}"))?;
        let archive_path = PathBuf::from(&app.archive_path);
        let destination_path = PathBuf::from(&app.original_path);

        emit_progress(
            &format!("Checking {}", app.display_name),
            "Confirming the archive is available.",
        )?;
        ensure_archive_exists(&archive_path)?;

        if destination_path.exists() {
            bail!(
                "An app already exists at the restore destination: {}",
                destination_path.display()
            );
        }

        emit_progress("Preparing restore", "Updating Compressor's manifest.")?;
        manifest.update_status(app.id, CompressionStatus::Restoring, None)?;
        self.store.save(&manifest)?;

        emit_progress("Mounting archive", "Opening the compressed disk image.")?;
        let mount_point = attach_archive(&archive_path)?;
        let restore_result = (|| -> Result<()> {
            emit_progress(
                "Finding app",
                &format!("Locating {} in the mounted archive.", app.display_name),
            )?;
            let source_url = app_source_in_mount(&mount_point, &app.display_name)?;

            emit_progress(
                &format!("Restoring {}", app.display_name),
                "Copying the app back to its original location.",
            )?;
            copy_with_ditto(&source_url, &destination_path)?;

            emit_progress("Cleaning up", "Detaching the mounted archive.")?;
            detach_archive(&mount_point)?;
            Ok(())
        })();

        match restore_result {
            Ok(()) => {
                let mut manifest = self.store.load()?;
                manifest.update_status(app.id, CompressionStatus::Restored, Some(iso8601_now()))?;
                self.store.save(&manifest)?;
                Ok(())
            }
            Err(error) => {
                let _ = detach_archive(&mount_point);
                if let Ok(mut manifest) = self.store.load() {
                    let _ = manifest.update_status(app.id, CompressionStatus::Failed, None);
                    let _ = self.store.save(&manifest);
                }
                Err(error)
            }
        }
    }
}

#[derive(Serialize)]
struct ProgressEvent<'a> {
    event: &'static str,
    title: &'a str,
    detail: &'a str,
}

#[derive(Serialize)]
struct ResultEvent<T> {
    event: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    app: Option<T>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SummaryResponse {
    size_bytes: i64,
    formatted: String,
}

#[derive(Serialize)]
struct ListResponse {
    apps: Vec<ManagedApp>,
}

fn emit_progress(title: &str, detail: &str) -> Result<()> {
    write_json_line(&ProgressEvent {
        event: "progress",
        title,
        detail,
    })
}

fn emit_result<T: Serialize>(app: Option<T>) -> Result<()> {
    write_json_line(&ResultEvent {
        event: "result",
        app,
    })
}

fn write_json<T: Serialize>(value: &T) -> Result<()> {
    println!("{}", serde_json::to_string(value)?);
    Ok(())
}

fn write_json_line<T: Serialize>(value: &T) -> Result<()> {
    println!("{}", serde_json::to_string(value)?);
    Ok(())
}

fn required_value(args: &mut impl Iterator<Item = String>, name: &str) -> Result<String> {
    let next = args.next().with_context(|| format!("missing {name}"))?;
    if next != name {
        bail!("expected {name}, got {next}");
    }
    args.next().with_context(|| format!("missing value for {name}"))
}

fn next_arg(iter: &mut impl Iterator<Item = String>, name: &str) -> Result<String> {
    iter.next().with_context(|| format!("missing value for {name}"))
}

fn default_base_directory() -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("Compressor")
}

fn normalized_path(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn validate_existing_app(path: &Path) -> Result<()> {
    validate_app_path(path)?;
    if !path.exists() || !path.is_dir() {
        bail!("The app no longer exists: {}", path.display());
    }
    Ok(())
}

fn validate_app_path(path: &Path) -> Result<()> {
    let path_string = path.to_string_lossy();
    if path.extension().and_then(|value| value.to_str()).unwrap_or_default().to_lowercase() != "app"
    {
        bail!("Select a valid macOS application: {path_string}");
    }
    if path_string == "/System/Applications" || path_string.starts_with("/System/Applications/") {
        bail!("System apps cannot be compressed: {path_string}");
    }
    Ok(())
}

fn archive_path_for(archive_directory: &Path, app_path: &Path, id: Uuid) -> Result<PathBuf> {
    fs::create_dir_all(archive_directory)?;
    let app_name = app_path.file_stem().unwrap_or_default().to_string_lossy();
    let safe_name = sanitize_archive_base_name(&app_name);
    Ok(archive_directory.join(format!("{safe_name}-{id}.dmg")))
}

fn sanitize_archive_base_name(name: &str) -> String {
    let sanitized: String = name
        .chars()
        .map(|character| {
            if character.is_alphanumeric() || [' ', '.', '_', '-'].contains(&character) {
                character
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim()
        .to_string();
    if sanitized.is_empty() {
        "App".to_string()
    } else {
        sanitized
    }
}

fn bundle_identifier(app_path: &Path) -> Result<Option<String>> {
    let info_path = app_path.join("Contents").join("Info.plist");
    if !info_path.exists() {
        return Ok(None);
    }

    let output = run_command(
        "/usr/bin/defaults",
        &["read", info_path.to_str().unwrap_or_default(), "CFBundleIdentifier"],
    );
    match output {
        Ok(result) => {
            let value = String::from_utf8_lossy(&result.stdout).trim().to_string();
            if value.is_empty() {
                Ok(None)
            } else {
                Ok(Some(value))
            }
        }
        Err(_) => Ok(None),
    }
}

fn verify_archive(archive_path: &Path) -> Result<()> {
    ensure_archive_exists(archive_path)?;
    run_command(
        "/usr/bin/hdiutil",
        &["verify", archive_path.to_str().unwrap_or_default()],
    )?;
    Ok(())
}

fn ensure_archive_exists(archive_path: &Path) -> Result<()> {
    if !archive_path.exists() {
        bail!("The archive is missing: {}", archive_path.display());
    }
    Ok(())
}

fn size_of_item(path: &Path) -> Result<i64> {
    if path.is_dir() {
        let output = run_command("/usr/bin/du", &["-sk", path.to_str().unwrap_or_default()])?;
        let stdout = String::from_utf8_lossy(&output.stdout);
        let kilobytes = stdout
            .split_whitespace()
            .next()
            .and_then(|value| value.parse::<i64>().ok())
            .unwrap_or(0);
        Ok(kilobytes * 1024)
    } else {
        Ok(fs::metadata(path)?.len() as i64)
    }
}

fn format_bytes(bytes: i64) -> String {
    const UNITS: [&str; 5] = ["bytes", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }

    if unit == 0 {
        format!("{bytes} {}", UNITS[unit])
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

fn run_command(executable: &str, arguments: &[&str]) -> Result<Output> {
    let output = Command::new(executable)
        .args(arguments)
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("failed to launch {executable}"))?;

    if output.status.success() {
        Ok(output)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let message = [stdout, stderr]
            .into_iter()
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        bail!(
            "{} failed with status {}: {}",
            executable,
            output.status.code().unwrap_or(-1),
            message
        );
    }
}

fn can_write_parent(path: &Path) -> bool {
    let parent = path.parent().unwrap_or_else(|| Path::new("/"));
    let Ok(parent_c_string) = CString::new(parent.to_string_lossy().as_bytes()) else {
        return false;
    };
    unsafe { access(parent_c_string.as_ptr(), W_OK) == 0 }
}

fn move_to_trash(path: &Path) -> Result<()> {
    let trash_path = unique_trash_path(path);
    if can_write_parent(path) {
        if run_command(
            "/bin/mv",
            &[path.to_str().unwrap_or_default(), trash_path.to_str().unwrap_or_default()],
        )
        .is_ok()
        {
            return Ok(());
        }
    }

    run_privileged_shell_command(&shell_command([
        "/bin/mv",
        path.to_str().unwrap_or_default(),
        trash_path.to_str().unwrap_or_default(),
    ]))
    .map_err(|error| anyhow!("The app could not be moved to Trash: {error}"))
}

fn copy_with_ditto(source: &Path, destination: &Path) -> Result<()> {
    if can_write_parent(destination) {
        run_command(
            "/usr/bin/ditto",
            &[
                source.to_str().unwrap_or_default(),
                destination.to_str().unwrap_or_default(),
            ],
        )?;
        return Ok(());
    }

    run_privileged_shell_command(&shell_command([
        "/usr/bin/ditto",
        source.to_str().unwrap_or_default(),
        destination.to_str().unwrap_or_default(),
    ]))
}

fn run_privileged_shell_command(command: &str) -> Result<()> {
    let script = format!(
        "do shell script {} with administrator privileges",
        apple_script_string(command)
    );
    run_command("/usr/bin/osascript", &["-e", &script])?;
    Ok(())
}

fn shell_command<const N: usize>(arguments: [&str; N]) -> String {
    arguments
        .iter()
        .map(|argument| shell_quote(argument))
        .collect::<Vec<_>>()
        .join(" ")
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn apple_script_string(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('\"', "\\\""))
}

fn unique_trash_path(path: &Path) -> PathBuf {
    let home = env::var("HOME").unwrap_or_else(|_| ".".into());
    let trash_directory = PathBuf::from(home).join(".Trash");
    let base_name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
    let candidate = trash_directory.join(&base_name);
    if !candidate.exists() {
        return candidate;
    }

    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    trash_directory.join(format!("{base_name}-{stamp}"))
}

fn attach_archive(archive_path: &Path) -> Result<PathBuf> {
    let output = run_command(
        "/usr/bin/hdiutil",
        &[
            "attach",
            "-nobrowse",
            "-readonly",
            "-plist",
            archive_path.to_str().unwrap_or_default(),
        ],
    )?;
    let plist = String::from_utf8_lossy(&output.stdout);
    parse_mount_point(&plist)
        .map(PathBuf::from)
        .with_context(|| format!("The archive mounted, but no mount point was reported: {}", archive_path.display()))
}

fn detach_archive(mount_point: &Path) -> Result<()> {
    run_command(
        "/usr/bin/hdiutil",
        &["detach", mount_point.to_str().unwrap_or_default()],
    )?;
    Ok(())
}

fn parse_mount_point(plist: &str) -> Option<String> {
    let marker = "<key>mount-point</key>";
    let start = plist.find(marker)?;
    let remaining = &plist[start + marker.len()..];
    let string_start = remaining.find("<string>")?;
    let after_start = &remaining[string_start + "<string>".len()..];
    let string_end = after_start.find("</string>")?;
    Some(after_start[..string_end].to_string())
}

fn app_source_in_mount(mount_point: &Path, display_name: &str) -> Result<PathBuf> {
    let preferred = mount_point.join(display_name);
    if preferred.exists() {
        return Ok(preferred);
    }

    let direct_info_plist = mount_point.join("Contents").join("Info.plist");
    if direct_info_plist.exists() {
        return Ok(mount_point.to_path_buf());
    }

    let entries = fs::read_dir(mount_point)?;
    for entry in entries {
        let path = entry?.path();
        if path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .eq_ignore_ascii_case("app")
        {
            return Ok(path);
        }
    }

    bail!(
        "No app bundle was found in the mounted archive: {}",
        mount_point.display()
    )
}

fn iso8601_now() -> String {
    let output = Command::new("/bin/date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output();
    match output {
        Ok(result) if result.status.success() => String::from_utf8_lossy(&result.stdout).trim().to_string(),
        _ => "1970-01-01T00:00:00Z".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitizes_archive_names() {
        assert_eq!(sanitize_archive_base_name("My App"), "My App");
        assert_eq!(sanitize_archive_base_name("My/App"), "My-App");
    }

    #[test]
    fn parses_mount_point_from_plist_output() {
        let plist = r#"
        <plist version="1.0">
          <array>
            <dict>
              <key>mount-point</key>
              <string>/Volumes/Foo</string>
            </dict>
          </array>
        </plist>
        "#;
        assert_eq!(parse_mount_point(plist), Some("/Volumes/Foo".to_string()));
    }

    #[test]
    fn shell_quote_matches_expected_escaping() {
        assert_eq!(
            shell_quote("/Applications/O'Hare App.app"),
            "'/Applications/O'\\''Hare App.app'"
        );
    }
}
