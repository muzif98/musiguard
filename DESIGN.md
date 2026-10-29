# MusiGuard design notes

This document explains the main design decisions behind MusiGuard and the
reasons for them. The README covers what the project does and how to use it.

## Landing folder instead of `~/Downloads`

Downloads arrive in `~/PreDownload` and only reach `~/Downloads` (or a category
folder) after the checks. Keeping a separate landing folder means a file is
never visible in its final place, or opened from there, before it has been
scanned.

The landing folder can be a separate ext4 volume backed by a **sparse image
file**, mounted with `noexec,nosuid,nodev`:

- `noexec` makes it impossible to run anything from there, even by mistake,
  and the quarantine lives on the same volume;
- a sparse image allocates only the blocks actually used, so the declared size
  is just a ceiling;
- the fstab line uses `nofail`, so a missing image never blocks boot;
- the creation script is idempotent: an existing image is never reformatted
  (it may hold downloads and quarantined files), re-runs replace the fstab line
  instead of duplicating it, and files already in the folder are parked and
  moved back after mounting (otherwise they would be hidden under the mount
  point);
- the mount point is always `chown`ed to the user, even if it was already
  mounted: after `daemon-reload` systemd mounts the new fstab entry by itself,
  so the "mount it now" branch is usually skipped, and without the `chown` the
  ext4 root would remain owned by root;
- after mounting, the guardian is restarted, because its inotify watch would
  still point at the old directory hidden underneath.

## systemd user service

The guardian runs as a systemd **user** service rather than a manually started
script: if it crashed, or `inotifywait` was killed, nobody restarted it and
downloads silently stayed in the landing folder. `Restart=on-failure` brings it
back; `StartLimitBurst=5` in 300 s stops endless restarts when a dependency is
missing.

It is bound to `graphical-session.target` (not to boot) because `zenity` and
`notify-send` need a display and the session bus; `PartOf` stops it at logout.

A `flock` lock prevents two guardians (for example one started by hand and one
by the service) from processing the same files concurrently. A second instance
exits with status 0, which `Restart=on-failure` intentionally does not treat as
a failure. The installer refuses to install while a manually started guardian
holds the lock, instead of installing a service that would exit immediately.
It also retires units with legacy names left by older versions, which were the
cause of duplicate instances.

## Detecting a finished download

A file is handled only when **all three** conditions hold:

1. no process has it open for writing;
2. it is not sparse;
3. size and mtime are identical on two consecutive reads.

Checking only the size is not enough for torrents. Torrent clients write in
place, without a temporary suffix, and pieces arrive out of order: as soon as a
piece near the end is written, the apparent size jumps to the final value. An
earlier size-only check declared such files "ready" two seconds into the
download and moved them away from the client, which then failed.

- **Writers** are detected with `lsof -F`, keeping only file descriptors opened
  in `w` or `u` mode. Readers (media players, thumbnailers, a client that is
  seeding) do not count. Without `lsof`, `/proc/*/fd` links are scanned and the
  open flags in `fdinfo` are checked (`O_WRONLY`/`O_RDWR`).
- **Sparseness**: a file whose allocated blocks are less than 90 % of its size
  is considered incomplete. Since everything in the landing folder comes from
  the network, a sparse file means missing pieces. A `sync` is done first,
  otherwise ext4 delayed allocation makes a freshly written file look sparse.
  Files under 64 KiB are skipped, because block granularity makes the ratio
  meaningless.
- **Stability** uses size + mtime for files, and a hash of sizes and mtimes of
  every contained file for directories (preallocated torrent files keep their
  size but their mtime changes with each piece).

While a writer is present, the check runs every 15 s; otherwise every 2 s.
The wait is capped by `ATTESA_MAX_MINUTI` (12 hours by default, since torrents
can be slow); on timeout the entry is left untouched and will be re-queued at
the next start. An empty directory (just created by a torrent client) is never
sorted while empty.

## Event handling and concurrency

- `inotifywait` listens to `close_write`, `moved_to` and `create`. `create` is
  needed for multi-file torrents, whose directory is created but never written
  or renamed as a whole.
- Every entry is handled in a **background subshell**, because waiting can take
  hours and the main loop is serial. A per-entry lock (`flock -n` on a file
  named after the hash of the entry name) deduplicates events: a download
  produces many `close_write` events, but only the first handler proceeds.
- Background subshells close the inherited global lock descriptor, so a long
  extraction or an open dialog never keeps the service lock.
- Partial files of browsers and download managers (`.part`, `.crdownload`,
  `.!qB`, ...), `lost+found` and dotfiles (including the quarantine) are
  ignored. The final file arrives via a rename, which emits `moved_to`.
- At startup, everything already in the landing folder is re-queued, so nothing
  is left behind by a restart in the middle of a download.

## Scanner (`AntiVirusDIY.sh`)

The scanner is a separate script with a simple contract (exit 0 = clean,
exit 1 = issues, details on stdout), so it can be used on its own.

- **Configuration is parsed, not sourced.** Earlier versions sourced the config
  with `.`, so anyone able to write to it could run code as the user. Now only
  lines matching `KEY=number` are accepted; anything else is ignored. The
  VirusTotal key file accepts exactly one line of 64 hex characters.
- **MIME vs. extension.** `file --mime-type` reveals ELF binaries and scripts
  disguised as documents. Windows PE files (`x-dosexec`, `x-msdownload`) are
  covered too, with a separate whitelist (`exe`, `msi`), because a renamed
  `.exe` used to pass the Linux-only check.
- **Name anti-spoofing.** The MIME check looks at content; this looks at what
  the user actually sees. Bidirectional and invisible Unicode characters (e.g.
  RTLO, U+202E) make `invoice<RTLO>fdp.exe` display as `invoiceexe.pdf`; no
  legitimate download needs them. Double extensions such as `invoice.pdf.exe`
  are flagged when an executable/script extension follows a document or media
  one; this also covers types the MIME check cannot (`js`, `vbs`, `ps1` are
  plain text to `file`, `jar` is a zip). Spaces around the inner extension are
  removed to defeat padding (`document.pdf          .exe`).
- **Clipboard SHA256 instead of a prompt.** An earlier version opened a dialog
  for every download asking for a checksum. Now, if the clipboard contains a
  64-hex string (typically copied from the download page) it is compared; if
  not, nothing is shown and the hash is not even computed. A mismatch may also
  mean the clipboard held the hash of another file, and the message says so.
- **Hash checks run in parallel.** `sha256sum` and the optional VirusTotal
  request are the slow parts; they run in a background subshell that writes to
  a temporary file, joined after the local checks. Separate channels (file vs.
  variable) avoid races. The hash is computed once and shared by both checks.
- **VirusTotal is hash-only and fail-silent.** Only the SHA256 is sent, never
  the file. Unknown hashes, missing network, rate limits (4 requests/min on the
  free plan) and rejected keys produce no message: network trouble must not
  block downloads, and ClamAV coverage remains. `curl --max-time 15` prevents a
  hanging network from stalling the queue. `jq` is used if present, with a grep
  fallback on the flat `last_analysis_stats` object.
- **ClamAV.** `clamdscan` is preferred because the daemon keeps signatures in
  memory, while `clamscan` reloads about 1 GB of signatures for every file
  (tens of seconds each, minutes with several downloads queued). `--fdpass`
  lets the daemon, running as another user, read files in the user's home.
  If the daemon fails, `clamscan` is used. Exit code 1 is a detection, 2 or
  more is a scan error and is reported as such.
- **Directories.** Multi-file torrents arrive as directories. The same name and
  MIME checks run on each contained file, using a single `file` invocation for
  the whole tree; ClamAV runs once, recursively. The two hash-based checks are
  disabled for directories: a clipboard hash refers to one file, and the free
  VirusTotal quota cannot cover a folder. Name checks stop after 5000 files,
  because on huge trees they would cost more than the scan.

## Quarantine

Suspicious entries are moved **immediately** to `.Quarantena` inside the
landing folder and set to mode `000`:

- it stays on the `noexec` volume;
- it is hidden from the file manager and from the (non-recursive) inotify watch,
  so it is never re-queued;
- no application can open the file, but the owner can still delete or restore
  it;
- the reason is appended to `quarantena.log`.

Earlier, suspicious files stayed loose in the landing folder, where they could
be opened by mistake and were re-queued on every event, and the decision dialog
blocked the whole queue. Now the dialog runs in a background subshell after the
file is already isolated, so an unanswered dialog does not delay other
downloads. Choices: delete, keep in quarantine (also the default if the dialog
is closed), or ignore the risk and sort.

## Sorting

- Each category goes into a `Downloads` subfolder of the matching XDG user
  directory (`Documents/Downloads`, `Pictures/Downloads`, ...), so downloaded
  files stay separate from personal ones.
- Name collisions get a numeric suffix instead of being overwritten (a bare
  `mv` used to replace existing files silently).
- Archive detection is based on the extension, not on the destination, so
  extraction works even when sorting is disabled.
- **Directories are moved as a whole**, without opening them: an album or a
  series must not end up split between Music and Videos. The destination is
  the category with the most **bytes**, not the most files: a movie folder has
  one large `.mkv` among many small `.jpg`, `.nfo` and `.srt` files. For the
  same reason archives inside directories are not extracted and metadata is not
  stripped.
- When a torrent's files are moved, the client can no longer seed them; a
  notification tells the user to remove the torrent.

## Archive extraction

- **Two-layer zip-bomb guard.** zip and 7z declare the total uncompressed size
  in their index, so oversized archives are refused before touching the disk.
  The index can lie (nested bombs), and other formats declare nothing, so the
  extraction subshell also sets `ulimit -f`: the extractor is killed by
  `SIGXFSZ` instead of filling the disk, and the normal error path runs. The
  archive is always kept when extraction is refused or fails.
- **Collision-safe target folder.** Downloading `files.zip` twice used to
  extract the second copy over the first one's folder (`unzip -o`). The target
  is now created with `mkdir` without `-p`, an atomic test-and-create: if it
  fails, `files (1)`, `files (2)`, ... are tried (up to 999, to avoid looping
  on other errors). This also removes a race between two parallel extractions
  with the same name, and guarantees the folder is new and ours, so `rm -rf` on
  failure is safe and removes partial output (earlier `rmdir` left partial
  files behind).
- Single compressed files (`gz`, `bz2`, `xz`, `zst`) are supported too.
  Pattern order matters: `*.tar.*` and `*.tgz` must be matched before `*.gz`.
- The original archive is deleted only after a successful extraction.

## Metadata stripping

`exiftool -all=` removes GPS, author and software tags from photos and PDFs
after the file has been moved and before the notification, so the notified
file is already clean. Orientation and ICC profile are copied back
(`-tagsfromfile @`), otherwise portrait photos would appear rotated and colours
could shift. Office documents are excluded because `exiftool` cannot rewrite
them. `-overwrite_original` avoids leaving `_original` copies. If `exiftool`
fails the file is left as it was; if it is not installed the module disables
itself with a single log line instead of failing on every file.

## Notifications and dialogs

- **One notification per file.** Sorting and extraction share one function; for
  archives only the extractor notifies, when it is done, so a download no
  longer produces both "file is safe" and "extraction completed".
- `notify-send` is used instead of `zenity --notification` because it supports
  click actions: the `default` action opens the destination folder (or log)
  with a single click on the body. The `transient` hint keeps notifications out
  of the GNOME notification centre. Since `notify-send` waits for the click, it
  is run in background.
- `zenity --text` is Pango markup: unescaped `&`, `<`, `>` (from file names or
  scanner output) make the dialog fail silently, so every external string is
  escaped.
- Dialogs started from the event loop read from `/dev/null`, so they do not
  consume the `inotifywait` pipe. The selected value is cut at the first `|`
  to work around a `zenity --list` double-click quirk.

## Configuration

The configuration is a plain `KEY=number` file written by a wizard
(`zenity` checklist, or terminal prompts without a graphical session). It is
read once at startup, and the wizard restarts the service after changes.
Legacy keys from older versions are still honoured (`SMISTA_CATEGORIE`).

## Weekly maintenance

A single weekly timer (`Persistent=true`, so a run missed while the machine
was off happens at the next boot) performs:

0. **ClamAV signature freshness**, read-only. Updating requires root
   (`freshclam` writes to `/var/lib/clamav`), so MusiGuard only warns if the
   signatures are older than 7 days or `clamav-freshclam` is inactive.
1. **System Trash review**, only if enabled: a list and a confirmation, never
   automatic. `gio trash --empty` is preferred because it follows the XDG
   specification (other mounts, `.trashinfo` metadata); manual removal is the
   fallback.
2. **Quarantine review**, always: it may contain malware and must not pile up
   unnoticed. This is deliberately not a module that can be disabled.
3. **Log rotation**, size-based (2 MiB, 4 backups). It is self-contained
   because the system `logrotate` is usually not configured for files in the
   user's home. A plain rename is safe because every writer appends with `>>`
   and keeps no long-lived descriptor.

Before deleting anything, the Trash and quarantine paths are checked against
the expected suffix, so an empty or unexpected `HOME` can never lead to
deleting the wrong directory. Without a graphical session nothing is deleted:
only a notification is shown.
