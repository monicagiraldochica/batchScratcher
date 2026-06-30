#!/usr/bin/env bash
# syncDirCpy2MainDir.sh
#
# Directional sync: push NEW/UPDATED items from dirCopy -> dirMain (never the reverse).
# - Does NOT delete anything from dirMain that isn't in dirCopy.
# - Optional: --rmDirCopy (rm -rf dirCopy after successful sync)
# - Optional: --dryRun   (show what WOULD be copied + what WOULD be removed)
#
# Usage:
#   syncDirCpy2MainDir <dirCopy> <dirMain> [--rmDirCopy] [--dryRun]
#
# Example:
#   syncDirCpy2MainDir "/path/to/dirCopy" "/path/to/dirMain" --dryRun
#   syncDirCpy2MainDir "/path/to/dirCopy" "/path/to/dirMain" --rmDirCopy

set -euo pipefail

syncDirCpy2MainDir() {
  local dirCopy="" dirMain=""
  local rmDirCopy=0 dryRun=0

  # ---- Parse positional args ----
  if [[ $# -lt 2 ]]; then
    echo "ERROR: Need at least 2 args: <dirCopy> <dirMain>" >&2
    echo "Usage: syncDirCpy2MainDir <dirCopy> <dirMain> [--rmDirCopy] [--dryRun]" >&2
    return 2
  fi

  dirCopy="$1"; shift
  dirMain="$1"; shift

  # ---- Parse options ----
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rmDirCopy) rmDirCopy=1 ;;
      --dryRun)    dryRun=1 ;;
      -h|--help)
        echo "Usage: syncDirCpy2MainDir <dirCopy> <dirMain> [--rmDirCopy] [--dryRun]"
        return 0
        ;;
      *)
        echo "ERROR: Unknown option: $1" >&2
        return 2
        ;;
    esac
    shift
  done

  # ---- Sanity checks ----
  if [[ -z "$dirCopy" || -z "$dirMain" ]]; then
    echo "ERROR: dirCopy and dirMain must be non-empty." >&2
    return 2
  fi

  if [[ ! -d "$dirCopy" ]]; then
    echo "ERROR: dirCopy does not exist or is not a directory: $dirCopy" >&2
    return 2
  fi

  # Ensure dirMain exists (create it if needed)
  if [[ ! -d "$dirMain" ]]; then
    mkdir -p "$dirMain"
  fi

  if ! command -v rsync >/dev/null 2>&1; then
    echo "ERROR: rsync not found in PATH." >&2
    return 127
  fi

  # Resolve real paths for safety checks
  local rpCopy rpMain
  rpCopy="$(realpath -m -- "$dirCopy")"
  rpMain="$(realpath -m -- "$dirMain")"

  # Avoid obvious foot-guns
  if [[ "$rpCopy" == "/" || "$rpCopy" == "" ]]; then
    echo "ERROR: Refusing to operate on dirCopy='${rpCopy}'." >&2
    return 2
  fi
  if [[ "$rpCopy" == "$rpMain" ]]; then
    echo "ERROR: dirCopy and dirMain resolve to the same path: $rpCopy" >&2
    return 2
  fi
  if [[ "$rmDirCopy" -eq 1 && "$rpMain" == "$rpCopy"* ]]; then
    echo "ERROR: Refusing --rmDirCopy because dirMain is inside dirCopy:" >&2
    echo "  dirCopy: $rpCopy" >&2
    echo "  dirMain: $rpMain" >&2
    return 2
  fi

  # ---- rsync flags ----
  # -a : archive (preserve perms/times/links, recurse)
  # -i : itemize changes (useful for dryRun reporting)
  # NOTE: We intentionally do NOT use --delete (dirMain keeps any extra files)
  local -a rsync_base
  rsync_base=(rsync -a --itemize-changes --human-readable)

  # Copy *contents* of dirCopy into dirMain:
  #   source trailing slash means "copy contents" rather than the directory itself.
  local src="${rpCopy%/}/"
  local dst="${rpMain%/}/"

  if [[ "$dryRun" -eq 1 ]]; then
    echo "DRY RUN: dirCopy -> dirMain"
    echo "  dirCopy: $rpCopy"
    echo "  dirMain: $rpMain"
    echo

    # Show only paths that would be created/updated in dirMain.
    # Out format: "<itemize> <path>"
    # Itemize legend: leading '>' indicates a transfer to receiver (dirMain).
    "${rsync_base[@]}" -n --out-format='%i %n%L' "$src" "$dst" \
      | awk '
          # Keep only lines that represent transfers/creations from sender to receiver
          # Typical itemize starts with: ">f", ">d", ">L", etc.
          $1 ~ /^>/
        '

    echo
    if [[ "$rmDirCopy" -eq 1 ]]; then
      echo "DRY RUN: would remove directory after successful sync:"
      echo "  rm -rf -- '$rpCopy'"
    fi
    return 0
  fi

  echo "Syncing (directional): dirCopy -> dirMain"
  echo "  dirCopy: $rpCopy"
  echo "  dirMain: $rpMain"
  echo

  # Perform the sync
  "${rsync_base[@]}" "$src" "$dst"

  echo
  echo "Sync complete."

  # Optional cleanup
  if [[ "$rmDirCopy" -eq 1 ]]; then
    echo "Removing dirCopy:"
    echo "  rm -rf -- '$rpCopy'"
    rm -rf -- "$rpCopy"
    echo "Removed."
  fi
}

# If executed as a script, run the function with CLI args.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  syncDirCpy2MainDir "$@"
fi