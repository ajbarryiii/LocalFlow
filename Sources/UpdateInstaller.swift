import Foundation

/// Why the running app cannot replace itself where it is.
enum UpdateInstallLocationProblem: Equatable {
    /// macOS App Translocation runs the app from a random read-only path.
    case translocated
    /// For example the mounted disk image the app was downloaded on.
    case readOnlyVolume
    /// The user cannot rename items in the folder that holds the app.
    case folderNotWritable
}

/// Checks, before downloading and before quitting, that the app bundle can be
/// swapped for a new one in place.
struct UpdateInstallLocation: Sendable {
    var isOnReadOnlyVolume: @Sendable (URL) -> Bool
    var isWritableDirectory: @Sendable (URL) -> Bool

    static let live = UpdateInstallLocation(
        isOnReadOnlyVolume: { url in
            (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        },
        isWritableDirectory: { url in
            FileManager.default.isWritableFile(atPath: url.path)
        }
    )

    func problem(forAppAt appURL: URL) -> UpdateInstallLocationProblem? {
        let app = appURL.standardizedFileURL
        if app.pathComponents.contains("AppTranslocation") {
            return .translocated
        }
        if isOnReadOnlyVolume(app) {
            return .readOnlyVolume
        }
        if !isWritableDirectory(app.deletingLastPathComponent()) {
            return .folderNotWritable
        }
        return nil
    }

    static func message(for problem: UpdateInstallLocationProblem) -> String {
        let name = AppName.displayName
        let move = "Quit \(name), move it to your Applications folder, open it from there, and try again."
        switch problem {
        case .translocated:
            return "\(name) can't update itself because macOS is running it from a temporary location. \(move)"
        case .readOnlyVolume:
            return "\(name) can't update itself because it is running from a read-only disk, such as the disk image it came on. \(move)"
        case .folderNotWritable:
            return "\(name) can't update itself because you don't have permission to change the folder it is in. \(move)"
        }
    }
}

/// The detached script that swaps the installed app for the staged update
/// once the running app has quit, and relaunches whichever app ends up
/// installed.
///
/// The staged app and the backup live in the installed app's folder, so
/// every move is a rename on one volume that happens completely or not at
/// all; the script refuses any other layout.
///
/// Exit status 0 means the new app is installed; relaunching it and cleaning
/// up are best effort and never undo the install. Any other status means the
/// new app is not installed: the current app is left in place (or put back)
/// and relaunched.
struct UpdateReplacement {
    static let shellURL = URL(fileURLWithPath: "/bin/bash")
    static let defaultOpenCommand = "/usr/bin/open"

    let waitingForProcessID: Int32
    let currentApp: URL
    let stagedApp: URL
    let stagingDirectory: URL
    let backup: URL
    let openCommand: String

    init(
        waitingForProcessID: Int32,
        currentApp: URL,
        stagedApp: URL,
        stagingDirectory: URL,
        backup: URL? = nil,
        openCommand: String = UpdateReplacement.defaultOpenCommand
    ) {
        self.waitingForProcessID = waitingForProcessID
        self.currentApp = currentApp
        self.stagedApp = stagedApp
        self.stagingDirectory = stagingDirectory
        self.backup = backup ?? Self.backupURL(for: currentApp)
        self.openCommand = openCommand
    }

    /// A new hidden folder next to the installed app that holds the verified
    /// update until it is renamed into place.
    static func stagingDirectoryURL(nextTo currentApp: URL) -> URL {
        currentApp.deletingLastPathComponent()
            .appendingPathComponent(".\(baseName(of: currentApp))-update-\(UUID().uuidString)", isDirectory: true)
    }

    /// A new hidden path next to the installed app for the current app while
    /// the new one moves in. It is unique per update so a leftover from an
    /// interrupted update is never reused, and it keeps the `.app` extension
    /// so the old app can still be launched from it if it cannot be put back.
    static func backupURL(for currentApp: URL) -> URL {
        currentApp.deletingLastPathComponent()
            .appendingPathComponent(".\(baseName(of: currentApp))-update-backup-\(UUID().uuidString).app", isDirectory: true)
    }

    private static func baseName(of app: URL) -> String {
        app.deletingPathExtension().lastPathComponent
    }

    /// Arguments for `shellURL`. Paths are passed as positional parameters,
    /// never interpolated into the script.
    var arguments: [String] {
        ["-c", Self.script, "localflow-update",
         String(waitingForProcessID),
         currentApp.path,
         stagedApp.path,
         stagingDirectory.path,
         backup.path,
         openCommand]
    }

    // `mv src dst` moves src *into* dst when dst is an existing directory, so
    // every move first checks that its destination is free.
    static let script = """
    pid=$1 app=$2 staged=$3 staging=$4 backup=$5 opener=$6

    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done

    occupied() { [ -e "$1" ] || [ -L "$1" ]; }
    relaunch() { "$opener" "$1" >/dev/null 2>&1; }
    keep_current_app() { rm -rf "$staging" 2>/dev/null; relaunch "$app"; exit 1; }

    # 0. Only renames inside the app's folder: a move to another volume is a
    #    copy, which can fail halfway or fail after a complete copy.
    folder=$(dirname "$app")
    if [ "$(dirname "$staged")" != "$staging" ] || [ "$(dirname "$staging")" != "$folder" ] \\
        || [ "$(dirname "$backup")" != "$folder" ]; then
        relaunch "$app"
        exit 1
    fi

    # 1. Move the current app aside.
    [ -d "$staged" ] && [ -d "$app" ] || keep_current_app
    occupied "$backup" && keep_current_app
    mv "$app" "$backup" || keep_current_app

    # 2. Move the new app into place. A failed rename leaves nothing behind.
    installed=0
    if ! occupied "$app" && mv "$staged" "$app"; then
        installed=1
    fi

    if [ "$installed" -ne 1 ]; then
        # The new app never got into place: put the current app back.
        if ! occupied "$app" && mv "$backup" "$app"; then
            keep_current_app
        fi
        # It cannot go back without nesting it in whatever took its place,
        # so run it from the backup rather than leave nothing running.
        rm -rf "$staging" 2>/dev/null
        relaunch "$backup"
        exit 1
    fi

    # 3. The new app is installed. Nothing below may undo that.
    relaunch "$app"
    rm -rf "$backup" "$staging" 2>/dev/null
    exit 0
    """
}
