# Future Development Plan - CLI Mac Cleaner

This document outlines future feature enhancements and design improvements for `mac-cleaner.sh`, drawing inspiration from key paradigms in **CleanMyMac.app** while maintaining our design philosophy: a single-file, transparent, lightweight, and developer-centric Command Line Interface (CLI).

---

## 🚀 1. Intelligent App Uninstaller (`uninstall`)

**Objective**: Standard macOS drag-to-Trash leaves configuration files, container caches, and system daemons behind. We can provide a clean app removal mechanism.

### Key Implementation Details
- Command structure: `./mac-cleaner.sh --uninstall /Applications/AppName.app`
- Read the app's `Info.plist` to fetch its unique `CFBundleIdentifier` (Bundle ID).
- Scan and aggregate size for:
  - `~/Library/Application Support/<AppName>` & `~/Library/Application Support/<BundleID>`
  - `~/Library/Caches/<BundleID>`
  - `~/Library/Preferences/<BundleID>.plist`
  - `~/Library/Containers/<BundleID>` (Sandbox containers)
  - `~/Library/Group Containers/<SharedGroupID>`
  - `~/Library/Logs/<AppName>` & `~/Library/Logs/<BundleID>`
- Move the App package itself along with all collected directory folders into the recovery Trash quarantine folder.

---

## ⚡ 2. System Maintenance Sub-command (`maintain`)

**Objective**: Expose native macOS diagnostic and optimization utilities that traditionally require complex shell scripting under a single execution gate.

### Key Maintenance Tasks
- **RAM Memory Flushing**: Trigger `sudo purge` to reclaim inactive RAM and flush system disk caches safely.
- **DNS Cache Purging**: Flush the system resolver cache to resolve connectivity or DNS resolution hangs:
  ```bash
  sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
  ```
- **Spotlight Search Reindexing**: Wipe and rebuild the local file metadata store to resolve Spotlight freezes:
  ```bash
  sudo mdutil -E /
  ```
- **Launch Services Reset**: Rebuild the app association and launch services database if default apps get mixed up.

---

## 🔍 3. Large & Old Files Scanner (`large-files`)

**Objective**: Scan user home subdirectories to identify massive user data archives, virtual machines, or local videos that are consuming space.

### Scan Scope & Filtering
- Exclude core system library directories (`~/Library`, `~/.Trash`, `/System`).
- Let the user customize size and age threshold flags:
  ```bash
  ./mac-cleaner.sh large-files --min-size 100M --older-than 30
  ```
- Output a sorted flat tree list of files descending by file size, allowing the user to select specific files to quarantine.

---

## 🚦 4. Startup Items & Daemon Manager (`startup`)

**Objective**: Let users inspect and optionally disable background launch files that run automatically during system start, which often slow down booting.

### Location Targets
- **LaunchAgents (User context)**: `~/Library/LaunchAgents/`
- **LaunchAgents (Global context)**: `/Library/LaunchAgents/`
- **LaunchDaemons (System context)**: `/Library/LaunchDaemons/`
- **Login Items (User Profile)**: Query and list items added via System Settings Login Items using `osascript`.

---

## 📦 5. Development Tool Extension Cleaner (`dev-clean`)

**Objective**: Developer tools (like VS Code, Cursor, Xcode) leave massive duplicate files. We can prune older inactive tool extensions.

### Targets
- **VS Code & Cursor Extensions**: Clean up outdated versions of active plugins inside `~/.vscode/extensions/` and `~/.cursor/extensions/`. (When plugins update, VS Code retains older folder versions on disk).
- **Homebrew Old Caches**: Automatically trigger `brew cleanup` under user approval to purge outdated formula bottles.
- **iOS Simulator Runtimes**: Identify and list obsolete iOS version simulator runtime images located in `/Library/Developer/CoreSimulator/Profiles/Runtimes/` for safe deletion.
