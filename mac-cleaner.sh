#!/usr/bin/env bash
set -euo pipefail

VERSION="1.2.0"
COMMAND="scan"
COMMAND_SET=0
UNINSTALL_TARGET=""
REPORT_OUTPUT=""
APPLICATION_ROOTS=()
STALE_DAYS=180
STARTUP_REPORT_FILE=""
DRY_RUN=1
OLDER_THAN_DAYS=14
MIN_SIZE_BYTES=$((100 * 1024 * 1024))
INCLUDE_DOWNLOADS=0
INCLUDE_DOCKER=0
INCLUDE_BREW=0
INCLUDE_XCODE_ARCHIVES=0
EMPTY_TRASH=0
INTERACTIVE=0
VERBOSE=0
SHOW_FILES=0
YES=0
CLEAN_LOG=0
ABORT_EXECUTION=0
COLOR_DISABLED=0
SCAN_SECONDS=0
SCAN_ACTIVITY_PID=""

HOME_DIR="${HOME}"

# Color codes (ANSI escape sequences, empty by default)
COLOR_RESET=""
COLOR_BOLD=""
COLOR_DIM=""
COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_BLUE=""
COLOR_MAGENTA=""
COLOR_CYAN=""

enable_color() {
  COLOR_RESET=$'\e[0m'
  COLOR_BOLD=$'\e[1m'
  COLOR_DIM=$'\e[90m'     # Dim (Gray)
  COLOR_RED=$'\e[31m'
  COLOR_GREEN=$'\e[32m'
  COLOR_YELLOW=$'\e[33m'
  COLOR_BLUE=$'\e[34m'
  COLOR_MAGENTA=$'\e[35m'
  COLOR_CYAN=$'\e[36m'
}

disable_color() {
  COLOR_RESET=""
  COLOR_BOLD=""
  COLOR_DIM=""
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_MAGENTA=""
  COLOR_CYAN=""
}

# Runtime state. These are intentionally not user-configurable.
TOTAL_BYTES=0
ITEMS_FOUND=0
MOVED_BYTES=0
ITEMS_MOVED=0
PLAN_FILE=""
SKIPPED_FILE=""
APP_REPORT_FILE=""
INSPECTION_META_FILE=""
CONFIG_FILE="${HOME}/.mac-cleaner.rc"
XDG_CONFIG_FILE="${HOME}/.config/mac-cleaner/config"
LOG_FILE="" # Set in main
QUARANTINE_ROOT=""
CLEAN_SCRIPT_FILE="clean.sh"

# User config is a trusted shell fragment. CLI flags are parsed after config so
# one-off command-line choices override persistent preferences.
load_config() {
  local f
  for f in "$XDG_CONFIG_FILE" "$CONFIG_FILE"; do
    if [[ -f "$f" ]]; then
      # shellcheck disable=SC1090
      source "$f"
      return
    fi
  done
}

# User-visible help text. Keep this aligned with README examples.
usage() {
  cat <<EOF
${COLOR_BOLD}mac-cleaner${COLOR_RESET} - conservative macOS cleanup helper

${COLOR_BOLD}Usage:${COLOR_RESET}
  ./mac-cleaner.sh [options]
  ./mac-cleaner.sh scan [options]
  ./mac-cleaner.sh large-files [options]
  ./mac-cleaner.sh dev-clean [options]
  ./mac-cleaner.sh applications [options]
  ./mac-cleaner.sh startup [options]
  ./mac-cleaner.sh uninstall /Applications/AppName.app

${COLOR_BOLD}Default behavior:${COLOR_RESET}
  Scans first, builds a sorted cleanup plan, and prints what can be cleaned.

${COLOR_BOLD}Commands:${COLOR_RESET}
  scan                    Run the default cache, log, temp, and developer cleanup scan.
  large-files             Find large user files older than the age threshold.
  dev-clean               Find old developer tool artifacts such as editor extensions.
  applications            Inventory installed apps and optionally write Markdown.
  startup                 Inventory startup items. Report-only for now.
  uninstall               Inspect app-related files. Report-only for now.

${COLOR_BOLD}Modes:${COLOR_RESET}
  -e, --execute             Move selected files to a recovery folder in ~/.Trash.
  -d, --dry-run             Preview only. This is the default.
                            Also writes a commented clean.sh review script.
  -i, --interactive         Guided setup and review prompts.

${COLOR_BOLD}Scan Filters:${COLOR_RESET}
  -o, --older-than DAYS     Only include files older than DAYS. [default: 14]
  --min-size SIZE           Minimum size such as 100M or 1G. [default: 100M]
  --stale-days DAYS         applications only. Flag apps not opened in DAYS. [default: 180]
  --app-root PATH           applications only. Scan an app directory root. Repeatable.
  --include-downloads       Include old files from ~/Downloads.
  --include-xcode-archives  Include old Xcode Organizer archives.
  --empty-trash             Include ~/.Trash contents in the scan.
  --include-docker          Include Docker prune review if Docker is installed.
  --include-brew            dev-clean only. Run Homebrew cleanup dry-run review.

${COLOR_BOLD}Output & Configuration:${COLOR_RESET}
  -v, --verbose             Print compact grouped details (tree layout).
  -s, --show-files          Print every matched file path.
  --output FILE             applications/startup only. Write a Markdown report.
  -n, --no-color            Disable colorized console output.
  -y, --yes                 Skip low/medium-risk prompts. High-risk groups still ask.
  --clean-log               Empty the mac-cleaner log file and exit.
  -V, --version             Print version.
  -h, --help                Show this help.

${COLOR_BOLD}Examples:${COLOR_RESET}
  ./mac-cleaner.sh
  ./mac-cleaner.sh large-files --min-size 500M --older-than 30
  ./mac-cleaner.sh dev-clean --verbose
  ./mac-cleaner.sh dev-clean --include-brew
  ./mac-cleaner.sh applications --output apps.md
  ./mac-cleaner.sh startup --output startup.md
  ./mac-cleaner.sh uninstall /Applications/AppName.app
  ./mac-cleaner.sh -o 30 --include-downloads
  ./mac-cleaner.sh -i
  ./mac-cleaner.sh -e --empty-trash

${COLOR_BOLD}Notes:${COLOR_RESET}
  This script avoids protected system folders and defaults to preview mode.
  Use -v/--verbose for human-friendly detail and -s/--show-files for full paths.
  Dry-run mode writes ./clean.sh with commented rm -rf lines for review.
  Execute mode shows each group, then asks before moving files.
  Files are moved to ~/.Trash/mac-cleaner-* first, not permanently deleted.
EOF
}

# Logging is best-effort and privacy-aware: terminal output can show exact
# paths for review, but persistent logs should not retain local path details.
redact_log_message() {
  local msg="$1"
  # Strip ANSI color escape codes before saving to logs
  msg="$(printf '%s' "$msg" | sed 's/\x1b\[[0-9;]*m//g')"

  if [[ -n "${QUARANTINE_ROOT:-}" ]]; then
    msg="${msg//"$QUARANTINE_ROOT"/<QUARANTINE_ROOT>}"
  fi
  if [[ -n "${LOG_FILE:-}" ]]; then
    msg="${msg//"$LOG_FILE"/<LOG_FILE>}"
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    msg="${msg//"$log_dir"/<LOG_DIR>}"
  fi
  local clean_tmp="${TMPDIR:-/tmp}"
  clean_tmp="${clean_tmp%/}"
  if [[ -n "$clean_tmp" ]]; then
    msg="${msg//"$clean_tmp"/<TMPDIR>}"
  fi
  msg="${msg//"$HOME_DIR"/~}"

  # Redact specific user file and directory detail components to prevent leaks
  msg="$(printf '%s' "$msg" | sed -E \
    -e 's|Failed to move .* to [^:]+|Failed to move <path> to <target>|g' \
    -e 's|~/Downloads/.*|~/Downloads/<redacted>|g' \
    -e 's|~/\.Trash/.*|~/\.Trash/<redacted>|g' \
    -e 's|~/\.cache/([^/]+)/.*|~/\.cache/\1/<redacted>|g' \
    -e 's|~/Library/Caches/([^/]+)/.*|~/Library/Caches/\1/<redacted>|g' \
    -e 's|~/Library/Logs/([^/]+)/.*|~/Library/Logs/\1/<redacted>|g' \
    -e 's|~/Library/Application Support/([^/]+)/.*|~/Library/Application Support/\1/<redacted>|g' \
    -e 's|~/Library/Developer/Xcode/Archives/.*|~/Library/Developer/Xcode/Archives/<redacted>|g' \
    -e 's|~/Library/Developer/CoreSimulator/Caches/.*|~/Library/Developer/CoreSimulator/Caches/<redacted>|g' \
    -e 's|~/Library/Containers/.*|~/Library/Containers/<redacted>|g' \
    -e 's|~/([^/]+)/.*|~/\1/<redacted>|g')"

  printf '%s' "$msg"
}

append_log() {
  local msg="$1"
  local log_dir
  log_dir="$(dirname "$LOG_FILE")"

  {
    mkdir -p "$log_dir" &&
      chmod 700 "$log_dir" 2>/dev/null || true
    touch "$LOG_FILE" &&
      chmod 600 "$LOG_FILE" 2>/dev/null || true
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(redact_log_message "$msg")" >> "$LOG_FILE"
  } 2>/dev/null || true
}

log() {
  local msg="$*"
  printf '%s\n' "$msg"
  if [[ -n "${LOG_FILE:-}" ]]; then
    append_log "$msg"
  fi
}

warn() {
  local msg="$*"
  printf '%sWarning:%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$msg" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    append_log "WARNING: $msg"
  fi
}

die() {
  local msg="$*"
  printf '%sError:%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$msg" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    append_log "ERROR: $msg"
  fi
  exit 1
}

default_log_file() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME_DIR/.local/state}/mac-cleaner/mac-cleaner.log"
}

# Maintenance command for the script's own persistent log. This exits before
# any scan runs.
clean_log_file() {
  local log_file="$1"

  if mkdir -p "$(dirname "$log_file")" && : > "$log_file"; then
    printf 'Cleaned log file: %s\n' "$log_file"
  else
    warn "Failed to clean log file: $log_file"
    exit 1
  fi
}

human_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b == 0) { print "empty"; exit }
    split("B KiB MiB GiB TiB", u)
    i=1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}

summary_bytes() {
  local val
  val="$(human_bytes "${1:-0}")"
  [[ "$val" == "empty" ]] && printf '0 B' || printf '%s' "$val"
}

format_duration() {
  local seconds="${1:-0}"
  local minutes hours

  if [[ "$seconds" -le 0 ]]; then
    printf 'less than 1s'
    return
  fi

  hours="$((seconds / 3600))"
  minutes="$(((seconds % 3600) / 60))"
  seconds="$((seconds % 60))"

  if [[ "$hours" -gt 0 ]]; then
    printf '%dh %dm %ds' "$hours" "$minutes" "$seconds"
  elif [[ "$minutes" -gt 0 ]]; then
    printf '%dm %ds' "$minutes" "$seconds"
  else
    printf '%ds' "$seconds"
  fi
}

start_scan_activity() {
  local label="$1"
  local started_at="$2"

  if [[ ! -t 2 ]]; then
    return
  fi

  (
    local frames=("-" "\\" "|" "/")
    local idx=0 now elapsed

    while true; do
      now="$(date '+%s')"
      elapsed="$((now - started_at))"
      printf '\r\033[2K%s %s (%s)' "${frames[idx]}" "$label" "$(format_duration "$elapsed")" >&2
      idx="$(((idx + 1) % 4))"
      sleep 1
    done
  ) &
  SCAN_ACTIVITY_PID="$!"
}

stop_scan_activity() {
  if [[ -z "${SCAN_ACTIVITY_PID:-}" ]]; then
    return
  fi

  kill "$SCAN_ACTIVITY_PID" 2>/dev/null || true
  wait "$SCAN_ACTIVITY_PID" 2>/dev/null || true
  SCAN_ACTIVITY_PID=""

  if [[ -t 2 ]]; then
    printf '\r\033[2K' >&2
  fi
}

parse_size_bytes() {
  local value="$1"
  local number unit multiplier

  if [[ ! "$value" =~ ^([0-9]+)([KkMmGgTt]?[Bb]?)?$ ]]; then
    return 1
  fi

  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"
  unit="${unit%b}"
  unit="${unit%B}"

  case "$unit" in
    "" )
      multiplier=1
      ;;
    [Kk])
      multiplier=1024
      ;;
    [Mm])
      multiplier=$((1024 * 1024))
      ;;
    [Gg])
      multiplier=$((1024 * 1024 * 1024))
      ;;
    [Tt])
      multiplier=$((1024 * 1024 * 1024 * 1024))
      ;;
    *)
      return 1
      ;;
  esac

  printf '%s' "$((number * multiplier))"
}

clean_script_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    if (b == 0) { print "0 B"; exit }
    if (b < 1024) { print "<1 KB"; exit }
    split("KB MB GB TB", u)
    i=1; b /= 1024
    while (b >= 1024 && i < 4) { b /= 1024; i++ }
    printf "%.1f %s\n", b, u[i]
  }'
}

# Risk rank is stored in the plan so output and execution order stay stable.
risk_rank() {
  case "$1" in
    low) printf '1' ;;
    medium) printf '2' ;;
    high) printf '3' ;;
    *) printf '9' ;;
  esac
}

# The plan file is the single source of truth between scan, display, and
# execution. Skipped optional groups are tracked separately so the real cleanup
# plan stays first in the output.
cleanup_runtime() {
  stop_scan_activity
  [[ -n "${PLAN_FILE:-}" ]] && rm -f "$PLAN_FILE"
  [[ -n "${SKIPPED_FILE:-}" ]] && rm -f "$SKIPPED_FILE"
  [[ -n "${APP_REPORT_FILE:-}" ]] && rm -f "$APP_REPORT_FILE"
  [[ -n "${INSPECTION_META_FILE:-}" ]] && rm -f "$INSPECTION_META_FILE"
  [[ -n "${STARTUP_REPORT_FILE:-}" ]] && rm -f "$STARTUP_REPORT_FILE"

  return 0
}

setup_plan_file() {
  local temp_root="${TMPDIR:-/tmp}"
  temp_root="${temp_root%/}"
  mkdir -p "$temp_root"
  PLAN_FILE="$(mktemp "$temp_root/mac-cleaner-plan.XXXXXX")"
  SKIPPED_FILE="$(mktemp "$temp_root/mac-cleaner-skipped.XXXXXX")"
  INSPECTION_META_FILE="$(mktemp "$temp_root/mac-cleaner-inspection.XXXXXX")"
  trap cleanup_runtime EXIT
}

# Execute mode never permanently deletes files. It moves approved items into a
# timestamped folder under ~/.Trash so users can inspect and recover them.
setup_quarantine_root() {
  if [[ -n "$QUARANTINE_ROOT" ]]; then
    return
  fi

  local stamp
  stamp="$(date '+%Y%m%d-%H%M%S')"
  QUARANTINE_ROOT="$HOME_DIR/.Trash/mac-cleaner-$stamp"
  mkdir -p "$QUARANTINE_ROOT"
}

# Guard exact high-level directories. The script may remove children under some
# of these roots, but never the root directories themselves.
is_guarded_path() {
  local path="${1%/}"

  case "$path" in
    ""|"/"|"$HOME_DIR"|"$HOME_DIR/Library"|"$HOME_DIR/Library/Caches"|"$HOME_DIR/Library/Logs"|"$HOME_DIR/Downloads"|"$HOME_DIR/.Trash"|"$HOME_DIR/.cache")
      return 0
      ;;
    "$HOME_DIR/Library/Application Support"|"$HOME_DIR/Library/Application Support/Code"|"$HOME_DIR/Library/Application Support/Firefox"|"$HOME_DIR/Library/Application Support/Firefox/Profiles")
      return 0
      ;;
    "$HOME_DIR/Library/Developer"|"$HOME_DIR/Library/Developer/Xcode"|"$HOME_DIR/Library/Developer/CoreSimulator")
      return 0
      ;;
    "$HOME_DIR/Library/Containers"|"$HOME_DIR/Library/Containers/com.apple.Safari"|"$HOME_DIR/Library/Containers/com.apple.Safari/Data"|"$HOME_DIR/Library/Containers/com.apple.Safari/Data/Library"|"$HOME_DIR/Library/Containers/com.apple.Safari/Data/Library/Caches")
      return 0
      ;;
  esac

  return 1
}

is_under_path() {
  local path="${1%/}"
  local root="${2%/}"

  [[ "$path" == "$root/"* ]]
}

is_large_files_scope_path() {
  local path="${1%/}"
  local root

  for root in \
    "$HOME_DIR/Desktop" \
    "$HOME_DIR/Documents" \
    "$HOME_DIR/Downloads" \
    "$HOME_DIR/Movies" \
    "$HOME_DIR/Music" \
    "$HOME_DIR/Pictures"
  do
    if is_under_path "$path" "$root"; then
      return 0
    fi
  done

  return 1
}

is_dev_clean_scope_path() {
  local path="${1%/}"

  case "$path" in
    "$HOME_DIR/.vscode/extensions"/*|"$HOME_DIR/.cursor/extensions"/*)
      return 0
      ;;
  esac

  return 1
}

safe_to_delete_path() {
  local path="$1"

  if is_guarded_path "$path"; then
    return 1
  fi

  if [[ "$COMMAND" == "large-files" ]] && is_large_files_scope_path "$path"; then
    return 0
  fi

  if [[ "$COMMAND" == "dev-clean" ]] && is_dev_clean_scope_path "$path"; then
    return 0
  fi

  if [[ "$INCLUDE_XCODE_ARCHIVES" -eq 1 ]] && is_under_path "$path" "$HOME_DIR/Library/Developer/Xcode/Archives"; then
    return 0
  fi

  case "$path" in
    # Caches, Logs, Trash, Downloads
    "$HOME_DIR/Library/Caches"/*|"$HOME_DIR/Library/Containers/com.apple.Safari/Data/Library/Caches"/*|"$HOME_DIR/Library/Logs"/*|"$HOME_DIR/.cache"/*|"$HOME_DIR/Downloads"/*|"$HOME_DIR/.Trash"/*)
      return 0
      ;;
    # IDEs Caches (VS Code, Cursor)
    "$HOME_DIR/Library/Application Support/Code/Cache"/*|"$HOME_DIR/Library/Application Support/Code/CachedData"/*|"$HOME_DIR/Library/Application Support/Code/Service Worker/CacheStorage"/*)
      return 0
      ;;
    "$HOME_DIR/Library/Application Support/Cursor/Cache"/*|"$HOME_DIR/Library/Application Support/Cursor/CachedData"/*)
      return 0
      ;;
    # Chrome and Brave profiles caches
    "$HOME_DIR/Library/Application Support/Google/Chrome"/*/Cache/*|"$HOME_DIR/Library/Application Support/Google/Chrome"/*/"Code Cache"/*)
      return 0
      ;;
    "$HOME_DIR/Library/Application Support/BraveSoftware/Brave-Browser"/*/Cache/*|"$HOME_DIR/Library/Application Support/BraveSoftware/Brave-Browser"/*/"Code Cache"/*)
      return 0
      ;;
    # Firefox profile caches
    "$HOME_DIR/Library/Application Support/Firefox/Profiles"/*)
      return 0
      ;;
    # Developer tools caches
    "$HOME_DIR/Library/Developer/Xcode/DerivedData"|"$HOME_DIR/Library/Developer/CoreSimulator/Caches"|"$HOME_DIR/.npm/_cacache"|"$HOME_DIR/.yarn/cache"|"$HOME_DIR/.cargo/registry/cache"|"$HOME_DIR/.gradle/caches")
      return 0
      ;;
  esac

  local clean_tmp="${TMPDIR:-/tmp}"
  clean_tmp="${clean_tmp%/}"
  if is_under_path "$path" "$clean_tmp"; then
    return 0
  fi

  return 1
}

# Use du for both files and directories so the plan can show realistic reclaim
# estimates before the user approves anything.
path_size_bytes() {
  local path="$1"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    printf '0'
    return
  fi

  local blocks
  blocks="$(du -sk "$path" 2>/dev/null | awk '{print $1}' || true)"
  if [[ -z "$blocks" ]]; then
    printf '0'
  else
    printf '%s' "$((blocks * 1024))"
  fi
}

file_size_bytes() {
  local path="$1"
  local bytes

  bytes="$(stat -f %z "$path" 2>/dev/null || stat -c %s "$path" 2>/dev/null || true)"
  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '%s' "$bytes"
  else
    printf '0'
  fi
}

apparent_path_size_bytes() {
  local path="$1"
  local total

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    printf '0'
    return
  fi

  if [[ -f "$path" || -L "$path" ]]; then
    file_size_bytes "$path"
    return
  fi

  total="$(find "$path" -type f -exec stat -f %z {} + 2>/dev/null | awk '{ total += $1 } END { printf "%d", total }' || true)"
  if [[ -z "$total" ]]; then
    total="$(find "$path" -type f -exec stat -c %s {} + 2>/dev/null | awk '{ total += $1 } END { printf "%d", total }' || true)"
  fi

  if [[ "$total" =~ ^[0-9]+$ ]]; then
    printf '%s' "$total"
  else
    printf '0'
  fi
}

path_mtime_seconds() {
  local path="$1"
  local seconds

  seconds="$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || true)"
  if [[ "$seconds" =~ ^[0-9]+$ ]]; then
    printf '%s' "$seconds"
  else
    printf '0'
  fi
}

path_birth_seconds() {
  local path="$1"
  local seconds

  seconds="$(stat -f %B "$path" 2>/dev/null || true)"
  if [[ "$seconds" =~ ^[0-9]+$ && "$seconds" -gt 0 ]]; then
    printf '%s' "$seconds"
    return
  fi

  path_mtime_seconds "$path"
}

format_epoch_date() {
  local seconds="${1:-0}"

  if [[ ! "$seconds" =~ ^[0-9]+$ || "$seconds" -le 0 ]]; then
    printf 'unknown'
    return
  fi

  date -r "$seconds" '+%Y-%m-%d' 2>/dev/null || date -d "@$seconds" '+%Y-%m-%d' 2>/dev/null || printf 'unknown'
}

current_epoch_seconds() {
  date '+%s'
}

markdown_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

markdown_inline_code_escape() {
  local value="$1"
  value="${value//\`/\\\`}"
  printf '%s' "$value"
}

add_note() {
  local current="$1"
  local item="$2"

  if [[ -z "$current" || "$current" == "review" ]]; then
    printf '%s' "$item"
  else
    printf '%s, %s' "$current" "$item"
  fi
}

uninstall_inspect_command() {
  local path="$1"
  printf './mac-cleaner.sh uninstall %s' "$(shell_quote "$path")"
}

package_json_value() {
  local file="$1"
  local key="$2"

  sed -nE "s/^[[:space:]]*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" "$file" 2>/dev/null | head -n 1
}

extension_identity() {
  local path="$1"
  local base pkg publisher name

  base="$(basename "$path")"
  pkg="$path/package.json"
  if [[ -f "$pkg" ]]; then
    publisher="$(package_json_value "$pkg" publisher)"
    name="$(package_json_value "$pkg" name)"
    if [[ -n "$publisher" && -n "$name" ]]; then
      printf '%s.%s' "$publisher" "$name"
      return
    fi
  fi

  # Fallback for typical extension folders like publisher.name-1.2.3.
  printf '%s' "$base" | sed -E 's/-[0-9]+([.][0-9A-Za-z_-]+)*$//'
}

plist_value() {
  local plist="$1"
  local key="$2"
  local value=""

  if [[ ! -f "$plist" ]]; then
    return 1
  fi

  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
  fi

  if [[ -z "$value" ]] && command -v plutil >/dev/null 2>&1; then
    value="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true)"
  fi

  if [[ -z "$value" ]]; then
    value="$(awk -v wanted="$key" '
      $0 ~ "<key>" wanted "</key>" {
        getline
        if (match($0, /<string>[^<]+<\/string>/)) {
          value = substr($0, RSTART + 8, RLENGTH - 17)
          print value
          exit
        }
      }
    ' "$plist" 2>/dev/null || true)"
  fi

  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi

  return 1
}

app_bundle_name() {
  local app="$1"
  local base

  base="$(basename "$app")"
  printf '%s' "${base%.app}"
}

app_last_used_seconds() {
  local app="$1"
  local raw seconds

  if ! command -v mdls >/dev/null 2>&1; then
    printf '0'
    return
  fi

  raw="$(mdls -raw -name kMDItemLastUsedDate "$app" 2>/dev/null || true)"
  if [[ -z "$raw" || "$raw" == "(null)" ]]; then
    printf '0'
    return
  fi

  seconds="$(date -j -f '%Y-%m-%d %H:%M:%S %z' "$raw" '+%s' 2>/dev/null || true)"
  if [[ "$seconds" =~ ^[0-9]+$ ]]; then
    printf '%s' "$seconds"
  else
    printf '0'
  fi
}

app_inventory_file() {
  if [[ -z "${APP_REPORT_FILE:-}" ]]; then
    APP_REPORT_FILE="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-apps.XXXXXX")"
  fi
}

startup_report_file() {
  if [[ -z "${STARTUP_REPORT_FILE:-}" ]]; then
    STARTUP_REPORT_FILE="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-startup.XXXXXX")"
  fi
}

plist_array_first_value() {
  local plist="$1"
  local key="$2"
  local value=""

  if [[ ! -f "$plist" ]]; then
    return 1
  fi

  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    value="$(/usr/libexec/PlistBuddy -c "Print :$key:0" "$plist" 2>/dev/null || true)"
  fi

  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return 0
  fi

  return 1
}

one_line_field() {
  local value="$1"
  value="${value%%$'\n'*}"
  value="${value//$'\t'/ }"
  printf '%s' "$value"
}

startup_bool_field() {
  local value="$1"
  value="$(one_line_field "$value")"

  case "$value" in
    true|false)
      printf '%s' "$value"
      ;;
    Dict*)
      printf 'dict'
      ;;
    "")
      printf 'false'
      ;;
    *)
      printf '%s' "$value"
      ;;
  esac
}

# Add one candidate path to the cleanup plan after validating it against the
# allowlist. This is the last safety check before anything can be shown or moved.
record_path() {
  local group="$1"
  local risk="$2"
  local path="$3"

  if ! safe_to_delete_path "$path"; then
    warn "Skipping guarded or unexpected path: $path"
    return
  fi

  local size
  size="$(path_size_bytes "$path")"
  TOTAL_BYTES="$((TOTAL_BYTES + size))"
  ITEMS_FOUND="$((ITEMS_FOUND + 1))"

  printf '%s\t%s\t%s\t%s\t%s\n' "$group" "$(risk_rank "$risk")" "$risk" "$size" "$path" >>"$PLAN_FILE"
}

record_inspection_path() {
  local group="$1"
  local risk="$2"
  local path="$3"
  local reason="${4:-matched by inspect rule}"

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return
  fi
  if [[ -s "$PLAN_FILE" ]] && awk -F '\t' -v wanted="$path" '$5 == wanted { found = 1 } END { exit found ? 0 : 1 }' "$PLAN_FILE"; then
    return
  fi

  local size
  size="$(path_size_bytes "$path")"
  TOTAL_BYTES="$((TOTAL_BYTES + size))"
  ITEMS_FOUND="$((ITEMS_FOUND + 1))"

  printf '%s\t%s\t%s\t%s\t%s\n' "$group" "$(risk_rank "$risk")" "$risk" "$size" "$path" >>"$PLAN_FILE"
  printf '%s\t%s\n' "$path" "$reason" >>"$INSPECTION_META_FILE"
}

record_skipped() {
  local group="$1"
  local reason="$2"

  printf '%s\t%s\n' "$group" "$reason" >>"$SKIPPED_FILE"
}

quarantine_path() {
  local path="$1"
  local expected_bytes="${2:-0}"
  local err_msg
  if ! safe_to_delete_path "$path"; then
    warn "Refusing to move guarded or unexpected path: $path"
    return 1
  fi

  if [[ -e "$path" || -L "$path" ]]; then
    setup_quarantine_root

    local relative target parent clean_tmp
    clean_tmp="${TMPDIR:-/tmp}"
    clean_tmp="${clean_tmp%/}"
    case "$path" in
      "$HOME_DIR"/*)
        relative="home/${path#"$HOME_DIR"/}"
        ;;
      "$clean_tmp"/*)
        relative="tmp/${path#"$clean_tmp"/}"
        ;;
      *)
        relative="other/${path#/}"
        ;;
    esac

    target="$QUARANTINE_ROOT/$relative"
    parent="$(dirname "$target")"
    mkdir -p "$parent"

    if [[ -e "$target" || -L "$target" ]]; then
      target="$target.$(date '+%s').$$"
    fi

    if ! err_msg=$(mv "$path" "$target" 2>&1); then
      warn "Failed to move $path to $target: $err_msg"
      return 1
    fi

    ITEMS_MOVED="$((ITEMS_MOVED + 1))"
    MOVED_BYTES="$((MOVED_BYTES + expected_bytes))"
    return 0
  fi

  return 1
}

# Render the dry-run cleanup plan. The awk block keeps grouping and size
# aggregation close to the sorted plan format.
print_plan() {
  log ""
  if [[ "$COMMAND" == "uninstall" ]]; then
    log "${COLOR_BOLD}== Uninstall inspection report ==${COLOR_RESET}"
  else
    log "${COLOR_BOLD}== Cleanup plan ==${COLOR_RESET}"
  fi

  if [[ "$ITEMS_FOUND" -eq 0 ]]; then
    log "No matching files found."
    return
  fi

  sort_plan | awk -F '\t' \
    -v verbose="$VERBOSE" \
    -v show_files="$SHOW_FILES" \
    -v command="$COMMAND" \
    -v reason_file="$INSPECTION_META_FILE" \
    -v home="$HOME_DIR" \
    -v tmp="${TMPDIR:-/tmp}" \
    -v reset="$COLOR_RESET" \
    -v bold="$COLOR_BOLD" \
    -v dim="$COLOR_DIM" \
    -v red="$COLOR_RED" \
    -v green="$COLOR_GREEN" \
    -v yellow="$COLOR_YELLOW" \
    -v blue="$COLOR_BLUE" \
    -v cyan="$COLOR_CYAN" \
    -v magenta="$COLOR_MAGENTA" '
    BEGIN {
      if (command == "uninstall" && reason_file != "") {
        while ((getline line < reason_file) > 0) {
          split(line, parts, "\t")
          if (parts[1] != "") reason[parts[1]] = parts[2]
        }
        close(reason_file)
      }
      note["Developer caches"] = "Usually safe to regenerate, but the next build, package install, or simulator launch may be slower."
      note["Crash reports older than threshold"] = "Useful for troubleshooting older app crashes. Safe to move after review."
      note["Old user logs"] = note["Old iOS simulator logs"] = "Logs are usually safe to move, but can help investigate older issues."
      note["User cache contents older than threshold"] = note["Firefox browser caches"] = note["Temporary files older than threshold"] = "Usually safe to regenerate. Apps may rebuild these files later."
      note["Downloads older than threshold"] = "High-risk personal files. Review each path before approving."
      note["Large files older than threshold"] = "High-risk personal files. Review each path before approving."
      note["Old VS Code extension versions"] = note["Old Cursor extension versions"] = "Older extension versions are usually safe to remove after the editor has updated successfully."
      note["Application bundle"] = note["App support files"] = note["App caches"] = note["App preferences"] = note["App containers"] = note["App logs"] = "Inspect-only. Matching is conservative but should be reviewed before any future execute support."
      note["Trash"] = "High-risk final review area. Moving these keeps them recoverable until Trash is emptied."
      note["Old Xcode archives"] = "High-risk release archives. They may contain dSYMs, builds, and submission history."

      rnote["1"] = rnote["low"] = "Usually safe to regenerate."
      rnote["2"] = rnote["medium"] = "Review first. These may affect workflow or troubleshooting history."
      rnote["3"] = rnote["high"] = "Review carefully before approving."
    }
    function human(bytes, units, i) {
      if (bytes == 0) {
        return "empty"
      }
      split("B KiB MiB GiB TiB", units, " ")
      i = 1
      while (bytes >= 1024 && i < 5) {
        bytes /= 1024
        i++
      }
      return sprintf("%.1f %s", bytes, units[i])
    }
    function display_path(path) {
      if (index(path, home "/") == 1) {
        return "~" substr(path, length(home) + 1)
      }
      if (tmp != "" && index(path, tmp "/") == 1) {
        return "$TMPDIR" substr(path, length(tmp) + 1)
      }
      return path
    }
    function detail_bucket(path, shown) {
      shown = display_path(path)
      if (match(shown, /^\~\/(Library\/Application Support\/Code|Library\/Application Support|Library\/Developer|Library\/Logs|Library\/Caches|\.cache)\/[^\/]+/)) {
        return substr(shown, RSTART, RLENGTH)
      }
      if (shown == "~/Library/Logs") return "~/Library/Logs root files"
      if (shown == "~/Library/Caches") return "~/Library/Caches root files"
      if (shown ~ /^\~\/\.gradle/) return "~/.gradle/caches"
      if (shown ~ /^\~\/\.npm/) return "~/.npm/_cacache"
      if (shown ~ /^\~\/Downloads/) return "~/Downloads"
      if (shown ~ /^\~\/\.Trash/) return "~/.Trash"
      if (shown ~ /^\$TMPDIR/) return "$TMPDIR"
      return shown
    }
    function group_note(group, risk) {
      if (group in note) return "Note: " note[group]
      if (risk in rnote) return "Note: " rnote[risk]
      return "Note: Review carefully before approving."
    }
    function ensure_group(group, risk) {
      if (!(group in seen_group)) {
        groups[++group_total] = group
        group_risk[group] = risk
        seen_group[group] = 1
      }
    }
    function add_detail(group, detail, size, key) {
      key = group SUBSEP detail
      if (!(key in seen_detail)) {
        detail_total[group] += 1
        detail_order[group SUBSEP detail_total[group]] = detail
        seen_detail[key] = 1
      }
      detail_count[key]++
      detail_bytes[key] += size
    }
    function add_file(group, size, path) {
      file_total[group] += 1
      file_size[group SUBSEP file_total[group]] = size
      file_path[group SUBSEP file_total[group]] = path
    }
    {
      group = $1
      risk = $3
      size = $4
      path = $5
      ensure_group(group, risk)
      group_count[group]++
      group_bytes[group] += size

      if (show_files != 0) {
        add_file(group, size, path)
      } else if (verbose != 0) {
        add_detail(group, detail_bucket(path), size)
      }
    }
    END {
      for (i = 1; i <= group_total; i++) {
        group = groups[i]
        risk = group_risk[group]

        # Determine risk color
        risk_color = reset
        if (risk == "1" || risk == "low") {
          risk_color = green
        } else if (risk == "2" || risk == "medium") {
          risk_color = yellow
        } else if (risk == "3" || risk == "high") {
          risk_color = red
        }

        # Print header
        printf "%s❯ %s%s %s[%s risk]%s\n", bold, group, reset, risk_color, (risk == "1" ? "low" : (risk == "2" ? "medium" : (risk == "3" ? "high" : risk))), reset
        printf "  %s%s%s\n", dim, group_note(group, risk), reset

        if (show_files != 0) {
          for (j = 1; j <= file_total[group]; j++) {
            size = file_size[group SUBSEP j]
            path = file_path[group SUBSEP j]
            printf "  %s├── %s%-10s%s  %s\n", dim, reset, human(size), dim, display_path(path)
            if (command == "uninstall" && (path in reason)) {
              printf "  %s│   Reason: %s%s\n", dim, reason[path], reset
            }
          }
        } else if (verbose != 0) {
          for (j = 1; j <= detail_total[group]; j++) {
            detail = detail_order[group SUBSEP j]
            key = group SUBSEP detail
            printf "  %s├── %s%-10s%s  (%d %s)  %s%s\n",
              dim, reset, human(detail_bytes[key]), dim, detail_count[key],
              (detail_count[key] == 1 ? "item" : "items"), reset, detail
          }
        }

        # Summary as tree base (always the └── branch)
        printf "  %s└── Total: %s%s%s  (%d %s)\n",
          dim, bold, human(group_bytes[group]), reset, group_count[group],
          (group_count[group] == 1 ? "item" : "items")

        if (i < group_total) {
          printf "\n"
        }
      }
    }
  '
}

sort_plan() {
  if [[ "$COMMAND" == "large-files" ]]; then
    LC_ALL=C sort -t "$(printf '\t')" -k4,4nr -k5,5 "$PLAN_FILE"
    return
  fi

  LC_ALL=C sort -t "$(printf '\t')" -k2,2n -k1,1 -k5,5 "$PLAN_FILE"
}

shell_quote() {
  local value="$1"
  printf '%q' "$value"
}

write_dry_run_clean_script() {
  if [[ "$DRY_RUN" -ne 1 ]]; then
    return
  fi
  if [[ "$COMMAND" == "uninstall" ]]; then
    return
  fi

  local output="$CLEAN_SCRIPT_FILE"
  if [[ -e "$output" || -L "$output" ]]; then
    output="clean-$(date '+%Y%m%d-%H%M%S').sh"
  fi

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n\n'
    printf '## Generated by mac-cleaner.sh %s dry-run.\n' "$VERSION"
    printf '## Review every path carefully before using this file.\n'
    printf '##\n'
    printf '## How to use:\n'
    printf '##   1. Open this file in your editor (VS Code, Cursor, etc.).\n'
    printf '##   2. Select the groups or command lines you approve.\n'
    printf '##   3. Press Cmd + / (or Ctrl + /) to uncomment only the rm -rf lines.\n'
    printf '##   4. Run this script in your terminal:\n'
    printf '##      bash %s\n\n' "$output"

    if [[ "$ITEMS_FOUND" -eq 0 ]]; then
      printf '## No removable candidates were found in this dry run.\n'
    else
      local previous_group="" group _rank risk size path
      while IFS="$(printf '\t')" read -r group _rank risk size path; do
        if [[ "$group" != "$previous_group" ]]; then
          if [[ -n "$previous_group" ]]; then
            printf '\n'
          fi
          printf '## == %s [%s risk] ==\n' "$group" "$risk"
          previous_group="$group"
        fi

        printf '## Size: %s\n' "$(clean_script_bytes "$size")"
        printf '# rm -rf -- %s\n' "$(shell_quote "$path")"
      done < <(sort_plan)
    fi
  } >"$output"

  chmod 700 "$output" 2>/dev/null || true
  log ""
  log "Dry-run cleanup script written to: $output"
  log "All rm -rf lines are commented. Review, edit, and run it yourself only if you are confident."

  # Clean up old clean-[0-9]*.sh scripts in the current directory, keeping the last 3 files
  local old_scripts=()
  local script_path
  while IFS= read -r script_path; do
    if [[ -f "$script_path" ]]; then
      old_scripts+=("$script_path")
    fi
  done < <(ls -t clean-[0-9]*.sh 2>/dev/null)

  if [[ "${#old_scripts[@]}" -gt 3 ]]; then
    local idx
    for ((idx = 3; idx < ${#old_scripts[@]}; idx++)); do
      rm -f "${old_scripts[idx]}"
    done
  fi
}

print_group_files() {
  local group="$1"

  sort_plan | awk -F '\t' \
    -v wanted="$group" \
    -v home="$HOME_DIR" \
    -v tmp="${TMPDIR:-/tmp}" \
    -v dim="$COLOR_DIM" \
    -v reset="$COLOR_RESET" '
    function human(bytes, units, i) {
      if (bytes == 0) {
        return "empty"
      }
      split("B KiB MiB GiB TiB", units, " ")
      i = 1
      while (bytes >= 1024 && i < 5) {
        bytes /= 1024
        i++
      }
      return sprintf("%.1f %s", bytes, units[i])
    }
    function display_path(path) {
      if (index(path, home "/") == 1) {
        return "~" substr(path, length(home) + 1)
      }
      if (tmp != "" && index(path, tmp "/") == 1) {
        return "$TMPDIR" substr(path, length(tmp) + 1)
      }
      return path
    }
    $1 == wanted {
      paths[++total] = $5
      sizes[total] = $4
    }
    END {
      for (i = 1; i <= total; i++) {
        prefix = (i == total) ? "└──" : "├──"
        printf "  %s%s %s%-10s%s  %s%s\n", dim, prefix, reset, human(sizes[i]), dim, display_path(paths[i]), reset
      }
    }
  '
}

print_skipped_optional_groups() {
  if [[ ! -s "$SKIPPED_FILE" ]]; then
    return
  fi

  log ""
  log "${COLOR_BOLD}== Skipped optional groups ==${COLOR_RESET}"
  awk -F '\t' -v dim="$COLOR_DIM" -v reset="$COLOR_RESET" '{ printf "  %s%s: skipped. %s%s\n", dim, $1, $2, reset }' "$SKIPPED_FILE"
}

print_final_summary() {
  log ""
  log "${COLOR_BOLD}📊 Final Summary${COLOR_RESET}"
  log "${COLOR_DIM}────────────────────────────────────────────────────────${COLOR_RESET}"
  if [[ "$COMMAND" == "applications" ]]; then
    printf "${COLOR_BOLD}%-20s${COLOR_RESET} %8s apps    %12s\n" "Applications:" "$ITEMS_FOUND" "$(summary_bytes "$TOTAL_BYTES")"
  elif [[ "$COMMAND" == "startup" ]]; then
    printf "${COLOR_BOLD}%-20s${COLOR_RESET} %8s items   %12s\n" "Startup items:" "$ITEMS_FOUND" "$(summary_bytes "$TOTAL_BYTES")"
  elif [[ "$COMMAND" == "uninstall" ]]; then
    printf "${COLOR_BOLD}%-20s${COLOR_RESET} %8s items   %12s\n" "Potential matches:" "$ITEMS_FOUND" "$(summary_bytes "$TOTAL_BYTES")"
  else
    printf "${COLOR_BOLD}%-20s${COLOR_RESET} %8s items   %12s\n" "Can be reclaimed:" "$ITEMS_FOUND" "$(summary_bytes "$TOTAL_BYTES")"
  fi
  printf "${COLOR_BOLD}%-20s${COLOR_RESET} %8s items   %12s\n" "Actually moved:" "$ITEMS_MOVED" "$(summary_bytes "$MOVED_BYTES")"
  printf "${COLOR_BOLD}%-20s${COLOR_RESET} %24s\n" "Scan time:" "$(format_duration "$SCAN_SECONDS")"
  log "${COLOR_DIM}────────────────────────────────────────────────────────${COLOR_RESET}"
}

print_next_step() {
  log ""
  if [[ "$COMMAND" == "applications" ]]; then
    log "Review the application report, then inspect any candidate app with:"
    log "  ${COLOR_BOLD}${COLOR_CYAN}./mac-cleaner.sh uninstall /Applications/AppName.app${COLOR_RESET}"
    return
  fi

  if [[ "$COMMAND" == "startup" ]]; then
    log "Review the startup report above. This command is inspect-only for now."
    log "${COLOR_DIM}Disable/remove support should only be added after entries and ownership are clearly understood.${COLOR_RESET}"
    return
  fi

  if [[ "$COMMAND" == "uninstall" ]]; then
    log "Review the paths above. This command is inspect-only for now."
    log "${COLOR_DIM}Execute support will be added only after the matching rules are proven conservative.${COLOR_RESET}"
    return
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Review the paths above. If they look safe, run:"
    case "$COMMAND" in
      large-files)
        log "  ${COLOR_BOLD}${COLOR_CYAN}./mac-cleaner.sh large-files --execute${COLOR_RESET}"
        ;;
      dev-clean)
        log "  ${COLOR_BOLD}${COLOR_CYAN}./mac-cleaner.sh dev-clean --execute${COLOR_RESET}"
        ;;
      *)
        log "  ${COLOR_BOLD}${COLOR_CYAN}./mac-cleaner.sh --execute${COLOR_RESET}"
        log "${COLOR_DIM}For a more conservative cleanup, leave Downloads, Trash, Docker, and Xcode archives disabled.${COLOR_RESET}"
        ;;
    esac
  else
    log "${COLOR_BOLD}${COLOR_GREEN}Cleanup complete.${COLOR_RESET}"
  fi
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local answer suffix

  if [[ "$default" == "y" || "$default" == "Y" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  while true; do
    printf '%s%s%s %s: ' "$COLOR_BOLD" "$prompt" "$COLOR_RESET" "$suffix"
    read -r answer
    case "$answer" in
      "")
        [[ "$default" == "y" || "$default" == "Y" ]]
        return
        ;;
      y|Y|yes|YES|Yes)
        return 0
        ;;
      n|N|no|NO|No)
        return 1
        ;;
      *)
        log "Please answer y or n."
        ;;
    esac
  done
}

prompt_age_threshold() {
  local answer

  while true; do
    printf '%sOnly include age-based files older than how many days?%s [%s]: ' "$COLOR_BOLD" "$COLOR_RESET" "$OLDER_THAN_DAYS"
    read -r answer
    if [[ -z "$answer" ]]; then
      return
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]]; then
      OLDER_THAN_DAYS="$answer"
      return
    fi
    log "Please enter a non-negative whole number."
  done
}

prompt_min_size() {
  local answer parsed

  while true; do
    printf '%sOnly include files at least how large?%s [%s]: ' "$COLOR_BOLD" "$COLOR_RESET" "$(summary_bytes "$MIN_SIZE_BYTES")"
    read -r answer
    if [[ -z "$answer" ]]; then
      return
    fi
    if parsed="$(parse_size_bytes "$answer")"; then
      MIN_SIZE_BYTES="$parsed"
      return
    fi
    log "Please enter a size such as 100M or 1G."
  done
}

prompt_detail_level() {
  local answer

  log ""
  log "${COLOR_BOLD}Review detail:${COLOR_RESET}"
  log "  1) Summary only"
  log "  2) Grouped folders"
  log "  3) Every file path"

  while true; do
    printf '%sChoose review detail%s [2]: ' "$COLOR_BOLD" "$COLOR_RESET"
    read -r answer
    case "${answer:-2}" in
      1)
        VERBOSE=0
        SHOW_FILES=0
        return
        ;;
      2)
        VERBOSE=1
        SHOW_FILES=0
        return
        ;;
      3)
        VERBOSE=0
        SHOW_FILES=1
        return
        ;;
      *)
        log "Please choose 1, 2, or 3."
        ;;
    esac
  done
}

configure_interactive_mode() {
  if [[ "$INTERACTIVE" -ne 1 ]]; then
    return
  fi

  if [[ ! -t 0 ]]; then
    die "--interactive requires a terminal."
  fi

  log ""
  log "== Interactive setup =="
  log "Press Enter to keep the default shown in brackets."

  if [[ "$COMMAND" == "uninstall" || "$COMMAND" == "applications" || "$COMMAND" == "startup" ]]; then
    log "This report command does not need interactive setup yet."
    log ""
    log "Scanning with your current options..."
    return
  fi

  if [[ "$COMMAND" == "dev-clean" ]]; then
    prompt_detail_level
    log ""
    log "Scanning with your interactive choices..."
    return
  fi

  prompt_age_threshold

  if [[ "$COMMAND" == "large-files" ]]; then
    prompt_min_size
    prompt_detail_level
    log ""
    log "Scanning with your interactive choices..."
    return
  fi

  if prompt_yes_no "Include old files from ~/Downloads?" "$([[ "$INCLUDE_DOWNLOADS" -eq 1 ]] && printf y || printf n)"; then
    INCLUDE_DOWNLOADS=1
  else
    INCLUDE_DOWNLOADS=0
  fi

  if prompt_yes_no "Include ~/.Trash contents?" "$([[ "$EMPTY_TRASH" -eq 1 ]] && printf y || printf n)"; then
    EMPTY_TRASH=1
  else
    EMPTY_TRASH=0
  fi

  if prompt_yes_no "Include old Xcode Organizer archives?" "$([[ "$INCLUDE_XCODE_ARCHIVES" -eq 1 ]] && printf y || printf n)"; then
    INCLUDE_XCODE_ARCHIVES=1
  else
    INCLUDE_XCODE_ARCHIVES=0
  fi

  if command -v docker >/dev/null 2>&1; then
    if prompt_yes_no "Include Docker prune review?" "$([[ "$INCLUDE_DOCKER" -eq 1 ]] && printf y || printf n)"; then
      INCLUDE_DOCKER=1
    else
      INCLUDE_DOCKER=0
    fi
  else
    INCLUDE_DOCKER=0
  fi

  prompt_detail_level

  log ""
  log "Scanning with your interactive choices..."
}

offer_interactive_execute() {
  if [[ "$INTERACTIVE" -ne 1 || "$DRY_RUN" -ne 1 ]]; then
    return
  fi

  if [[ "$ITEMS_FOUND" -eq 0 && "$INCLUDE_DOCKER" -ne 1 ]]; then
    return
  fi

  log ""
  if prompt_yes_no "Run execute mode now and approve cleanup groups one by one?" n; then
    DRY_RUN=0
  else
    log "Staying in dry-run mode. Nothing was moved."
  fi
}

group_risk_note() {
  case "$1" in
    low)
      printf 'Usually safe to regenerate, such as caches or temporary files.'
      ;;
    medium)
      printf 'Review first. These may affect developer tools, local workflow, or troubleshooting history.'
      ;;
    high)
      printf 'High impact. These can include personal files, Trash contents, or release/archive history.'
      ;;
    *)
      printf 'Review carefully before moving.'
      ;;
  esac
}

display_path() {
  local path="$1"
  local clean_tmp="${TMPDIR:-/tmp}"
  clean_tmp="${clean_tmp%/}"

  if [[ "$path" == "$HOME_DIR/"* ]]; then
    printf '%s/%s' '~' "${path#"$HOME_DIR"/}"
    return
  fi

  if [[ -n "$clean_tmp" && "$path" == "$clean_tmp/"* ]]; then
    printf '%s/%s' "\$TMPDIR" "${path#"$clean_tmp"/}"
    return
  fi

  printf '%s' "$path"
}

# Interactive gate for file cleanup groups. The default is always "No"; --yes
# only auto-approves low/medium risk groups.
confirm_group_quarantine() {
  local group="$1"
  local risk="$2"
  local count="$3"
  local size
  size="$(human_bytes "$4")"

  if [[ "$YES" -eq 1 && "$risk" != "high" ]]; then
    log ""
    log "${COLOR_DIM}────────────────────────────────────────────────────────${COLOR_RESET}"
    log "🟢 ${COLOR_GREEN}✓ Auto-approved by --yes:${COLOR_RESET} ${COLOR_BOLD}$group${COLOR_RESET} (${COLOR_BLUE}$count${COLOR_RESET} items, ${COLOR_BLUE}$size${COLOR_RESET})"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    warn "Skipping '$group' because execute mode needs interactive confirmation."
    return 1
  fi

  local risk_color risk_label risk_icon
  case "$risk" in
    low)
      risk_color="$COLOR_GREEN"
      risk_label="[Low Risk]"
      risk_icon="🟢"
      ;;
    medium)
      risk_color="$COLOR_YELLOW"
      risk_label="[Medium Risk]"
      risk_icon="⚠️ "
      ;;
    high)
      risk_color="$COLOR_RED"
      risk_label="[High Risk]"
      risk_icon="🚨"
      ;;
    *)
      risk_color="$COLOR_RESET"
      risk_label="[$risk Risk]"
      risk_icon="❓"
      ;;
  esac

  log ""
  log "${COLOR_DIM}────────────────────────────────────────────────────────${COLOR_RESET}"
  log "📦 ${COLOR_BOLD}Ready to move group:${COLOR_RESET} ${COLOR_CYAN}$group${COLOR_RESET}"
  log "${risk_icon} ${COLOR_BOLD}Risk:${COLOR_RESET} ${risk_color}${risk_label}${COLOR_RESET} — $(group_risk_note "$risk")"
  log "📊 ${COLOR_BOLD}Files to move:${COLOR_RESET} ${COLOR_BOLD}${COLOR_BLUE}$count${COLOR_RESET} items (${COLOR_BOLD}${COLOR_BLUE}$size${COLOR_RESET})"
  print_group_files "$group"
  log "${COLOR_DIM}────────────────────────────────────────────────────────${COLOR_RESET}"
  printf '%sMove this group to ~/.Trash? [y/N/q]:%s ' "$COLOR_BOLD" "$COLOR_RESET"
  local answer
  read -r answer
  if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    return 0
  fi
  if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
    ABORT_EXECUTION=1
    log "🔴 ${COLOR_RED}✗ Stopping execute mode at your request.${COLOR_RESET}"
    return 1
  fi

  log "🟡 ${COLOR_YELLOW}⚠ Skipped group:${COLOR_RESET} ${COLOR_BOLD}$group${COLOR_RESET}"
  return 1
}

confirm_large_file_quarantine() {
  local path="$1"
  local bytes="$2"
  local size shown

  size="$(human_bytes "$bytes")"
  shown="$(display_path "$path")"

  if [[ ! -t 0 ]]; then
    warn "Skipping '$shown' because execute mode needs interactive confirmation."
    return 1
  fi

  log ""
  log "${COLOR_DIM}────────────────────────────────────────────────────────${COLOR_RESET}"
  log "📄 ${COLOR_BOLD}Ready to move large file:${COLOR_RESET} ${COLOR_CYAN}$shown${COLOR_RESET}"
  log "🚨 ${COLOR_BOLD}Risk:${COLOR_RESET} ${COLOR_RED}[High Risk]${COLOR_RESET} — Personal file. Review carefully before moving."
  log "📊 ${COLOR_BOLD}File size:${COLOR_RESET} ${COLOR_BOLD}${COLOR_BLUE}$size${COLOR_RESET}"
  log "${COLOR_DIM}────────────────────────────────────────────────────────${COLOR_RESET}"
  printf '%sMove this file to ~/.Trash? [y/N/q]:%s ' "$COLOR_BOLD" "$COLOR_RESET"
  local answer
  read -r answer
  if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    return 0
  fi
  if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
    ABORT_EXECUTION=1
    log "🔴 ${COLOR_RED}✗ Stopping execute mode at your request.${COLOR_RESET}"
    return 1
  fi

  log "🟡 ${COLOR_YELLOW}⚠ Skipped file:${COLOR_RESET} ${COLOR_BOLD}$shown${COLOR_RESET}"
  return 1
}

# Docker prune is not recoverable via ~/.Trash, so it has a separate prompt and
# explicit confirmation word.
confirm_docker_cleanup() {
  if [[ "$YES" -eq 1 ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    warn "Skipping Docker cleanup because execute mode needs confirmation. Re-run with --yes for automation."
    return 1
  fi

  log ""
  log "${COLOR_DIM}────────────────────────────────────────────────────────${COLOR_RESET}"
  log "🐳 ${COLOR_BOLD}Ready to run Docker cleanup${COLOR_RESET}"
  log "⚠️  ${COLOR_BOLD}Risk:${COLOR_RESET} ${COLOR_YELLOW}[Medium Risk]${COLOR_RESET} — This permanently removes unused Docker builder cache and stopped resources."
  log "${COLOR_DIM}────────────────────────────────────────────────────────${COLOR_RESET}"
  printf '%sRun Docker prune commands? Type PRUNE to confirm, or press Enter to skip:%s ' "$COLOR_BOLD" "$COLOR_RESET"
  local answer
  read -r answer
  if [[ "$answer" == "PRUNE" ]]; then
    return 0
  fi

  log "🟡 ${COLOR_YELLOW}⚠ Skipped Docker cleanup.${COLOR_RESET}"
  return 1
}

# Execute the approved plan by group. Each path is rechecked in quarantine_path
# before it is moved.
execute_large_files_plan() {
  if [[ "$DRY_RUN" -eq 1 || "$ITEMS_FOUND" -eq 0 ]]; then
    return
  fi

  log ""
  log "== Execute large-files plan =="
  log "Each file is shown with its size before confirmation."

  local _group _rank risk size path
  while IFS="$(printf '\t')" read -r _group _rank risk size path; do
    if [[ "$ABORT_EXECUTION" -eq 1 ]]; then
      break
    fi

    if ! confirm_large_file_quarantine "$path" "$size"; then
      continue
    fi

    quarantine_path "$path" "$size" || true
    log "🟢 ${COLOR_GREEN}✓ Moved file to recovery folder:${COLOR_RESET} ${COLOR_BOLD}$(display_path "$path")${COLOR_RESET}"
  done < <(sort_plan)

  if [[ -n "$QUARANTINE_ROOT" ]]; then
    log ""
    log "Recovery folder: $QUARANTINE_ROOT"
    log "Review it later and empty Trash when you are confident everything still works."
  fi
}

execute_plan() {
  if [[ "$DRY_RUN" -eq 1 || "$ITEMS_FOUND" -eq 0 ]]; then
    return
  fi

  if [[ "$COMMAND" == "large-files" ]]; then
    execute_large_files_plan
    return
  fi

  # Check if reclaiming exceeds 80% of available disk space on home volume
  local free_kb
  free_kb=$(df -k "$HOME_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ "$free_kb" =~ ^[0-9]+$ && "$free_kb" -gt 0 ]]; then
    local free_bytes=$((free_kb * 1024))
    if [[ $((TOTAL_BYTES * 10)) -gt $((free_bytes * 8)) ]]; then
      log ""
      warn "Total size of files to clean ($(human_bytes "$TOTAL_BYTES")) exceeds 80% of your free disk space ($(human_bytes "$free_bytes"))."
      warn "Moving files of this size might temporarily slow down or fill up the disk volume."
    fi
  fi

  log ""
  log "== Execute cleanup plan =="
  log "Each group is shown with file names and total size before confirmation."

  local groups_file
  groups_file="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-groups.XXXXXX")"
  awk -F '\t' '{ bytes[$1] += $4; count[$1] += 1; risk[$1] = $3; rank[$1] = $2 } END { for (group in count) printf "%s\t%s\t%s\t%d\t%d\n", rank[group], group, risk[group], count[group], bytes[group] }' "$PLAN_FILE" \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 >"$groups_file"

  local _rank group risk count bytes path path_bytes
  while IFS="$(printf '\t')" read -u 3 -r _rank group risk count bytes; do
    if [[ "$ABORT_EXECUTION" -eq 1 ]]; then
      break
    fi

    if ! confirm_group_quarantine "$group" "$risk" "$count" "$bytes"; then
      continue
    fi

    while IFS="$(printf '\t')" read -r path_bytes path; do
      quarantine_path "$path" "$path_bytes" || true
    done < <(sort_plan | awk -F '\t' -v wanted="$group" '$1 == wanted { print $4 "\t" $5 }')
    log "🟢 ${COLOR_GREEN}✓ Moved group to recovery folder:${COLOR_RESET} ${COLOR_BOLD}$group${COLOR_RESET}"
  done 3<"$groups_file"

  rm -f "$groups_file"

  if [[ -n "$QUARANTINE_ROOT" ]]; then
    log ""
    log "Recovery folder: $QUARANTINE_ROOT"
    log "Review it later and empty Trash when you are confident everything still works."
  fi
}

# Scan helpers keep find invocation details out of the main flow.
scan_literal_paths() {
  local title="$1"
  local risk="$2"
  shift
  shift

  local path

  for path in "$@"; do
    if [[ -e "$path" || -L "$path" ]]; then
      record_path "$title" "$risk" "$path"
    fi
  done
}

scan_dir_contents_older_than() {
  local title="$1"
  local risk="$2"
  shift
  shift

  local dir
  local path

  for dir in "$@"; do
    if [[ ! -d "$dir" ]]; then
      continue
    fi

    while IFS= read -r -d '' path; do
      record_path "$title" "$risk" "$path"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -mtime +"$OLDER_THAN_DAYS" -print0 2>/dev/null)
  done
}

scan_find() {
  local title="$1"
  local risk="$2"
  local root="$3"
  shift 3

  if [[ ! -d "$root" ]]; then
    return
  fi

  local path

  while IFS= read -r -d '' path; do
    record_path "$title" "$risk" "$path"
  done < <(find "$root" "$@" -print0 2>/dev/null)
}

run_docker_cleanup() {
  log ""
  log "== Docker cleanup =="

  if ! command -v docker >/dev/null 2>&1; then
    log "Skipped: docker is not installed."
    return
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Would run: docker system df"
    docker system df 2>/dev/null || warn "Docker is installed but not currently available."
    log "Would run: docker builder prune --force"
    log "Would run: docker system prune --force"
  else
    if ! confirm_docker_cleanup; then
      return
    fi
    docker builder prune --force
    docker system prune --force
    log "🟢 ${COLOR_GREEN}✓ Completed Docker cleanup.${COLOR_RESET}"
  fi
}

scan_default_cleanup() {
  # Step 1: scan conservative, generally regenerable caches and logs.
  scan_dir_contents_older_than "User cache contents older than threshold" "low" \
    "$HOME_DIR/Library/Caches" \
    "$HOME_DIR/Library/Containers/com.apple.Safari/Data/Library/Caches" \
    "$HOME_DIR/Library/Application Support/Code/Cache" \
    "$HOME_DIR/Library/Application Support/Code/CachedData" \
    "$HOME_DIR/Library/Application Support/Code/Service Worker/CacheStorage" \
    "$HOME_DIR/Library/Application Support/Cursor/Cache" \
    "$HOME_DIR/Library/Application Support/Cursor/CachedData" \
    "$HOME_DIR/.cache"

  # Chrome & Brave caches (All profiles dynamically)
  local browser_dir cache_dir
  for browser_dir in \
    "$HOME_DIR/Library/Application Support/Google/Chrome" \
    "$HOME_DIR/Library/Application Support/BraveSoftware/Brave-Browser"
  do
    if [[ -d "$browser_dir" ]]; then
      while IFS= read -r -d '' cache_dir; do
        scan_dir_contents_older_than "User cache contents older than threshold" "low" "$cache_dir"
      done < <(find "$browser_dir" -maxdepth 2 -type d '(' -name "Cache" -o -name "Code Cache" ')' -print0 2>/dev/null)
    fi
  done

  scan_find "Firefox browser caches" "low" "$HOME_DIR/Library/Application Support/Firefox/Profiles" \
    -type d '(' -name cache2 -o -name startupCache ')'

  scan_find "Old user logs" "low" "$HOME_DIR/Library/Logs" \
    -type f -mtime +"$OLDER_THAN_DAYS" ! -path "$HOME_DIR/Library/Logs/CoreSimulator/*" ! -path "$HOME_DIR/Library/Logs/DiagnosticReports/*"

  scan_find "Crash reports older than threshold" "medium" "$HOME_DIR/Library/Logs/DiagnosticReports" \
    -type f -mtime +"$OLDER_THAN_DAYS"

  scan_find "Temporary files older than threshold" "low" "${TMPDIR:-/tmp}" \
    -mindepth 1 -maxdepth 1 -mtime +"$OLDER_THAN_DAYS"

  # Step 2: scan developer caches. These are usually rebuildable but can make
  # the next install, build, or simulator launch slower.
  scan_literal_paths "Developer caches" "medium" \
    "$HOME_DIR/Library/Caches/go-build" \
    "$HOME_DIR/Library/Caches/CocoaPods" \
    "$HOME_DIR/Library/Developer/Xcode/DerivedData" \
    "$HOME_DIR/Library/Developer/CoreSimulator/Caches" \
    "$HOME_DIR/Library/Caches/Homebrew" \
    "$HOME_DIR/Library/Caches/pip" \
    "$HOME_DIR/.npm/_cacache" \
    "$HOME_DIR/.yarn/cache" \
    "$HOME_DIR/.cargo/registry/cache" \
    "$HOME_DIR/.gradle/caches"

  if [[ "$INCLUDE_XCODE_ARCHIVES" -eq 1 ]]; then
    scan_find "Old Xcode archives" "high" "$HOME_DIR/Library/Developer/Xcode/Archives" \
      -mindepth 2 -maxdepth 2 -type d -name '*.xcarchive' -mtime +"$OLDER_THAN_DAYS"
  else
    record_skipped "Old Xcode archives" "Use --include-xcode-archives to include Organizer archives older than the threshold."
  fi

  scan_find "Old iOS simulator logs" "low" "$HOME_DIR/Library/Logs/CoreSimulator" \
    -type f -mtime +"$OLDER_THAN_DAYS"

  # Step 3: scan high-impact personal areas only when explicitly opted in.
  if [[ "$INCLUDE_DOWNLOADS" -eq 1 ]]; then
    scan_find "Downloads older than threshold" "high" "$HOME_DIR/Downloads" \
      -mindepth 1 -maxdepth 1 -mtime +"$OLDER_THAN_DAYS"
  else
    record_skipped "Downloads older than threshold" "Use --include-downloads to include ~/Downloads."
  fi

  if [[ "$EMPTY_TRASH" -eq 1 ]]; then
    scan_find "Trash" "high" "$HOME_DIR/.Trash" \
      -mindepth 1 -maxdepth 1
  else
    record_skipped "Trash" "Use --empty-trash to include ~/.Trash."
  fi
}

scan_large_files() {
  local root path bytes

  for root in \
    "$HOME_DIR/Desktop" \
    "$HOME_DIR/Documents" \
    "$HOME_DIR/Downloads" \
    "$HOME_DIR/Movies" \
    "$HOME_DIR/Music" \
    "$HOME_DIR/Pictures"
  do
    if [[ ! -d "$root" ]]; then
      continue
    fi

    while IFS= read -r -d '' path; do
      bytes="$(file_size_bytes "$path")"
      if [[ "$bytes" -ge "$MIN_SIZE_BYTES" ]]; then
        record_path "Large files older than threshold" "high" "$path"
      fi
    done < <(find "$root" -name '.*' -prune -o -type f -mtime +"$OLDER_THAN_DAYS" -print0 2>/dev/null)
  done
}

scan_editor_old_extensions() {
  local title="$1"
  local root="$2"
  local entries_file path key mtime

  if [[ ! -d "$root" ]]; then
    record_skipped "$title" "Extension directory not found."
    return
  fi

  entries_file="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-extensions.XXXXXX")"

  while IFS= read -r -d '' path; do
    key="$(extension_identity "$path")"
    mtime="$(path_mtime_seconds "$path")"
    printf '%s\t%s\t%s\n' "$key" "$mtime" "$path" >>"$entries_file"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

  if [[ ! -s "$entries_file" ]]; then
    rm -f "$entries_file"
    return
  fi

  while IFS= read -r path; do
    record_path "$title" "medium" "$path"
  done < <(
    LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2nr "$entries_file" |
      awk -F '\t' '
        previous != $1 {
          previous = $1
          seen = 0
        }
        {
          seen += 1
          if (seen > 1) print $3
        }
      '
  )

  rm -f "$entries_file"
}

scan_dev_clean() {
  scan_editor_old_extensions "Old VS Code extension versions" "$HOME_DIR/.vscode/extensions"
  scan_editor_old_extensions "Old Cursor extension versions" "$HOME_DIR/.cursor/extensions"
}

print_simulator_runtime_report() {
  local root="/Library/Developer/CoreSimulator/Profiles/Runtimes"
  local runtime found=0 size

  log ""
  log "${COLOR_BOLD}== iOS Simulator runtimes report ==${COLOR_RESET}"
  if [[ ! -d "$root" ]]; then
    log "Skipped: $root not found."
    return
  fi

  while IFS= read -r -d '' runtime; do
    found=1
    size="$(summary_bytes "$(path_size_bytes "$runtime")")"
    printf '  %-12s %s\n' "$size" "$(display_path "$runtime")"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name '*.simruntime' -print0 2>/dev/null)

  if [[ "$found" -eq 0 ]]; then
    log "No simulator runtimes found."
  else
    log "${COLOR_DIM}Review-only. This command does not remove simulator runtimes.${COLOR_RESET}"
  fi
}

print_homebrew_cleanup_review() {
  log ""
  log "${COLOR_BOLD}== Homebrew cleanup review ==${COLOR_RESET}"
  if [[ "$INCLUDE_BREW" -eq 0 ]]; then
    log "Skipped: use --include-brew to run 'brew cleanup -n' review."
    return
  fi

  if ! command -v brew >/dev/null 2>&1; then
    log "Skipped: brew is not installed."
    return
  fi

  log "Running dry-run: brew cleanup -n"
  brew cleanup -n 2>/dev/null || warn "brew cleanup -n failed."
  log "${COLOR_DIM}Report-only. Run 'brew cleanup' manually after reviewing the dry-run output.${COLOR_RESET}"
}

print_dev_clean_review_reports() {
  if [[ "$COMMAND" != "dev-clean" ]]; then
    return
  fi

  print_homebrew_cleanup_review
  print_simulator_runtime_report
}

scan_uninstall_name_matches() {
  local group="$1"
  local risk="$2"
  local root="$3"
  local name="$4"
  local reason="$5"

  if [[ -z "$name" || ! -d "$root" ]]; then
    return
  fi

  record_inspection_path "$group" "$risk" "$root/$name" "$reason"
}

scan_uninstall_group_containers() {
  local bundle_id="$1"
  local root="$HOME_DIR/Library/Group Containers"
  local path

  if [[ -z "$bundle_id" || ! -d "$root" ]]; then
    return
  fi

  while IFS= read -r -d '' path; do
    record_inspection_path "App containers" "high" "$path" "matched by Bundle ID group-container pattern: $bundle_id"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -name "*$bundle_id*" -print0 2>/dev/null)
}

scan_uninstall() {
  local app="$UNINSTALL_TARGET"
  local info_plist bundle_id app_name display_name bundle_name

  if [[ -z "$app" ]]; then
    die "uninstall requires an .app path."
  fi
  if [[ ! -d "$app" || "$app" != *.app ]]; then
    die "uninstall requires a macOS .app bundle path."
  fi

  info_plist="$app/Contents/Info.plist"
  if [[ ! -f "$info_plist" ]]; then
    die "Missing app Info.plist: $info_plist"
  fi

  bundle_id="$(plist_value "$info_plist" CFBundleIdentifier || true)"
  app_name="$(app_bundle_name "$app")"
  display_name="$(plist_value "$info_plist" CFBundleDisplayName || true)"
  bundle_name="$(plist_value "$info_plist" CFBundleName || true)"

  log ""
  log "${COLOR_BOLD}== App metadata ==${COLOR_RESET}"
  log "App Bundle:    $(display_path "$app")"
  log "App Name:      ${app_name:-<unknown>}"
  log "Bundle ID:     ${bundle_id:-<not found>}"
  if [[ -n "$display_name" && "$display_name" != "$app_name" ]]; then
    log "Display Name:  $display_name"
  fi

  record_inspection_path "Application bundle" "high" "$app" "selected app bundle"

  if [[ -n "$app_name" ]]; then
    scan_uninstall_name_matches "App support files" "high" "$HOME_DIR/Library/Application Support" "$app_name" "matched by app bundle name: $app_name"
    scan_uninstall_name_matches "App caches" "high" "$HOME_DIR/Library/Caches" "$app_name" "matched by app bundle name: $app_name"
    scan_uninstall_name_matches "App logs" "high" "$HOME_DIR/Library/Logs" "$app_name" "matched by app bundle name: $app_name"
  fi
  if [[ -n "$display_name" && "$display_name" != "$app_name" ]]; then
    scan_uninstall_name_matches "App support files" "high" "$HOME_DIR/Library/Application Support" "$display_name" "matched by display name: $display_name"
    scan_uninstall_name_matches "App caches" "high" "$HOME_DIR/Library/Caches" "$display_name" "matched by display name: $display_name"
    scan_uninstall_name_matches "App logs" "high" "$HOME_DIR/Library/Logs" "$display_name" "matched by display name: $display_name"
  fi
  if [[ -n "$bundle_name" && "$bundle_name" != "$app_name" && "$bundle_name" != "$display_name" ]]; then
    scan_uninstall_name_matches "App support files" "high" "$HOME_DIR/Library/Application Support" "$bundle_name" "matched by bundle name: $bundle_name"
    scan_uninstall_name_matches "App caches" "high" "$HOME_DIR/Library/Caches" "$bundle_name" "matched by bundle name: $bundle_name"
    scan_uninstall_name_matches "App logs" "high" "$HOME_DIR/Library/Logs" "$bundle_name" "matched by bundle name: $bundle_name"
  fi
  if [[ -n "$bundle_id" ]]; then
    scan_uninstall_name_matches "App support files" "high" "$HOME_DIR/Library/Application Support" "$bundle_id" "matched by Bundle ID: $bundle_id"
    scan_uninstall_name_matches "App caches" "high" "$HOME_DIR/Library/Caches" "$bundle_id" "matched by Bundle ID: $bundle_id"
    scan_uninstall_name_matches "App logs" "high" "$HOME_DIR/Library/Logs" "$bundle_id" "matched by Bundle ID: $bundle_id"
  fi

  if [[ -n "$bundle_id" ]]; then
    record_inspection_path "App preferences" "high" "$HOME_DIR/Library/Preferences/$bundle_id.plist" "matched by Bundle ID preference file: $bundle_id"
    record_inspection_path "App containers" "high" "$HOME_DIR/Library/Containers/$bundle_id" "matched by Bundle ID container: $bundle_id"
    scan_uninstall_group_containers "$bundle_id"
  else
    record_skipped "Bundle ID matches" "Bundle ID was not found in Info.plist, so bundle-specific paths were skipped."
  fi
}

add_application_record() {
  local app="$1"
  local info_plist name bundle_id version disk_usage apparent_size installed modified last_used now stale_after note report_file

  info_plist="$app/Contents/Info.plist"
  if [[ ! -f "$info_plist" ]]; then
    return
  fi

  name="$(plist_value "$info_plist" CFBundleDisplayName || true)"
  if [[ -z "$name" ]]; then
    name="$(plist_value "$info_plist" CFBundleName || true)"
  fi
  if [[ -z "$name" ]]; then
    name="$(app_bundle_name "$app")"
  fi

  bundle_id="$(plist_value "$info_plist" CFBundleIdentifier || true)"
  version="$(plist_value "$info_plist" CFBundleShortVersionString || true)"
  if [[ -z "$version" ]]; then
    version="$(plist_value "$info_plist" CFBundleVersion || true)"
  fi

  disk_usage="$(path_size_bytes "$app")"
  apparent_size="$(apparent_path_size_bytes "$app")"
  installed="$(path_birth_seconds "$app")"
  modified="$(path_mtime_seconds "$app")"
  last_used="$(app_last_used_seconds "$app")"
  now="$(current_epoch_seconds)"
  stale_after="$((STALE_DAYS * 24 * 60 * 60))"
  note=""

  if [[ "$last_used" -gt 0 && $((now - last_used)) -ge "$stale_after" ]]; then
    note="$(add_note "$note" "stale")"
  elif [[ "$last_used" -eq 0 ]]; then
    note="$(add_note "$note" "last-opened unknown")"
  fi
  if [[ "$disk_usage" -ge "$MIN_SIZE_BYTES" ]]; then
    note="$(add_note "$note" "large")"
  fi
  if [[ "$bundle_id" == com.apple.* || "$app" == /System/Applications/* ]]; then
    note="$(add_note "$note" "Apple/system app")"
  fi

  app_inventory_file
  report_file="$APP_REPORT_FILE"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$disk_usage" "$apparent_size" "$name" "${version:-unknown}" "${bundle_id:-unknown}" \
    "$installed" "$last_used" "$modified" "$app" "${note:-review}" >>"$report_file"

  ITEMS_FOUND="$((ITEMS_FOUND + 1))"
  TOTAL_BYTES="$((TOTAL_BYTES + disk_usage))"
}

scan_applications() {
  local root app

  if [[ "${#APPLICATION_ROOTS[@]}" -eq 0 ]]; then
    APPLICATION_ROOTS=("/Applications" "$HOME_DIR/Applications")
  fi

  for root in "${APPLICATION_ROOTS[@]}"; do
    if [[ ! -d "$root" ]]; then
      record_skipped "Application root" "$root not found."
      continue
    fi

    while IFS= read -r -d '' app; do
      add_application_record "$app"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print0 2>/dev/null)
  done
}

print_applications_console_report() {
  local report_file="${APP_REPORT_FILE:-}"

  log ""
  log "${COLOR_BOLD}== Applications report ==${COLOR_RESET}"

  if [[ -z "$report_file" || ! -s "$report_file" ]]; then
    log "No applications found."
    return
  fi

  printf "%-30s %12s %12s %-12s %-12s %-12s %s\n" "App" "Apparent" "Disk Usage" "Installed" "Last Opened" "Version" "Notes"
  LC_ALL=C sort -t "$(printf '\t')" -k1,1nr "$report_file" | awk -F '\t' '
    function human(bytes, units, i) {
      if (bytes == 0) return "empty"
      split("B KiB MiB GiB TiB", units, " ")
      i = 1
      while (bytes >= 1024 && i < 5) { bytes /= 1024; i++ }
      return sprintf("%.1f %s", bytes, units[i])
    }
    function date_or_unknown(epoch, cmd, out) {
      if (epoch == 0) return "unknown"
      cmd = "date -r " epoch " +%Y-%m-%d 2>/dev/null"
      cmd | getline out
      close(cmd)
      if (out == "") return "unknown"
      return out
    }
    {
      name = $3
      if (length(name) > 29) name = substr(name, 1, 26) "..."
      printf "%-30s %12s %12s %-12s %-12s %-12s %s\n",
        name, human($2), human($1), date_or_unknown($6), date_or_unknown($7), $4, $10
    }
  '

  if [[ -n "$REPORT_OUTPUT" ]]; then
    log ""
    log "Markdown report written to: $REPORT_OUTPUT"
  fi
}

write_applications_markdown_table() {
  local title="$1"
  local input="$2"
  local limit="${3:-0}"
  local count=0
  local disk_usage apparent_size name version bundle_id installed last_used modified path note command

  printf '## %s\n\n' "$title"
  printf '| App | Version | Apparent Size | Disk Usage | Installed | Last Opened | Modified | Bundle ID | Notes | Inspect Command | Path |\n'
  printf '| --- | --- | ---: | ---: | --- | --- | --- | --- | --- | --- | --- |\n'

  while IFS="$(printf '\t')" read -r disk_usage apparent_size name version bundle_id installed last_used modified path note; do
    if [[ "$limit" -gt 0 && "$count" -ge "$limit" ]]; then
      break
    fi
    command="$(uninstall_inspect_command "$path")"
    printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | \`%s\` | \`%s\` |\n" \
      "$(markdown_escape "$name")" \
      "$(markdown_escape "$version")" \
      "$(summary_bytes "$apparent_size")" \
      "$(summary_bytes "$disk_usage")" \
      "$(format_epoch_date "$installed")" \
      "$(format_epoch_date "$last_used")" \
      "$(format_epoch_date "$modified")" \
      "$(markdown_escape "$bundle_id")" \
      "$(markdown_escape "$note")" \
      "$(markdown_inline_code_escape "$command")" \
      "$(markdown_inline_code_escape "$path")"
    count="$((count + 1))"
  done <"$input"

  if [[ "$count" -eq 0 ]]; then
    printf '| _No matching apps._ |  |  |  |  |  |  |  |  |  |  |\n'
  fi

  printf '\n'
}

write_applications_markdown() {
  local output="$REPORT_OUTPUT"
  local report_file="${APP_REPORT_FILE:-}"
  local sorted_file stale_file unknown_file

  if [[ -z "$output" ]]; then
    return
  fi

  sorted_file="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-apps-sorted.XXXXXX")"
  stale_file="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-apps-stale.XXXXXX")"
  unknown_file="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-apps-unknown.XXXXXX")"

  if [[ -n "$report_file" && -s "$report_file" ]]; then
    LC_ALL=C sort -t "$(printf '\t')" -k1,1nr "$report_file" >"$sorted_file"
    awk -F '\t' '$10 ~ /(^|, )stale(,|$)/' "$report_file" | LC_ALL=C sort -t "$(printf '\t')" -k7,7n >"$stale_file"
    awk -F '\t' '$10 ~ /last-opened unknown/' "$report_file" | LC_ALL=C sort -t "$(printf '\t')" -k1,1nr >"$unknown_file"
  fi

  {
    printf '# Installed Applications Report\n\n'
    printf 'Generated: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Stale threshold: not opened in %s day(s)\n\n' "$STALE_DAYS"
    printf 'Use the Inspect Command column to review app-related files before deleting anything.\n\n'

    write_applications_markdown_table "All Applications" "$sorted_file"
    write_applications_markdown_table "Possibly Stale Apps" "$stale_file"
    write_applications_markdown_table "Largest Apps" "$sorted_file" 10
    write_applications_markdown_table "Unknown Last Opened" "$unknown_file"
  } >"$output"

  rm -f "$sorted_file" "$stale_file" "$unknown_file"
}

add_startup_plist_record() {
  local scope="$1"
  local plist="$2"
  local label program run_at_load keep_alive disabled modified size note report_file now recent_after

  label="$(plist_value "$plist" Label || true)"
  if [[ -z "$label" ]]; then
    label="$(basename "$plist" .plist)"
  fi
  label="$(one_line_field "$label")"

  program="$(plist_value "$plist" Program || true)"
  if [[ -z "$program" ]]; then
    program="$(plist_array_first_value "$plist" ProgramArguments || true)"
  fi
  if [[ -z "$program" ]]; then
    program="unknown"
  fi
  program="$(one_line_field "$program")"

  run_at_load="$(plist_value "$plist" RunAtLoad || true)"
  keep_alive="$(plist_value "$plist" KeepAlive || true)"
  disabled="$(plist_value "$plist" Disabled || true)"
  run_at_load="$(startup_bool_field "$run_at_load")"
  keep_alive="$(startup_bool_field "$keep_alive")"
  disabled="$(one_line_field "${disabled:-unknown}")"
  [[ -z "$disabled" ]] && disabled="unknown"
  modified="$(path_mtime_seconds "$plist")"
  size="$(path_size_bytes "$plist")"
  note=""

  if [[ "$run_at_load" == "true" ]]; then
    note="$(add_note "$note" "auto-start")"
  fi
  if [[ "$keep_alive" == "true" || "$keep_alive" == "dict" ]]; then
    note="$(add_note "$note" "keepalive")"
  fi
  if [[ "$scope" == "daemon" ]]; then
    note="$(add_note "$note" "system-wide")"
  elif [[ "$scope" == "global-agent" ]]; then
    note="$(add_note "$note" "global")"
  fi
  if [[ "$label" == com.apple.* || "$plist" == /System/Library/* ]]; then
    note="$(add_note "$note" "Apple/system item")"
  else
    note="$(add_note "$note" "third-party item")"
  fi
  if [[ "$program" == /* && ! -e "$program" ]]; then
    note="$(add_note "$note" "missing program path")"
  fi
  now="$(current_epoch_seconds)"
  recent_after="$((30 * 24 * 60 * 60))"
  if [[ "$modified" -gt 0 && $((now - modified)) -le "$recent_after" ]]; then
    note="$(add_note "$note" "recently modified")"
  fi
  note="${note:-review}"

  startup_report_file
  report_file="$STARTUP_REPORT_FILE"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$scope" "$label" "$program" "$run_at_load" "$keep_alive" "$disabled" "$modified" "$size" "$plist" "$note" >>"$report_file"

  ITEMS_FOUND="$((ITEMS_FOUND + 1))"
  TOTAL_BYTES="$((TOTAL_BYTES + size))"
}

scan_startup_plist_dir() {
  local scope="$1"
  local root="$2"
  local plist

  if [[ ! -d "$root" ]]; then
    record_skipped "Startup $scope" "$root not found."
    return
  fi

  while IFS= read -r -d '' plist; do
    add_startup_plist_record "$scope" "$plist"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type f -name '*.plist' -print0 2>/dev/null)
}

scan_login_items() {
  local names name report_file

  if ! command -v osascript >/dev/null 2>&1; then
    record_skipped "Login Items" "osascript is not available."
    return
  fi

  names="$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null || true)"
  if [[ -z "$names" ]]; then
    record_skipped "Login Items" "Login Items could not be read or none were found."
    return
  fi

  startup_report_file
  report_file="$STARTUP_REPORT_FILE"
  while IFS= read -r name; do
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    if [[ -z "$name" ]]; then
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "login-item" "$name" "unknown" "true" "false" "unknown" "0" "0" "System Settings Login Items" "login item" >>"$report_file"
    ITEMS_FOUND="$((ITEMS_FOUND + 1))"
  done < <(printf '%s' "$names" | tr ',' '\n')
}

scan_startup() {
  scan_startup_plist_dir "user-agent" "$HOME_DIR/Library/LaunchAgents"
  scan_startup_plist_dir "global-agent" "/Library/LaunchAgents"
  scan_startup_plist_dir "daemon" "/Library/LaunchDaemons"
  scan_login_items
}

print_startup_console_report() {
  local report_file="${STARTUP_REPORT_FILE:-}"

  log ""
  log "${COLOR_BOLD}== Startup items report ==${COLOR_RESET}"

  if [[ -z "$report_file" || ! -s "$report_file" ]]; then
    log "No startup items found."
    return
  fi

  printf "%-13s %-35s %-9s %-9s %-10s %s\n" "Scope" "Label" "RunLoad" "KeepAlive" "Disabled" "Program"
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 "$report_file" | awk -F '\t' '
    {
      label = $2
      program = $3
      if (length(label) > 34) label = substr(label, 1, 31) "..."
      if (length(program) > 50) program = substr(program, 1, 47) "..."
      printf "%-13s %-35s %-9s %-9s %-10s %s\n", $1, label, $4, $5, $6, program
    }
  '

  if [[ -n "$REPORT_OUTPUT" ]]; then
    log ""
    log "Markdown report written to: $REPORT_OUTPUT"
  fi
}

write_startup_markdown_table() {
  local title="$1"
  local input="$2"
  local count=0
  local scope label program run_at_load keep_alive disabled modified size path note

  printf '## %s\n\n' "$title"
  printf '| Scope | Label | Program | RunAtLoad | KeepAlive | Disabled | Modified | Size | Notes | Path |\n'
  printf '| --- | --- | --- | --- | --- | --- | --- | ---: | --- | --- |\n'

  while IFS="$(printf '\t')" read -r scope label program run_at_load keep_alive disabled modified size path note; do
    printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | \`%s\` |\n" \
      "$(markdown_escape "$scope")" \
      "$(markdown_escape "$label")" \
      "$(markdown_escape "$program")" \
      "$(markdown_escape "$run_at_load")" \
      "$(markdown_escape "$keep_alive")" \
      "$(markdown_escape "$disabled")" \
      "$(format_epoch_date "$modified")" \
      "$(summary_bytes "$size")" \
      "$(markdown_escape "$note")" \
      "$(markdown_inline_code_escape "$path")"
    count="$((count + 1))"
  done <"$input"

  if [[ "$count" -eq 0 ]]; then
    printf '| _No matching startup items._ |  |  |  |  |  |  |  |  |  |\n'
  fi

  printf '\n'
}

write_startup_markdown() {
  local output="$REPORT_OUTPUT"
  local report_file="${STARTUP_REPORT_FILE:-}"
  local sorted_file user_file system_file active_file missing_file

  if [[ -z "$output" ]]; then
    return
  fi

  sorted_file="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-startup-sorted.XXXXXX")"
  user_file="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-startup-user.XXXXXX")"
  system_file="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-startup-system.XXXXXX")"
  active_file="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-startup-active.XXXXXX")"
  missing_file="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-startup-missing.XXXXXX")"

  if [[ -n "$report_file" && -s "$report_file" ]]; then
    LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 "$report_file" >"$sorted_file"
    awk -F '\t' '$1 == "user-agent" || $1 == "login-item"' "$report_file" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 >"$user_file"
    awk -F '\t' '$1 == "global-agent" || $1 == "daemon"' "$report_file" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 >"$system_file"
    awk -F '\t' '$10 ~ /auto-start|keepalive/' "$report_file" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 >"$active_file"
    awk -F '\t' '$10 ~ /missing program path/' "$report_file" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 >"$missing_file"
  fi

  {
    printf '# Startup Items Report\n\n'
    printf 'Generated: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'This report is inspect-only. It does not disable or remove startup items.\n\n'
    write_startup_markdown_table "All Startup Items" "$sorted_file"
    write_startup_markdown_table "User Startup Items" "$user_file"
    write_startup_markdown_table "System-wide Startup Items" "$system_file"
    write_startup_markdown_table "Auto-start or KeepAlive Items" "$active_file"
    write_startup_markdown_table "Missing Program Paths" "$missing_file"
  } >"$output"

  rm -f "$sorted_file" "$user_file" "$system_file" "$active_file" "$missing_file"
}

# Parse options after config load so CLI flags can override saved preferences.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      scan|large-files|dev-clean|applications|startup|uninstall)
        if [[ "$COMMAND_SET" -eq 1 ]]; then
          warn "Only one command can be used at a time."
          exit 2
        fi
        COMMAND="$1"
        COMMAND_SET=1
        ;;
      --uninstall)
        if [[ "$COMMAND_SET" -eq 1 ]]; then
          warn "Only one command can be used at a time."
          exit 2
        fi
        if [[ $# -lt 2 ]]; then
          warn "$1 requires an .app path."
          exit 2
        fi
        COMMAND="uninstall"
        COMMAND_SET=1
        UNINSTALL_TARGET="$2"
        shift
        ;;
      -e|--execute)
        DRY_RUN=0
        ;;
      -d|--dry-run)
        DRY_RUN=1
        ;;
      -o|--older-than)
        if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then
          warn "$1 requires a non-negative integer."
          exit 2
        fi
        OLDER_THAN_DAYS="$2"
        shift
        ;;
      --min-size)
        if [[ $# -lt 2 ]]; then
          warn "$1 requires a size such as 100M or 1G."
          exit 2
        fi
        if ! MIN_SIZE_BYTES="$(parse_size_bytes "$2")"; then
          warn "$1 requires a size such as 100M or 1G."
          exit 2
        fi
        shift
        ;;
      --stale-days)
        if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then
          warn "$1 requires a non-negative integer."
          exit 2
        fi
        STALE_DAYS="$2"
        shift
        ;;
      --app-root)
        if [[ $# -lt 2 ]]; then
          warn "$1 requires a directory path."
          exit 2
        fi
        APPLICATION_ROOTS+=("$2")
        shift
        ;;
      --output)
        if [[ $# -lt 2 ]]; then
          warn "$1 requires a file path."
          exit 2
        fi
        REPORT_OUTPUT="$2"
        shift
        ;;
      --include-downloads)
        INCLUDE_DOWNLOADS=1
        ;;
      --include-docker)
        INCLUDE_DOCKER=1
        ;;
      --include-brew)
        INCLUDE_BREW=1
        ;;
      -i|--interactive)
        INTERACTIVE=1
        ;;
      --include-xcode-archives)
        INCLUDE_XCODE_ARCHIVES=1
        ;;
      --empty-trash)
        EMPTY_TRASH=1
        ;;
      -y|--yes)
        YES=1
        ;;
      -v|--verbose)
        VERBOSE=1
        ;;
      -s|--show-files)
        SHOW_FILES=1
        ;;
      --clean-log)
        CLEAN_LOG=1
        ;;
      -n|--no-color)
        COLOR_DISABLED=1
        ;;
      -V|--version)
        log "$VERSION"
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [[ "$COMMAND" == "uninstall" && -z "$UNINSTALL_TARGET" && "$1" != -* ]]; then
          UNINSTALL_TARGET="$1"
        elif [[ "$1" == -* ]]; then
          warn "Unknown option: $1. Try 'mac-cleaner.sh --help' for more information."
          exit 2
        else
          warn "Unknown command or argument: $1. Try 'mac-cleaner.sh --help' for more information."
          exit 2
        fi
        ;;
    esac
    shift
  done
}

main() {
  # Quick pre-scan for color preference
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "-n" || "$arg" == "--no-color" ]]; then
      COLOR_DISABLED=1
    fi
  done

  # Enable color if stdout is a TTY and colors are not explicitly disabled
  if [[ "$COLOR_DISABLED" -eq 0 ]] && [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    enable_color
  fi

  load_config
  parse_args "$@"

  if [[ "$COMMAND" == "uninstall" && "$DRY_RUN" -eq 0 ]]; then
    die "uninstall is inspect-only for now. Re-run without --execute."
  fi
  if [[ "$COMMAND" == "applications" && "$DRY_RUN" -eq 0 ]]; then
    die "applications is report-only. Re-run without --execute."
  fi
  if [[ "$COMMAND" == "startup" && "$DRY_RUN" -eq 0 ]]; then
    die "startup is report-only. Re-run without --execute."
  fi

  if [[ "$COMMAND" != "scan" && "$VERBOSE" -eq 0 && "$SHOW_FILES" -eq 0 ]]; then
    SHOW_FILES=1
  fi

  if [[ "$COLOR_DISABLED" -eq 1 ]]; then
    disable_color
  fi

  if [[ -z "$HOME_DIR" || "$HOME_DIR" == "/" ]]; then
    die "Refusing to run with unsafe HOME: ${HOME_DIR:-<empty>}"
  fi

  LOG_FILE="$(default_log_file)"

  if [[ "$CLEAN_LOG" -eq 1 ]]; then
    clean_log_file "$LOG_FILE"
    exit 0
  fi

  setup_plan_file

  local mode_str="${COLOR_GREEN}Dry Run (Safe mode, preview only)${COLOR_RESET}"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mode_str="${COLOR_YELLOW}Execute (Move selected files to Trash)${COLOR_RESET}"
  fi

  local visual_log_file="$LOG_FILE"
  visual_log_file="${visual_log_file//"$HOME_DIR"/~}"

  log ""
  log "${COLOR_BOLD}${COLOR_CYAN}✨ mac-cleaner v${VERSION}${COLOR_RESET}"
  log "${COLOR_DIM}────────────────────────────────────────────────────────${COLOR_RESET}"
  log "${COLOR_BOLD}Command:${COLOR_RESET}       $COMMAND"
  log "${COLOR_BOLD}Mode:${COLOR_RESET}          $mode_str"
  log "${COLOR_BOLD}Log File:${COLOR_RESET}      $visual_log_file"
  if [[ "$COMMAND" != "dev-clean" && "$COMMAND" != "uninstall" && "$COMMAND" != "applications" && "$COMMAND" != "startup" ]]; then
    log "${COLOR_BOLD}Age Threshold:${COLOR_RESET} > $OLDER_THAN_DAYS day(s)"
  fi
  if [[ "$COMMAND" == "large-files" ]]; then
    log "${COLOR_BOLD}Min File Size:${COLOR_RESET}  $(summary_bytes "$MIN_SIZE_BYTES")"
  elif [[ "$COMMAND" == "applications" ]]; then
    log "${COLOR_BOLD}Stale Threshold:${COLOR_RESET} > $STALE_DAYS day(s)"
    log "${COLOR_BOLD}Large App Size:${COLOR_RESET}  $(summary_bytes "$MIN_SIZE_BYTES")"
  fi
  log "${COLOR_DIM}────────────────────────────────────────────────────────${COLOR_RESET}"

  configure_interactive_mode

  local scan_start scan_end scan_label
  scan_start="$(date '+%s')"
  scan_label="Scanning cleanup candidates"
  if [[ "$COMMAND" == "large-files" ]]; then
    scan_label="Scanning large files"
  elif [[ "$COMMAND" == "dev-clean" ]]; then
    scan_label="Scanning developer tool artifacts"
  elif [[ "$COMMAND" == "applications" ]]; then
    scan_label="Scanning installed applications"
  elif [[ "$COMMAND" == "startup" ]]; then
    scan_label="Scanning startup items"
  elif [[ "$COMMAND" == "uninstall" ]]; then
    scan_label="Inspecting app-related files"
  fi
  start_scan_activity "$scan_label" "$scan_start"

  case "$COMMAND" in
    scan)
      scan_default_cleanup
      ;;
    large-files)
      scan_large_files
      ;;
    dev-clean)
      scan_dev_clean
      ;;
    applications)
      scan_applications
      ;;
    startup)
      scan_startup
      ;;
    uninstall)
      scan_uninstall
      ;;
    *)
      die "Unsupported command: $COMMAND"
      ;;
  esac

  scan_end="$(date '+%s')"
  SCAN_SECONDS="$((scan_end - scan_start))"
  stop_scan_activity

  # Show the plan or report first, then execute only if requested.
  if [[ "$COMMAND" == "applications" ]]; then
    write_applications_markdown
    print_applications_console_report
  elif [[ "$COMMAND" == "startup" ]]; then
    write_startup_markdown
    print_startup_console_report
  else
    print_plan
    write_dry_run_clean_script
    offer_interactive_execute
    execute_plan
    print_dev_clean_review_reports
  fi

  # Docker cleanup is handled separately because it is permanent.
  if [[ "$COMMAND" == "scan" ]]; then
    if [[ "$INCLUDE_DOCKER" -eq 1 ]]; then
      run_docker_cleanup
    else
      record_skipped "Docker cleanup" "Use --include-docker to prune Docker caches and stopped resources."
    fi
  fi

  # Close with optional skips, a final summary, and next steps.
  print_skipped_optional_groups
  print_final_summary
  print_next_step

  return 0
}

main "$@"
