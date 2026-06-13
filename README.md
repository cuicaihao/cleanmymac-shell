# mac-cleaner: Safe, Review-First macOS Cleanup

![mac-cleaner](mac-cleaner.webp)

`mac-cleaner` is a conservative macOS cleanup CLI for users who want a cautious cleanup plan before deleting anything.

It scans old caches, logs, temporary files, developer caches, and opt-in cleanup areas such as Downloads, Trash, Docker, and Xcode archives.

The default is safe: it scans only, prints a review plan, and writes a commented cleanup script. Execute mode never permanently deletes files; approved items are moved into a timestamped recovery folder under `~/.Trash`.

## Install

Install the latest GitHub Release:

```bash
curl -L https://github.com/cuicaihao/cleanmymac-shell/releases/latest/download/mac-cleaner.tar.gz -o mac-cleaner.tar.gz
tar -xzf mac-cleaner.tar.gz
chmod +x mac-cleaner
mkdir -p "$HOME/.local/bin"
mv mac-cleaner "$HOME/.local/bin/mac-cleaner"
```

Or install from a source checkout:

```bash
make install PREFIX="$HOME/.local"
```

Make sure `$HOME/.local/bin` is on your `PATH`.

## Quick Start

Always start with a dry run to preview candidates:

```bash
mac-cleaner --verbose
```

Dry-run mode prints a beautifully formatted summary and hierarchy tree of candidates, then writes a commented `clean.sh` review script:

```text
✨ mac-cleaner v1.2.0
────────────────────────────────────────────────────────
Mode:          Dry Run (Safe mode, preview only)
Log File:      ~/.local/state/mac-cleaner/mac-cleaner.log
Age Threshold: > 14 day(s)
────────────────────────────────────────────────────────

== Cleanup plan ==
❯ Old user logs [low risk]
  Note: Logs are usually safe to move, but can help investigate older issues.
  ├── 8.0 KiB     (1 item)  ~/Library/Logs/PhotosUpgrade.aapbz
  ├── 20.0 KiB    (6 items)  ~/Library/Logs/iStat Menus 7
  └── Total: 28.0 KiB  (7 items)

❯ User cache contents older than threshold [low risk]
  Note: Usually safe to regenerate. Apps may rebuild these files later.
  ├── empty       (1 item)  ~/.cache/antigravity
  ├── 2.0 MiB     (1 item)  ~/.cache/gitstatus
  ├── 75.6 MiB    (4 items)  ~/Library/Application Support/Code/CachedData
  ├── 48.0 KiB    (1 item)  ~/Library/Caches/GameKit
  └── Total: 77.6 MiB  (11 items)

❯ Crash reports older than threshold [medium risk]
  Note: Useful for troubleshooting older app crashes. Safe to move after review.
  ├── 16.0 KiB    (2 items)  ~/Library/Logs/DiagnosticReports
  └── Total: 16.0 KiB  (2 items)

❯ Developer caches [medium risk]
  Note: Usually safe to regenerate, but the next build, package install, or simulator launch may be slower.
  ├── 237.9 MiB   (1 item)  ~/.npm/_cacache
  ├── 55.2 MiB    (1 item)  ~/Library/Caches/Homebrew
  ├── 111.0 MiB   (1 item)  ~/Library/Caches/go-build
  ├── 14.9 MiB    (1 item)  ~/Library/Caches/pip
  ├── empty       (1 item)  ~/Library/Developer/CoreSimulator
  └── Total: 419.0 MiB  (5 items)

Dry-run cleanup script written to: clean.sh
All rm -rf lines are commented. Review, edit, and run it yourself only if you are confident.

== Skipped optional groups ==
  Old Xcode archives: skipped. Use --include-xcode-archives to include Organizer archives older than the threshold.
  Downloads older than threshold: skipped. Use --include-downloads to include ~/Downloads.
  Trash: skipped. Use --empty-trash to include ~/.Trash.
  Docker cleanup: skipped. Use --include-docker to prune Docker caches and stopped resources.

📊 Final Summary
────────────────────────────────────────────────────────
Can be reclaimed:          25 items      496.7 MiB
Actually moved:             0 items            0 B
────────────────────────────────────────────────────────

Review the paths above. If they look safe, run:
  ./mac-cleaner.sh --execute
```

For a full path-by-path review of everything found:

```bash
mac-cleaner --show-files
```

For a guided setup flow:

```bash
mac-cleaner --interactive
```

To find large personal files before deciding what to move:

```bash
mac-cleaner large-files --min-size 500M --older-than 30
```

When you are ready to execute the cleanup:

```bash
mac-cleaner --execute
```

Execute mode shows each group again, prints its specific files, and prompts for your approval (`y/N/q`). Approved files are safely moved to `~/.Trash/mac-cleaner-*` (they are not permanently deleted).

## Common Options

```bash
mac-cleaner --verbose                       # Grouped overview of folders and sizes (tree style)
mac-cleaner --show-files                     # Print every single matched file path
mac-cleaner --interactive                  # Guided interactive setup
mac-cleaner --no-color                     # Disable colorized console output
mac-cleaner --dry-run --older-than 30 --include-downloads --verbose
mac-cleaner large-files --min-size 1G --older-than 90
mac-cleaner dev-clean --verbose
mac-cleaner dev-clean --include-brew
mac-cleaner applications --output apps.md
mac-cleaner startup --output startup.md
mac-cleaner uninstall /Applications/AppName.app
mac-cleaner --clean-log                    # Clear script's persistent log file
mac-cleaner --execute --empty-trash        # Execute and empty ~/.Trash
mac-cleaner --execute --include-docker      # Run Docker build/system prunes
mac-cleaner --execute --include-xcode-archives
```

## What It Cleans

- Old user cache contents, including common browser and editor caches.
- Old files in `~/Library/Logs`.
- Old crash reports.
- Old temporary files from the current macOS temp directory.
- Developer caches such as Xcode DerivedData, Homebrew, npm, pip, Cargo, Gradle, and simulator caches.
- Optional old files in `~/Downloads`.
- Optional `~/.Trash` contents.
- Optional Docker builder and system prune.
- Optional old Xcode Organizer archives.

## Large Files

The `large-files` command scans common user content folders (`Desktop`, `Documents`, `Downloads`, `Movies`, `Music`, and `Pictures`) for large files older than the age threshold.

```bash
mac-cleaner large-files --min-size 500M --older-than 30
mac-cleaner large-files --execute
```

Large files are treated as high-risk personal data. Dry-run mode lists matching files by size, and execute mode asks before moving each file to the recovery folder.

## Developer Tool Cleanup

The `dev-clean` command starts with editor extension cleanup. It scans VS Code and Cursor extension directories, keeps the most recently modified folder for each extension, and lists older versions for review. It also prints a report-only review of installed iOS Simulator runtimes. Homebrew cleanup review is opt-in with `--include-brew`, which runs `brew cleanup -n` only.

```bash
mac-cleaner dev-clean --verbose
mac-cleaner dev-clean --include-brew
mac-cleaner dev-clean --execute
```

Old extension versions are treated as medium risk and moved to the recovery folder in execute mode. Homebrew cleanup and simulator runtimes remain report-only; this command does not run permanent `brew cleanup` or remove simulator runtimes.

## Applications Report

The `applications` command inventories installed apps before you decide what to inspect or remove. It scans `/Applications` and `~/Applications` by default, reports size and bundle metadata, and can write a Markdown report for review.

```bash
mac-cleaner applications
mac-cleaner applications --output apps.md
mac-cleaner applications --stale-days 180 --min-size 1G
```

The report includes app name, version, apparent size, disk usage, installed date, last opened date when Spotlight metadata is available, modified date, Bundle ID, notes, an inspect command, and path. Apparent size is the sum of file content sizes; disk usage is the on-disk footprint and is used for large-app notes. Notes can flag stale apps, large apps, unknown last-opened metadata, and Apple/system apps. The Markdown report also includes sections for all apps, possibly stale apps, largest apps, and apps with unknown last-opened metadata. Use `--app-root PATH` to scan a custom app directory root.

## Uninstall Inspection

The `uninstall` command is inspect-only. It reads the app bundle's `Info.plist`, reports the app name and Bundle ID, then lists likely related files from user Library locations.

```bash
mac-cleaner uninstall /Applications/AppName.app
```

It reports matches such as application support folders, caches, preferences, containers, group containers, logs, and the app bundle itself. Each match includes the reason it was selected, such as Bundle ID or app name. It does not move files yet; `--execute` is intentionally refused until the matching rules are proven conservative.

## Startup Items Report

The `startup` command is report-only. It lists user LaunchAgents, global LaunchAgents, LaunchDaemons, and Login Items when they can be read.

```bash
mac-cleaner startup
mac-cleaner startup --output startup.md
```

The report includes scope, label, program, `RunAtLoad`, `KeepAlive`, disabled state when available, modified date, size, notes, and path. Notes can flag auto-start, keepalive, system-wide, Apple/system, third-party, recently modified, and missing program paths. The Markdown report is split into all items, user startup items, system-wide items, auto-start/KeepAlive items, and missing program paths. It does not disable or remove startup items.

## Review Script

Dry-run mode writes a `clean.sh` review script with commented commands. Non-destructive metadata, titles, and sizes are prefixed with a double-hash `##`, while actual destructive command lines are commented with a single `#`:

```bash
## == User cache contents older than threshold [low risk] ==
## Size: 4.0 KB
# rm -rf -- /Users/you/Library/Caches/example
```

This layout allows you to open `clean.sh` in any modern editor (like VS Code, Cursor, Xcode), select the blocks of files you approve, and press **Cmd + /** (or **Ctrl + /**) to quickly uncomment only the `rm -rf` command lines, keeping titles and size warnings safely commented.

Nothing in this file runs until you review and execute it. Note that the built-in `--execute` mode is safer than running the generated script because it moves files to Trash instead of immediately deleting them.

## Configuration

You can persist your favorite options in `~/.config/mac-cleaner/config`. A legacy `~/.mac-cleaner.rc` file is also supported.

Configuration is applied in this order:

```text
built-in defaults < config file < command-line flags
```

Start from the example config:

```bash
mkdir -p ~/.config/mac-cleaner
cp examples/mac-cleaner.config.example ~/.config/mac-cleaner/config
```

Example config:

```bash
# Use 1 to enable an option and 0 to disable it.
OLDER_THAN_DAYS=30
VERBOSE=1
SHOW_FILES=0

INCLUDE_DOWNLOADS=0
INCLUDE_DOCKER=0
INCLUDE_XCODE_ARCHIVES=0
EMPTY_TRASH=0
```

The config file is loaded as a shell fragment. Do not paste or use config files from sources you do not trust.

## Logging

The script maintains a persistent log at `${XDG_STATE_HOME:-$HOME/.local/state}/mac-cleaner/mac-cleaner.log`.

The persistent log is privacy-aware: exact local paths are shown in terminal output for review, but path details are omitted from the saved log.

To empty the log without running a cleanup scan:

```bash
mac-cleaner --clean-log
```

## Safety Notes

- The script does not scan protected system folders.
- It does not require administrator privileges.
- `~/Downloads`, `~/.Trash`, Docker cleanup, and Xcode Organizer archives are opt-in.
- Execute mode moves files to `~/.Trash/mac-cleaner-*` first instead of permanently deleting them.
- Execute mode requires typing `y` before each group is moved; the default is No. Type `q` to stop reviewing remaining groups.
- `--yes` can skip low/medium-risk prompts in trusted automation. High-risk groups still ask.
- Docker cleanup is separate and permanent. In interactive execute mode, it requires typing `PRUNE`.
- Be extra careful with `--include-downloads`, `--empty-trash`, `--include-docker`, and `--include-xcode-archives`.
- Xcode Organizer archives can contain release builds, dSYMs, and submission history. Review dry-run output before including them.
- Always run a dry run first and read the output before using `--execute`.

## Development

For checks, versioning, and release steps, see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT License. See [LICENSE](LICENSE).
