#!/usr/bin/env bash

#
# Organize Photos
# Version: 1.0.0
# Date: 10/15/2026
#
# Author: RJ Duran
# Email: rjduranjr@gmail.com
#
# Description:
# Organizes photos and videos into year/month folders using
# embedded capture dates or filesystem timestamps.
# Designed for macOS and Windows Git Bash.
#
# Features:
# - Organizes files into Year/NN_Month folders.
# - Supports common photo, RAW, and video formats.
# - Uses ExifTool for accurate capture dates when available.
# - Falls back to filesystem creation or modification dates.
# - Detects exact duplicates using SHA-256 hashes.
# - Automatically renames conflicting filenames.
# - Supports preview, copy, and move operations.
# - Maintains a persistent destination index for faster processing.
# - Offers optional scanning and file counting.
# - Displays processing progress and final summary statistics.
#

set -euo pipefail

usage() {
  cat <<'HELP'
Usage: organize-photos-v1.6.0.sh SOURCE DESTINATION [--copy|--move] [--duplicates skip|keep|report] [--report FILE] [--scan|--no-scan] [--no-count]

Default: preview (no files changed); --duplicates skip.
--duplicates skip    Skip byte-identical files already present or planned.
--duplicates keep    Preserve every file, numbering conflicting names.
--duplicates report  Skip exact duplicates and write a CSV report.
--report FILE        CSV output path (for --duplicates report).
--scan               Rebuild the saved destination index by scanning all existing media.
--no-scan            Reuse saved index (default); do not enumerate destination files.
                     Without an index, existing content cannot be globally deduplicated.
--no-count           Skip initial source enumeration; show processed count and elapsed time
                     instead of percentage and estimated time remaining.

Examples:
  ./organize-photos-v1.6.0.sh ~/Pictures/Unsorted ~/Pictures/Organized
  ./organize-photos-v1.6.0.sh ~/Pictures/Unsorted ~/Pictures/Organized --copy
  ./organize-photos-v1.6.0.sh ~/Pictures/Unsorted ~/Pictures/Organized --move --duplicates report --report ~/Desktop/duplicates.csv

Requires standard Git Bash/macOS tools and either shasum or sha256sum.
ExifTool is optional but recommended. Windows fallback uses PowerShell for file creation dates.
Folder structure: DESTINATION/YYYY/MM_Month/filename.ext
Identical files are NEVER deleted from the source when skipped, even with --move.
HELP
}
[[ $# -ge 2 ]] || { usage; exit 1; }
source_dir=$1; output_dir=$2; shift 2
mode=preview; duplicates=skip; report_file=""; scan_destination=no; count_source=yes
while [[ $# -gt 0 ]]; do
  case "$1" in
    --copy) mode=copy; shift ;;
    --move) mode=move; shift ;;
    --dry-run) mode=preview; shift ;;
    --duplicates) [[ $# -ge 2 ]] || { usage; exit 1; }; duplicates=$2; shift 2 ;;
    --report) [[ $# -ge 2 ]] || { usage; exit 1; }; report_file=$2; shift 2 ;;
    --scan) scan_destination=yes; shift ;;
    --no-scan) scan_destination=no; shift ;;
    --no-count) count_source=no; shift ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done
case "$duplicates" in skip|keep|report) ;; *) usage; exit 1 ;; esac
[[ -d "$source_dir" ]] || { echo "Source folder not found: $source_dir" >&2; exit 1; }
source_dir=$(cd "$source_dir" && pwd -P)
# Allow destination path to be new and contain multiple missing levels.
mkdir_path=$(dirname "$output_dir")
if [[ -d "$output_dir" ]]; then
  output_dir=$(cd "$output_dir" && pwd -P)
else
  [[ -d "$mkdir_path" ]] || { echo "Destination parent must exist: $mkdir_path" >&2; exit 1; }
  output_dir="$(cd "$mkdir_path" && pwd -P)/$(basename "$output_dir")"
fi
[[ "$source_dir" != "$output_dir" ]] || { echo "Source and destination cannot be identical." >&2; exit 1; }
# Prevent accidental ingest of output if it is nested under the source.
# The destination itself may be nested, but its existing files will be excluded from source scanning.

for cmd in find cmp mktemp; do command -v "$cmd" >/dev/null 2>&1 || { echo "Missing command: $cmd" >&2; exit 1; }; done
if command -v shasum >/dev/null 2>&1; then
  hash_type=shasum
elif command -v sha256sum >/dev/null 2>&1; then
  hash_type=sha256sum
else
  echo 'Missing SHA-256 hashing utility (shasum or sha256sum).' >&2; exit 1
fi
case "$(uname -s)" in
  Darwin*) platform=mac ;;
  MINGW*|MSYS*|CYGWIN*) platform=windows ;;
  *) platform=unix ;;
esac
work=$(mktemp -d "${TMPDIR:-/tmp}/photo-organize.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/digests" "$work/targets"
index_file="$output_dir/.organize-photos-index-v1.bin"
index_readable=no
index_additions="$work/index-additions.bin"
: > "$index_additions"

is_media() {
  case "${1##*.}" in
    [Jj][Pp][Gg]|[Jj][Pp][Ee][Gg]|[Pp][Nn][Gg]|[Hh][Ee][Ii][Cc]|[Hh][Ee][Ii][Ff]|[Tt][Ii][Ff]|[Tt][Ii][Ff][Ff]|[Gg][Ii][Ff]|[Ww][Ee][Bb][Pp]|[Dd][Nn][Gg]|[Cc][Rr]2|[Cc][Rr]3|[Nn][Ee][Ff]|[Aa][Rr][Ww]|[Rr][Aa][Ff]|[Oo][Rr][Ff]|[Rr][Ww]2|[Mm][Oo][Vv]|[Mm][Pp]4|[Mm]4[Vv]|[Aa][Vv][Ii]) return 0 ;;
    *) return 1 ;;
  esac
}
sha256() {
  if [[ "$hash_type" == shasum ]]; then shasum -a 256
  else sha256sum; fi
}
file_hash() { sha256 < "$1" | cut -d ' ' -f 1; }
path_key() {
  local value=$1
  # Windows directories are normally case-insensitive: reserve paths accordingly.
  if [[ "$platform" == windows ]]; then
    value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
  fi
  printf '%s' "$value" | sha256 | cut -d ' ' -f 1
}
# Hash catalog: digest folder contains reference paths as numbered, NUL-terminated records.
# Compare actual bytes with cmp, not just hashes.
remember() {
  local hash=$1 path=$2 dir="$work/digests/$1" n
  mkdir -p "$dir"
  n=$(find "$dir" -type f | wc -l | tr -d ' ')
  printf '%s\0' "$path" > "$dir/$n"
}
match_duplicate() {
  local hash=$1 path=$2 entry existing
  [[ -d "$work/digests/$hash" ]] || return 1
  for entry in "$work/digests/$hash"/*; do
    [[ -f "$entry" ]] || continue
    IFS= read -r -d '' existing < "$entry" || true
    if [[ -f "$existing" ]] && cmp -s "$path" "$existing"; then
      duplicate_of=$existing
      return 0
    fi
  done
  return 1
}
# Return YYYY-MM-DD. Prefer embedded capture date, then creation/birth time,
# finally modification date. Windows creation time uses PowerShell via Git Bash.
capture_date() {
  local file=$1 dt="" winfile=""
  if command -v exiftool >/dev/null 2>&1; then
    dt=$(exiftool -s3 -d '%Y-%m-%d' -DateTimeOriginal -CreateDate -MediaCreateDate \
      "$file" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | head -n 1 || true)
  fi
  if [[ -z "$dt" ]]; then
    if [[ "$platform" == mac ]]; then
      dt=$(stat -f '%SB' -t '%Y-%m-%d' "$file" 2>/dev/null || true)
    elif [[ "$platform" == windows ]]; then
      if command -v cygpath >/dev/null 2>&1; then
        winfile=$(cygpath -w "$file" 2>/dev/null || true)
      else
        winfile=$file
      fi
      if command -v powershell.exe >/dev/null 2>&1; then
        # Avoid quoting arbitrary file names inside PowerShell source code.
        dt=$(PHOTO_ORGANIZER_FILE="$winfile" powershell.exe -NoProfile -NonInteractive -Command \
          'try { (Get-Item -LiteralPath $env:PHOTO_ORGANIZER_FILE -ErrorAction Stop).CreationTime.ToString("yyyy-MM-dd") } catch { "" }' \
          2>/dev/null | tr -d '\r' | head -n 1 || true)
      fi
    else
      dt=$(stat -c '%w' "$file" 2>/dev/null || true)
      dt=${dt%% *}; [[ "$dt" != '-' ]] || dt=""
    fi
  fi
  if [[ ! "$dt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    if [[ "$platform" == mac ]]; then
      dt=$(stat -f '%Sm' -t '%Y-%m-%d' "$file")
    else
      dt=$(date -d "@$(stat -c '%Y' "$file")" '+%Y-%m-%d')
    fi
  fi
  printf '%s' "$dt"
}
csv_field() { local v=${1//\"/\"\"}; printf '"%s"' "$v"; }
if [[ "$duplicates" == report ]]; then
  [[ -n "$report_file" ]] || report_file="$(pwd)/photo-duplicates-report.csv"
  [[ ! -e "$report_file" ]] || { echo "Report exists; choose a new --report path: $report_file" >&2; exit 1; }
  printf 'Source,Identical To,SHA-256,Action\n' > "$report_file"
fi

# Pre-count matching source files for accurate progress percentages.
# Count uses the same media filter and output-directory exclusion as processing.
total=0
if [[ "$count_source" == yes ]]; then
  while IFS= read -r -d '' candidate; do
    case "$candidate" in "$output_dir"/*) continue ;; esac
    is_media "$candidate" || continue
    total=$((total+1))
  done < <(find "$source_dir" -type f -print0)
fi

processed=0
progress_last_length=0
format_duration() {
  local sec=$1
  if [[ "$sec" -lt 0 ]]; then sec=0; fi
  printf '%02d:%02d:%02d' "$((sec/3600))" "$(((sec%3600)/60))" "$((sec%60))"
}
show_progress() {
  local now elapsed percent filled empty bar spaces eta line
  now=$(date +%s)
  elapsed=$((now-started_at))
  if [[ "$count_source" == no ]]; then
    line="${processed} files processed | Elapsed $(format_duration "$elapsed") | ETA unavailable (--no-count)"
    printf '\r%-*s' "$progress_last_length" "$line"
    progress_last_length=${#line}
    return
  fi
  if [[ "$total" -gt 0 ]]; then
    percent=$((processed*100/total))
    filled=$((processed*30/total))
  else
    percent=100; filled=30
  fi
  empty=$((30-filled))
  printf -v bar '%*s' "$filled" ''
  bar=${bar// /#}
  printf -v spaces '%*s' "$empty" ''
  spaces=${spaces// /-}
  if [[ "$processed" -gt 0 && "$processed" -lt "$total" ]]; then
    eta=$((elapsed*(total-processed)/processed))
    line="[$bar$spaces] ${percent}% | ${processed}/${total} files | Elapsed $(format_duration "$elapsed") | ETA $(format_duration "$eta")"
  elif [[ "$processed" -eq "$total" ]]; then
    line="[$bar$spaces] ${percent}% | ${processed}/${total} files | Elapsed $(format_duration "$elapsed") | ETA 00:00:00"
  else
    line="[$bar$spaces] ${percent}% | ${processed}/${total} files | Elapsed $(format_duration "$elapsed") | ETA calculating"
  fi
  # Terminal carriage return refreshes one line. Pad over a previously longer line.
  printf '\r%-*s' "$progress_last_length" "$line"
  progress_last_length=${#line}
}

# Persistent binary index: magic line, followed by repeated SHA256\0PATH\0 records.
# Null-separated paths safely support spaces, commas and embedded newlines.
# Stale index entries are checked against the live file with cmp before skipping.
# External newly added files require --scan for discovery.
index_magic='PHOTO_ORGANIZER_INDEX_1'
write_index_record() {
  printf '%s\0%s\0' "$1" "$2" >> "$index_additions"
}
load_index() {
  local digest path
  IFS= read -r header < "$index_file" || true
  [[ "$header" == "$index_magic" ]] || { echo 'Index format not recognized; use --scan.' >&2; return 1; }
  while IFS= read -r -d '' digest && IFS= read -r -d '' path; do
    [[ "$digest" =~ ^[0123456789abcdef]{64}$ ]] || continue
    # Only remember paths that still exist. Identical bytes are checked by cmp.
    [[ -f "$path" ]] && remember "$digest" "$path"
  done < <(tail -n +2 "$index_file")
}
if [[ "$duplicates" != keep ]]; then
  echo "Platform: $platform | ExifTool: $(if command -v exiftool >/dev/null 2>&1; then echo available; else echo unavailable; fi) | Mode: $mode"
  if [[ "$scan_destination" == yes ]]; then
    echo 'Rebuilding destination index (full scan requested)...'
    if [[ -d "$output_dir" ]]; then
      while IFS= read -r -d '' existing; do
        is_media "$existing" || continue
        hash=$(file_hash "$existing")
        remember "$hash" "$existing"
        write_index_record "$hash" "$existing"
      done < <(find "$output_dir" -type f -print0)
    fi
    index_readable=yes
  elif [[ -f "$index_file" ]]; then
    echo 'Loading saved destination index (no full scan)...'
    if load_index; then index_readable=yes; else exit 1; fi
  else
    echo 'No saved index: skipping destination scan. Existing files will be protected from overwrites, but may not be identified as duplicates.'
    echo 'Use --scan once to build a complete index.'
  fi
else
  echo "Platform: $platform | ExifTool: $(if command -v exiftool >/dev/null 2>&1; then echo available; else echo unavailable; fi) | Mode: $mode"
  if [[ "$scan_destination" == yes ]]; then
    echo 'Note: --scan is unnecessary with --duplicates keep; no duplicate index is built.'
  fi
fi
scanned=0; planned=0; skipped=0; renamed=0
started_at=$(date +%s)
show_progress
while IFS= read -r -d '' file; do
  case "$file" in "$output_dir"/*) continue ;; esac
  is_media "$file" || continue
  scanned=$((scanned+1))
  hash=""
  if [[ "$duplicates" != keep ]]; then
    hash=$(file_hash "$file")
    duplicate_of=""
    if match_duplicate "$hash" "$file"; then
      skipped=$((skipped+1))
      processed=$((processed+1))
      show_progress
      if [[ "$duplicates" == report ]]; then
        { csv_field "$file"; printf ','; csv_field "$duplicate_of"; printf ','; csv_field "$hash"; printf ',"SKIP"\n'; } >> "$report_file"
      fi
      continue
    fi
  fi
  dt=$(capture_date "$file"); year=${dt:0:4}; month=${dt:5:2}
  case "$month" in
    01) name=January;; 02) name=February;; 03) name=March;; 04) name=April;;
    05) name=May;; 06) name=June;; 07) name=July;; 08) name=August;;
    09) name=September;; 10) name=October;; 11) name=November;; 12) name=December;;
    *) skipped=$((skipped+1)); processed=$((processed+1)); show_progress; continue;;
  esac
  folder="$output_dir/$year/${month}_${name}"
  base=${file##*/}; stem=${base%.*}; ext=${base##*.}
  target="$folder/$base"; suffix=1; conflict=0
  while [[ -e "$target" || -e "$work/targets/$(path_key "$target")" ]]; do
    target="$folder/${stem}_$(printf '%03d' "$suffix").$ext"
    suffix=$((suffix+1)); conflict=1
  done
  [[ $conflict -eq 0 ]] || renamed=$((renamed+1))
  : > "$work/targets/$(path_key "$target")"
  if [[ "$mode" != preview ]]; then
    mkdir -p "$folder"
    if [[ "$mode" == copy ]]; then cp -p "$file" "$target"; else mv "$file" "$target"; fi
  fi
  # On previews, index the source path; for actual copy/move index the output path.
  if [[ "$duplicates" != keep ]]; then
    if [[ "$mode" == preview ]]; then remember "$hash" "$file"
    else remember "$hash" "$target"; write_index_record "$hash" "$target"; fi
  fi
  planned=$((planned+1))
  processed=$((processed+1))
  show_progress
done < <(find "$source_dir" -type f -print0)
# Commit the index only after successful processing. Full scans replace the old
# index; incremental runs append new paths without rehashing the destination.
if [[ "$mode" != preview && "$duplicates" != keep ]]; then
  mkdir -p "$output_dir"
  if [[ "$scan_destination" == yes ]]; then
    temp_index="$output_dir/.organize-photos-index-v1.tmp.$$"
    { printf '%s\n' "$index_magic"; cat "$index_additions"; } > "$temp_index"
    mv -f "$temp_index" "$index_file"
  else
    if [[ ! -f "$index_file" ]]; then
      { printf '%s\n' "$index_magic"; cat "$index_additions"; } > "$index_file"
    else
      cat "$index_additions" >> "$index_file"
    fi
  fi
elif [[ "$scan_destination" == yes && "$mode" == preview ]]; then
  echo 'Preview only: destination index not saved. Run --scan with --copy or --move to persist it.'
fi
printf '\nSummary: %d media files scanned; %d %s; %d duplicates skipped; %d filename conflicts renamed.\n' "$scanned" "$planned" "$mode" "$skipped" "$renamed"
[[ "$duplicates" != report ]] || echo "Duplicate report: $report_file"
