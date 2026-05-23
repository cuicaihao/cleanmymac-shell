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

Always start with a dry run:

```bash
mac-cleaner --verbose
```

Dry-run mode:

- Prints a cleanup plan grouped by risk and category.
- Shows how many items and how much space could be cleaned.
- Writes a commented `clean.sh` review script.

For a full file-by-file review:

```bash
mac-cleaner --show-files
```

For a guided flow:

```bash
mac-cleaner --interactive
```

When the plan looks safe:

```bash
mac-cleaner --execute
```

Execute mode shows each group again, asks `y/N/q`, and defaults to No. Approved files are moved to `~/.Trash/mac-cleaner-*`, not permanently deleted.

## Common Options

```bash
mac-cleaner --verbose
mac-cleaner --show-files
mac-cleaner --interactive
mac-cleaner --dry-run --older-than 30 --include-downloads --verbose
mac-cleaner --clean-log
mac-cleaner --execute --empty-trash
mac-cleaner --execute --include-docker
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

## Review Script

Dry-run mode writes a review script with commented commands:

```bash
# == User cache contents older than threshold [low risk] ==
# Size: 4.0 KB
# rm -rf -- /Users/you/Library/Caches/example
```

Nothing in this file runs until you edit it yourself. The built-in `--execute` mode is safer than running the generated script because it moves files to Trash first.

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
