#!/usr/bin/env bash
set -euo pipefail

VERSION="1.4.0"
DRY_RUN=1
OLDER_THAN_DAYS=14
INCLUDE_DOWNLOADS=0
INCLUDE_DOCKER=0
INCLUDE_XCODE_ARCHIVES=0
EMPTY_TRASH=0
VERBOSE=0
SHOW_FILES=0
YES=0
CLEAN_LOG=0

HOME_DIR="${HOME}"

# Runtime state. These are intentionally not user-configurable.
TOTAL_BYTES=0
ITEMS_FOUND=0
PLAN_FILE=""
SKIPPED_FILE=""
CONFIG_FILE="${HOME}/.mac-cleaner.rc"
XDG_CONFIG_FILE="${HOME}/.config/mac-cleaner/config"
LOG_FILE="" # Set in main
QUARANTINE_ROOT=""

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
  cat <<'EOF'
mac-cleaner.sh - conservative macOS cleanup helper

Usage:
  ./mac-cleaner.sh [options]

Default behavior:
  Scans first, builds a sorted cleanup plan, and prints what can be cleaned.

Options:
  --execute             Move selected files to a recovery folder in ~/.Trash.
  --dry-run             Preview only. This is the default.
  --older-than DAYS     Only remove age-based files older than DAYS. Default: 14.
  --include-downloads   Include old files from ~/Downloads.
  --include-xcode-archives
                        Include old Xcode Organizer archives.
  --empty-trash         Include ~/.Trash contents in the scan.
  --include-docker      Run Docker prune commands if Docker is installed.
  --yes                 Skip low/medium-risk prompts. High-risk groups still ask.
  --verbose             Print compact grouped details.
  --show-files          Print every matched file path.
  --clean-log           Empty the mac-cleaner log file and exit.
  --version             Print version.
  -h, --help            Show this help.

Examples:
  ./mac-cleaner.sh
  ./mac-cleaner.sh --older-than 30 --include-downloads
  ./mac-cleaner.sh --execute --empty-trash

Notes:
  This script avoids protected system folders and defaults to preview mode.
  Use --verbose for human-friendly detail and --show-files for full paths.
  Execute mode shows each group, then asks before moving files.
  Files are moved to ~/.Trash/mac-cleaner-* first, not permanently deleted.
EOF
}

# Logging is best-effort: cleanup scans should not fail just because the log
# directory cannot be created or written.
log() {
  local msg="$*"
  printf '%s\n' "$msg"
  if [[ -n "${LOG_FILE:-}" ]]; then
    { mkdir -p "$(dirname "$LOG_FILE")" && printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE"; } 2>/dev/null || true
  fi
}

warn() {
  local msg="$*"
  printf 'Warning: %s\n' "$msg" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    { mkdir -p "$(dirname "$LOG_FILE")" && printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE"; } 2>/dev/null || true
  fi
}

die() {
  local msg="$*"
  warn "$msg"
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

# Format byte counts for humans. "empty" avoids making zero-byte cache dirs look
# like meaningful reclaimable space.
human_bytes() {
  local bytes="${1:-0}"
  if [[ "$bytes" -eq 0 ]]; then
    printf 'empty'
    return
  fi

  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$bytes"
  else
    awk -v b="$bytes" 'BEGIN {
      split("B KiB MiB GiB TiB", u)
      i=1
      while (b >= 1024 && i < 5) { b /= 1024; i++ }
      printf "%.1f %s", b, u[i]
    }'
  fi
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
setup_plan_file() {
  PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-plan.XXXXXX")"
  SKIPPED_FILE="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-skipped.XXXXXX")"
  trap 'rm -f "$PLAN_FILE" "$SKIPPED_FILE"' EXIT
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

safe_to_delete_path() {
  local path="$1"

  if is_guarded_path "$path"; then
    return 1
  fi

  if [[ "$INCLUDE_XCODE_ARCHIVES" -eq 1 ]] && is_under_path "$path" "$HOME_DIR/Library/Developer/Xcode/Archives"; then
    return 0
  fi

  is_under_path "$path" "$HOME_DIR/Library/Caches" \
    || is_under_path "$path" "$HOME_DIR/Library/Containers/com.apple.Safari/Data/Library/Caches" \
    || is_under_path "$path" "$HOME_DIR/Library/Application Support/Code/Cache" \
    || is_under_path "$path" "$HOME_DIR/Library/Application Support/Code/CachedData" \
    || is_under_path "$path" "$HOME_DIR/Library/Application Support/Code/Service Worker/CacheStorage" \
    || is_under_path "$path" "$HOME_DIR/Library/Application Support/Google/Chrome/Default/Cache" \
    || is_under_path "$path" "$HOME_DIR/Library/Application Support/Google/Chrome/Default/Code Cache" \
    || is_under_path "$path" "$HOME_DIR/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cache" \
    || is_under_path "$path" "$HOME_DIR/.cache" \
    || is_under_path "$path" "$HOME_DIR/Library/Application Support/Firefox/Profiles" \
    || is_under_path "$path" "$HOME_DIR/Library/Logs" \
    || is_under_path "$path" "${TMPDIR:-/tmp}" \
    || [[ "$path" == "$HOME_DIR/Library/Developer/Xcode/DerivedData" ]] \
    || [[ "$path" == "$HOME_DIR/Library/Developer/CoreSimulator/Caches" ]] \
    || [[ "$path" == "$HOME_DIR/Library/Caches/Homebrew" ]] \
    || [[ "$path" == "$HOME_DIR/Library/Caches/pip" ]] \
    || [[ "$path" == "$HOME_DIR/.npm/_cacache" ]] \
    || [[ "$path" == "$HOME_DIR/.yarn/cache" ]] \
    || [[ "$path" == "$HOME_DIR/Library/pnpm/store" ]] \
    || [[ "$path" == "$HOME_DIR/.cargo/registry/cache" ]] \
    || [[ "$path" == "$HOME_DIR/.gradle/caches" ]] \
    || is_under_path "$path" "$HOME_DIR/Downloads" \
    || is_under_path "$path" "$HOME_DIR/.Trash"
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

record_skipped() {
  local group="$1"
  local reason="$2"

  printf '%s\t%s\n' "$group" "$reason" >>"$SKIPPED_FILE"
}

quarantine_path() {
  local path="$1"
  local err_msg
  if ! safe_to_delete_path "$path"; then
    warn "Refusing to move guarded or unexpected path: $path"
    return
  fi

  if [[ -e "$path" || -L "$path" ]]; then
    setup_quarantine_root

    local relative target parent
    case "$path" in
      "$HOME_DIR"/*)
        relative="home/${path#"$HOME_DIR"/}"
        ;;
      "${TMPDIR:-/tmp}"/*)
        relative="tmp/${path#"${TMPDIR:-/tmp}"/}"
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
    fi
  fi
}

# Render the dry-run cleanup plan. The awk block keeps grouping and size
# aggregation close to the sorted plan format.
print_plan() {
  log ""
  log "== Cleanup plan =="

  if [[ "$ITEMS_FOUND" -eq 0 ]]; then
    log "No matching files found."
    return
  fi

  sort_plan | awk -F '\t' -v verbose="$VERBOSE" -v show_files="$SHOW_FILES" -v home="$HOME_DIR" -v tmp="${TMPDIR:-/tmp}" '
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
    function detail_bucket(path, shown, parts) {
      shown = display_path(path)
      split(shown, parts, "/")

      if (parts[1] == "~" && parts[2] == ".cache" && parts[3] != "") {
        return parts[1] "/" parts[2] "/" parts[3]
      }
      if (parts[1] == "~" && parts[2] == ".gradle") {
        return "~/.gradle/caches"
      }
      if (parts[1] == "~" && parts[2] == ".npm") {
        return "~/.npm/_cacache"
      }
      if (parts[1] == "~" && parts[2] == "Library" && parts[3] == "Logs" && parts[4] != "") {
        if (parts[5] == "") {
          return "~/Library/Logs root files"
        }
        return parts[1] "/" parts[2] "/" parts[3] "/" parts[4]
      }
      if (parts[1] == "~" && parts[2] == "Library" && parts[3] == "Caches" && parts[4] != "") {
        if (parts[5] == "") {
          return "~/Library/Caches root files"
        }
        return parts[1] "/" parts[2] "/" parts[3] "/" parts[4]
      }
      if (parts[1] == "~" && parts[2] == "Library" && parts[3] == "Application Support" && parts[4] != "") {
        if (parts[4] == "Code" && parts[5] != "") {
          return parts[1] "/" parts[2] "/" parts[3] "/" parts[4] "/" parts[5]
        }
        return parts[1] "/" parts[2] "/" parts[3] "/" parts[4]
      }
      if (parts[1] == "~" && parts[2] == "Library" && parts[3] == "Developer" && parts[4] != "") {
        return parts[1] "/" parts[2] "/" parts[3] "/" parts[4]
      }
      if (parts[1] == "~" && parts[2] == "Downloads") {
        return "~/Downloads"
      }
      if (parts[1] == "~" && parts[2] == ".Trash") {
        return "~/.Trash"
      }
      if (parts[1] == "$TMPDIR") {
        return "$TMPDIR"
      }
      return shown
    }
    function group_note(group, risk) {
      if (group == "Developer caches") {
        return "Note: Usually safe to regenerate, but the next build, package install, or simulator launch may be slower."
      }
      if (group == "Crash reports older than threshold") {
        return "Note: Useful for troubleshooting older app crashes. Safe to move after review."
      }
      if (group == "Old user logs" || group == "Old iOS simulator logs") {
        return "Note: Logs are usually safe to move, but can help investigate older issues."
      }
      if (group == "User cache contents older than threshold" || group == "Firefox browser caches" || group == "Temporary files older than threshold") {
        return "Note: Usually safe to regenerate. Apps may rebuild these files later."
      }
      if (group == "Downloads older than threshold") {
        return "Note: High-risk personal files. Review each path before approving."
      }
      if (group == "Trash") {
        return "Note: High-risk final review area. Moving these keeps them recoverable in the mac-cleaner folder until Trash is emptied."
      }
      if (group == "Old Xcode archives") {
        return "Note: High-risk release archives. They may contain dSYMs, builds, and submission history."
      }
      if (risk == "low") {
        return "Note: Usually safe to regenerate."
      }
      if (risk == "medium") {
        return "Note: Review first. These may affect workflow or troubleshooting history."
      }
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
      file_order[group SUBSEP file_total[group]] = sprintf("  %s  %s", human(size), display_path(path))
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
        printf "== %s [%s risk] ==\n", group, group_risk[group]
        printf "%s\n", group_note(group, group_risk[group])

        if (show_files != 0) {
          for (j = 1; j <= file_total[group]; j++) {
            print file_order[group SUBSEP j]
          }
        } else if (verbose != 0) {
          for (j = 1; j <= detail_total[group]; j++) {
            detail = detail_order[group SUBSEP j]
            key = group SUBSEP detail
            printf "  %s  %d item(s)  %s\n", human(detail_bytes[key]), detail_count[key], detail
          }
        }

        printf "Found %d item(s), %s.\n", group_count[group], human(group_bytes[group])
        if (i < group_total) {
          printf "\n"
        }
      }
    }
  '
}

sort_plan() {
  LC_ALL=C sort -t "$(printf '\t')" -k2,2n -k1,1 -k5,5 "$PLAN_FILE"
}

print_group_files() {
  local group="$1"

  sort_plan | awk -F '\t' -v wanted="$group" -v home="$HOME_DIR" -v tmp="${TMPDIR:-/tmp}" '
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
      printf "  %s  %s\n", human($4), display_path($5)
    }
  '
}

# Optional groups are shown after the cleanup plan, so users first see what will
# actually be considered.
print_skipped_optional_groups() {
  if [[ ! -s "$SKIPPED_FILE" ]]; then
    return
  fi

  log ""
  log "== Skipped optional groups =="
  awk -F '\t' '{ printf "%s: skipped. %s\n", $1, $2 }' "$SKIPPED_FILE"
}

print_final_summary() {
  log ""
  log "Summary: $ITEMS_FOUND item(s), $(human_bytes "$TOTAL_BYTES") matched."
}

print_next_step() {
  log ""
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Review the paths above. If they look safe, run:"
    log "  ./mac-cleaner.sh --execute"
    log "For a more conservative cleanup, leave Downloads, Trash, Docker, and Xcode archives disabled."
  else
    log "Cleanup complete."
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
    log "Auto-approved by --yes: $group"
    log "Items: $count, size: $size"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    warn "Skipping '$group' because execute mode needs interactive confirmation."
    return 1
  fi

  log ""
  log "Ready to move group to recovery folder: $group"
  log "Risk: $risk - $(group_risk_note "$risk")"
  log "Files to move: $count, total size: $size"
  print_group_files "$group"
  printf 'Move this group to ~/.Trash? [y/N]: '
  local answer
  read -r answer
  if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    return 0
  fi

  log "Skipped group: $group"
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
  log "Ready to run Docker cleanup"
  log "Risk: medium - This permanently removes unused Docker builder cache and stopped resources."
  printf 'Run Docker prune commands? Type PRUNE to confirm, or press Enter to skip: '
  local answer
  read -r answer
  if [[ "$answer" == "PRUNE" ]]; then
    return 0
  fi

  log "Skipped Docker cleanup."
  return 1
}

# Execute the approved plan by group. Each path is rechecked in quarantine_path
# before it is moved.
execute_plan() {
  if [[ "$DRY_RUN" -eq 1 || "$ITEMS_FOUND" -eq 0 ]]; then
    return
  fi

  log ""
  log "== Execute cleanup plan =="
  log "Each group is shown with file names and total size before confirmation."

  local groups_file
  groups_file="$(mktemp "${TMPDIR:-/tmp}/mac-cleaner-groups.XXXXXX")"
  awk -F '\t' '{ bytes[$1] += $4; count[$1] += 1; risk[$1] = $3; rank[$1] = $2 } END { for (group in count) printf "%s\t%s\t%s\t%d\t%d\n", rank[group], group, risk[group], count[group], bytes[group] }' "$PLAN_FILE" \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 >"$groups_file"

  local _rank group risk count bytes path
  while IFS="$(printf '\t')" read -r _rank group risk count bytes; do
    if ! confirm_group_quarantine "$group" "$risk" "$count" "$bytes"; then
      continue
    fi

    sort_plan | awk -F '\t' -v wanted="$group" '$1 == wanted { print $5 }' | while IFS= read -r path; do
      quarantine_path "$path"
    done
    log "Moved group to recovery folder: $group"
  done <"$groups_file"

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
  fi
}

# Parse options after config load so CLI flags can override saved preferences.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --execute)
        DRY_RUN=0
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --older-than)
        if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ ]]; then
          warn "--older-than requires a non-negative integer."
          exit 2
        fi
        OLDER_THAN_DAYS="$2"
        shift
        ;;
      --include-downloads)
        INCLUDE_DOWNLOADS=1
        ;;
      --include-docker)
        INCLUDE_DOCKER=1
        ;;
      --include-xcode-archives)
        INCLUDE_XCODE_ARCHIVES=1
        ;;
      --empty-trash)
        EMPTY_TRASH=1
        ;;
      --yes)
        YES=1
        ;;
      --verbose)
        VERBOSE=1
        ;;
      --show-files)
        SHOW_FILES=1
        ;;
      --clean-log)
        CLEAN_LOG=1
        ;;
      --version)
        log "$VERSION"
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        warn "Unknown option: $1"
        usage
        exit 2
        ;;
    esac
    shift
  done
}

main() {
  load_config
  parse_args "$@"

  if [[ -z "$HOME_DIR" || "$HOME_DIR" == "/" ]]; then
    die "Refusing to run with unsafe HOME: ${HOME_DIR:-<empty>}"
  fi

  LOG_FILE="$(default_log_file)"

  if [[ "$CLEAN_LOG" -eq 1 ]]; then
    clean_log_file "$LOG_FILE"
    exit 0
  fi

  setup_plan_file

  log "mac-cleaner.sh $VERSION"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Mode: dry run. Nothing will be deleted."
  else
    log "Mode: execute. Matching files will be moved to a recovery folder in ~/.Trash."
  fi
  log "Log file: $LOG_FILE"
  log "Age threshold: older than $OLDER_THAN_DAYS day(s)."

  # Step 1: scan conservative, generally regenerable caches and logs.
  scan_dir_contents_older_than "User cache contents older than threshold" "low" \
    "$HOME_DIR/Library/Caches" \
    "$HOME_DIR/Library/Containers/com.apple.Safari/Data/Library/Caches" \
    "$HOME_DIR/Library/Application Support/Code/Cache" \
    "$HOME_DIR/Library/Application Support/Code/CachedData" \
    "$HOME_DIR/Library/Application Support/Code/Service Worker/CacheStorage" \
    "$HOME_DIR/Library/Application Support/Google/Chrome/Default/Cache" \
    "$HOME_DIR/Library/Application Support/Google/Chrome/Default/Code Cache" \
    "$HOME_DIR/Library/Application Support/BraveSoftware/Brave-Browser/Default/Cache" \
    "$HOME_DIR/.cache"

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
    "$HOME_DIR/Library/Developer/Xcode/DerivedData" \
    "$HOME_DIR/Library/Developer/CoreSimulator/Caches" \
    "$HOME_DIR/Library/Caches/Homebrew" \
    "$HOME_DIR/Library/Caches/pip" \
    "$HOME_DIR/.npm/_cacache" \
    "$HOME_DIR/.yarn/cache" \
    "$HOME_DIR/Library/pnpm/store" \
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

  # Step 4: show the plan first, then execute only if requested.
  print_plan
  execute_plan

  # Step 5: Docker cleanup is handled separately because it is permanent.
  if [[ "$INCLUDE_DOCKER" -eq 1 ]]; then
    run_docker_cleanup
  else
    record_skipped "Docker cleanup" "Use --include-docker to prune Docker caches and stopped resources."
  fi

  # Step 6: close with optional skips, a final summary, and next steps.
  print_skipped_optional_groups
  print_final_summary
  print_next_step
}

main "$@"
