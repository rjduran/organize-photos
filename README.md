# Organize Photos

A cross-platform Bash script that organizes photos and videos into **year/month folders** based on their original capture date when available. Includes exact-duplicate detection, safe filename conflict handling, optional persistent destination indexing, and a live terminal progress display.

Works on **macOS** (from Terminal, including zsh) and **Windows 10/11** (Git Bash).

## Example folder structure

```text
Organized Photos/
├── 2024/
│   ├── 01_January/
│   │   └── IMG_0001.HEIC
│   └── 12_December/
│       └── DSC_1234.NEF
├── 2025/
│   └── 07_July/
│       └── vacation.jpg
└── 2026/
    └── 10_October/
        ├── IMG_0001.JPG
        └── IMG_0001_001.JPG
```

Only folders needed for the processed files are created.

## Features

- Organizes files as `YYYY/MM_Month/original-filename.ext` (for example, `2026/10_October/`).
- Recursively processes supported photo, RAW, and video formats.
- Prefers embedded photo capture dates; uses filesystem dates as fallbacks.
- Runs on macOS Bash and Windows Git Bash (including when launched from zsh on macOS).
- Defaults to **preview mode** — no photo copying or moving until requested.
- Uses SHA-256 **plus byte comparison** to identify exact duplicates.
- Never overwrites files; appends `_001`, `_002`, etc. to conflicting filenames.
- Offers optional duplicate CSV reports and a reusable destination hash index.
- Shows a live progress indicator with percentage/ETA or a count-only display.
- Never deletes skipped duplicate source files, even in move mode.

## Requirements

- macOS with Bash (macOS's built-in Bash is supported), **or** Windows 10/11 with [Git for Windows / Git Bash](https://gitforwindows.org/).
- Common shell utilities provided by macOS or Git Bash: `find`, `cmp`, `mktemp`, `date`, `stat`, `cp`, `mv`, and others.
- A SHA-256 utility: `shasum` **or** `sha256sum`.
- **Optional but recommended:** [ExifTool](https://exiftool.org/) to read original capture timestamps across image and video formats.
- On Windows, `powershell.exe` is used for filesystem creation dates if embedded dates are unavailable.

**Install ExifTool (optional)**

macOS with Homebrew:

```bash
brew install exiftool
```

On Windows, install ExifTool using its [official Windows instructions](https://exiftool.org/install.html) and ensure `exiftool` is on your `PATH` in Git Bash.

Verify:

```bash
exiftool -ver
```

## Installation

Save `organize-photos-v1.6.0.sh` from this repository and open a terminal in its directory.

On macOS, you can optionally mark it executable:

```bash
chmod +x organize-photos-v1.6.0.sh
```

Or run it with `bash` on either operating system, as shown below. **You do not need to convert the script to zsh** to run it from a macOS zsh terminal.

## Quick start

### macOS

Preview changes (default; no photos are moved or copied):

```bash
bash organize-photos-v1.6.0.sh \
  "$HOME/Pictures/Unsorted" \
  "$HOME/Pictures/Organized"
```

Copy photos:

```bash
bash organize-photos-v1.6.0.sh \
  "$HOME/Pictures/Unsorted" \
  "$HOME/Pictures/Organized" --copy
```

Move photos:

```bash
bash organize-photos-v1.6.0.sh \
  "$HOME/Pictures/Unsorted" \
  "$HOME/Pictures/Organized" --move
```

### Windows Git Bash

Git Bash typically uses paths such as `/c/Users/YourName/Pictures` for the Windows `C:` drive.

Preview:

```bash
bash organize-photos-v1.6.0.sh \
  "/c/Users/YourName/Pictures/Unsorted" \
  "/c/Users/YourName/Pictures/Organized"
```

Copy:

```bash
bash organize-photos-v1.6.0.sh \
  "/c/Users/YourName/Pictures/Unsorted" \
  "/c/Users/YourName/Pictures/Organized" --copy
```

Quote paths containing spaces on either platform.

## Options

| Option | Description |
| --- | --- |
| `--copy` | Copy files to the organized destination. |
| `--move` | Move files to the organized destination. |
| `--dry-run` | Preview only; also the default when no operation is specified. |
| `--duplicates skip` | Skip exact duplicates (default). |
| `--duplicates keep` | Preserve every file, renaming conflicts; disables duplicate checking. |
| `--duplicates report` | Skip exact duplicates and create a CSV duplicate report. |
| `--report FILE` | Specify CSV filename with `--duplicates report`. |
| `--scan` | Fully scan the destination and rebuild its persistent duplicate index. |
| `--no-scan` | Reuse saved destination index without scanning the destination (default). |
| `--no-count` | Skip preliminary source counting and show a count-only progress display. |

### Faster startup for large collections

Skip *both* the optional full destination scan and the initial source count:

```bash
bash organize-photos-v1.6.0.sh SOURCE DESTINATION \
  --copy --no-scan --no-count
```

The script starts processing incoming files without a preliminary source count. Its display shows **files processed and elapsed time**, without percentage or ETA.

Without `--no-count`, the script first counts supported source files and then displays a bar similar to:

```text
[##################------------] 60% | 3000/5000 files | Elapsed 00:02:15 | ETA 00:01:30
```

Both modes display a final summary with counts for media files, copied/moved/planned files, duplicate skips, and renamed collisions.

## Persistent destination index

Checking for duplicates across a large existing library can take time. The organizer can save the destination file hashes to:

```text
DESTINATION/.organize-photos-index-v1.bin
```

**Build or rebuild the index** while actually copying or moving:

```bash
bash organize-photos-v1.6.0.sh SOURCE DESTINATION --copy --scan
```

On future runs, omit `--scan` (or use `--no-scan`) to load the saved index and avoid rehashing every destination file:

```bash
bash organize-photos-v1.6.0.sh SOURCE DESTINATION --copy --no-scan
```

The index is updated with successfully processed files. A **preview run does not save a rebuilt index**, even when `--scan` is specified. Also, `--duplicates keep` does not build or use the duplicate index.

**Index limitations:** If files are added or changed directly in the destination outside this script, they might not be represented until the next `--scan`. The script checks whether indexed files still exist and verifies actual bytes before skipping a source file. Without a pre-existing index or an initial `--scan`, it cannot reliably detect exact duplicates already somewhere else in the destination, although it still protects against filename overwrites.

## How dates are chosen

The script tries, in order:

1. Embedded metadata using ExifTool (when installed): `DateTimeOriginal`, then `CreateDate`, then `MediaCreateDate`.
2. Filesystem **creation/birth date**: macOS `stat`, or Windows PowerShell.
3. Filesystem **modification date** if the earlier options are unavailable.

To inspect a file's timestamps:

```bash
exiftool -a -G1 -s -time:all "photo.jpg"
```

**Note:** Copying, exporting, and restoring files may alter their filesystem creation timestamps. For better date accuracy, install ExifTool and review its metadata results for a representative sample of photos.

## Duplicates and filename collisions

| Situation | Behavior with default `--duplicates skip` |
| --- | --- |
| Same content, same or different name | Skip the duplicate. |
| Different content, same destination filename | Keep both by numbering the incoming filename. |
| Same capture timestamp, different content | Keep both. |
| Same-looking image with different encoding/compression | Keep both unless the underlying bytes match exactly. |

For example, a naming conflict becomes `IMG_0001_001.HEIC` rather than overwriting `IMG_0001.HEIC`.

To produce a duplicate CSV:

```bash
bash organize-photos-v1.6.0.sh SOURCE DESTINATION \
  --copy --duplicates report --report "duplicates.csv"
```

The CSV includes source path, path of the identical file, SHA-256 hash, and action. Choose a **new** report filename; the script refuses to overwrite an existing report. Without `--report`, it creates `photo-duplicates-report.csv` in the current directory.

## Supported formats

JPG/JPEG, PNG, HEIC/HEIF, TIFF, GIF, WebP; RAW formats DNG, CR2, CR3, NEF, ARW, RAF, ORF, RW2; and videos MOV, MP4, M4V, AVI.

File extensions are matched case-insensitively. The script preserves the original filename, subject to collision renaming.

## Safety and limitations

- **Start with a preview**, and use `--copy` on a small representative sample before `--move` on an irreplaceable collection.
- The default duplicate behavior skips exact matches but **does not delete skipped originals**. If you use `--move`, skipped source files remain in the source directory.
- No file is intentionally overwritten; destination filename conflicts receive numbered suffixes.
- Duplicate detection is **byte-for-byte**, not visual similarity detection.
- A preview does not save the destination index; building that index requires an actual copy/move run with `--scan`.
- Destination folders must have an existing parent directory if the destination itself does not yet exist.
- The tool should be tested on your macOS and Windows Git Bash setups before processing a large or critical collection; native cross-platform behavior has not been exhaustively validated.

## Example workflows

**One-time migration into a library with existing files:**

```bash
bash organize-photos-v1.6.0.sh SOURCE DESTINATION --copy --scan
```

**Add a new batch later, without rescanning the destination:**

```bash
bash organize-photos-v1.6.0.sh SOURCE DESTINATION --move --no-scan
```

**Process immediately with no source count or destination scan:**

```bash
bash organize-photos-v1.6.0.sh SOURCE DESTINATION --move --no-scan --no-count
```

**Rebuild the index after manually changing the organized library:**

```bash
bash organize-photos-v1.6.0.sh SOURCE DESTINATION --copy --scan
```

## License

This project is licensed under the terms specified in the [LICENSE](LICENSE) file included in this repository.
