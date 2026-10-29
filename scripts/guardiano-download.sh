#!/bin/bash
# set -u: undefined variables are fatal, not silently empty.
set -u

DIR_PRE="${HOME}/PreDownload"
DIR_DOWN="${HOME}/Downloads"

# Installed project paths (the systemd units also expect ~/MusiGuard).
SCRIPT_AV="${HOME}/MusiGuard/scripts/AntiVirusDIY.sh"
LOG_ESTRAZIONI="${HOME}/MusiGuard/estrazioni.log"

# Quarantine lives INSIDE PreDownload: it stays on the noexec volume and is
# hidden from the file manager and from inotify (the watch is not recursive).
# The log records the reason.
DIR_QUARANTENA="${DIR_PRE}/.Quarantena"
LOG_QUARANTENA="${HOME}/MusiGuard/quarantena.log"

# Modules and parameters from ~/.config/musiguard.conf (written by
# configura.sh). Parsed, never executed: only KEY=number lines. Read once at
# startup; configura.sh restarts the service after changes.
CONF="${HOME}/.config/musiguard.conf"
leggi_conf() {
    local V=""
    [ -f "$CONF" ] && V=$(grep -E "^$1=[0-9]+$" "$CONF" | tail -n1 | cut -d= -f2)
    echo "${V:-$2}"
}
# ESTRAI_ARCHIVI=0 keeps archives compressed; SMISTA_ESTENSIONE=0 sends
# everything to ~/Downloads (legacy key SMISTA_CATEGORIE is also honoured).
ESTRAI_ARCHIVI=$(leggi_conf ESTRAI_ARCHIVI 1)
SMISTA_ESTENSIONE=$(leggi_conf SMISTA_ESTENSIONE "$(leggi_conf SMISTA_CATEGORIE 1)")
# Zip-bomb / full-disk guard: cap (MB) on the DECOMPRESSED size. zip/7z are
# refused upfront from their index; other formats are killed by ulimit.
# The archive itself is kept.
MAX_ESTRAZIONE_MB=$(leggi_conf MAX_ESTRAZIONE_MB 10240)
# PULISCI_METADATI=1 strips tracking metadata (GPS, author, software) from
# sorted photos and PDFs. Needs exiftool; if missing, the module turns off
# with a single log warning.
PULISCI_METADATI=$(leggi_conf PULISCI_METADATI 1)
# Max wait (minutes) for a download to finish; generous because torrents can
# take hours. On timeout the file is left in PreDownload.
ATTESA_MAX_MINUTI=$(leggi_conf ATTESA_MAX_MINUTI 720)
if [ "$PULISCI_METADATI" = 1 ] && ! command -v exiftool &>/dev/null; then
    PULISCI_METADATI=0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Pulizia metadati attiva nel conf ma exiftool non è installato: modulo disattivato (apt install libimage-exiftool-perl)." >> "$LOG_ESTRAZIONI"
fi

# Single-instance lock: a second guardian would race on the same files.
# flock -n exits immediately; fd 9 stays open for the script's lifetime.
LOCKFILE="${HOME}/MusiGuard/.guardiano.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "Guardiano già in esecuzione (lock: $LOCKFILE), esco." >&2
    exit 0
fi

# Fail fast and clearly if the scanner script is missing.
if [ ! -x "$SCRIPT_AV" ]; then
    zenity --error --text="Script antivirus non trovato o non eseguibile:\n$SCRIPT_AV" 2>/dev/null
    echo "Errore: $SCRIPT_AV non trovato o non eseguibile (chmod +x?)" >&2
    exit 1
fi

# Each type goes into a "Downloads" subfolder of the matching XDG user
# directory (Documents/Downloads, Pictures/Downloads, ...), keeping downloads
# separate from personal files.
DIR_DOCS="$(xdg-user-dir DOCUMENTS 2>/dev/null || echo "${HOME}/Documents")/Downloads"
DIR_IMG="$(xdg-user-dir PICTURES 2>/dev/null || echo "${HOME}/Pictures")/Downloads"
DIR_VID="$(xdg-user-dir VIDEOS 2>/dev/null || echo "${HOME}/Videos")/Downloads"
DIR_MUS="$(xdg-user-dir MUSIC 2>/dev/null || echo "${HOME}/Music")/Downloads"
DIR_ARCH="${HOME}/Documents/Archivi"
DIR_3D="$(xdg-user-dir DOCUMENTS 2>/dev/null || echo "${HOME}/Documents")/3d Print/Downloaded"

# PreDownload must exist, or inotifywait exits immediately.
mkdir -p "$DIR_PRE" "$DIR_DOWN" "$DIR_DOCS" "$DIR_IMG" "$DIR_VID" "$DIR_MUS" "$DIR_ARCH" "$DIR_3D"

# zenity --text is Pango markup: bare & < > make the dialog fail silently.
# Use on EVERY external string passed to --text.
escape_markup() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$1"
}

# Clickable notification: clicking the body opens the folder. notify-send is
# used because zenity --notification has no click handling; the "default"
# action means a single click on the body. The transient hint leaves no copy
# in the GNOME notification centre; -t 5000 = 5 s. notify-send blocks until
# clicked, so call it in background from the main loop. Shared by sorting
# and extraction, so each file gets exactly one notification.
notifica_click() {
    local TITOLO="$1" CORPO="$2" CARTELLA="$3"
    if command -v notify-send &>/dev/null; then
        local AZIONE
        AZIONE=$(notify-send --app-name="MusiGuard" --icon=folder-download \
            -h int:transient:1 -t 5000 \
            -A "default=Apri cartella" \
            "$TITOLO" "$CORPO" 2>/dev/null)
        [ "$AZIONE" = "default" ] && xdg-open "$CARTELLA" &>/dev/null
    else
        # Fallback without libnotify: passive notification, no click.
        zenity --notification --text="$TITOLO\n📂 $CORPO" 2>/dev/null
    fi
}

# Same as notifica_click, but opens a log file.
notifica_click_log() {
    local TITOLO="$1" CORPO="$2" LOGFILE="$3"
    if command -v notify-send &>/dev/null; then
        local AZIONE
        AZIONE=$(notify-send --app-name="MusiGuard" --icon=dialog-error --urgency=critical \
            -h int:transient:1 -t 5000 \
            -A "default=Apri log" \
            "$TITOLO" "$CORPO" 2>/dev/null)
        [ "$AZIONE" = "default" ] && xdg-open "$LOGFILE" &>/dev/null
    else
        zenity --notification --text="$TITOLO\n📄 $CORPO" 2>/dev/null
    fi
}

# --- Background archive extraction ---
estrai_archivio() {
    local FILE_PATH="$1"
    local DIR_DEST NOME
    DIR_DEST="$(dirname "$FILE_PATH")"
    NOME="$(basename "$FILE_PATH")"

    (
        # Close the inherited lock fd: a long extraction must not hold the
        # service lock.
        exec 9>&-
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🟢 Inizio estrazione: $NOME" >> "$LOG_ESTRAZIONI"
        
        # Destination folder name: strip known extensions.
        local NOME_CART="$NOME"
        NOME_CART="${NOME_CART%.tar.gz}"
        NOME_CART="${NOME_CART%.tar.bz2}"
        NOME_CART="${NOME_CART%.tar.xz}"
        NOME_CART="${NOME_CART%.tar.zst}"
        NOME_CART="${NOME_CART%.tgz}"
        NOME_CART="${NOME_CART%.gz}"
        NOME_CART="${NOME_CART%.bz2}"
        NOME_CART="${NOME_CART%.xz}"
        NOME_CART="${NOME_CART%.zst}"
        NOME_CART="${NOME_CART%.tar}"
        NOME_CART="${NOME_CART%.zip}"
        NOME_CART="${NOME_CART%.rar}"
        NOME_CART="${NOME_CART%.7z}"

        # Zip-bomb guard (1): zip and 7z declare the total size in their index;
        # refuse before touching the disk. The index can lie (nested bombs),
        # hence ulimit below.
        local MAX_BYTE=$((MAX_ESTRAZIONE_MB * 1024 * 1024))
        local DIM_DICHIARATA=""
        case "$NOME" in
            *.tar.*|*.tar|*.tgz) : ;;  # no total in the index: ulimit covers it
            *.zip) DIM_DICHIARATA=$(unzip -l "$FILE_PATH" 2>/dev/null | tail -n1 | awk '{print $1}') ;;
            *.7z)  DIM_DICHIARATA=$(7z l "$FILE_PATH" 2>/dev/null | tail -n1 | awk '{print $3}') ;;
        esac
        if [[ "$DIM_DICHIARATA" =~ ^[0-9]+$ ]] && [ "$DIM_DICHIARATA" -gt "$MAX_BYTE" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⛔ RIFIUTATO: $NOME dichiara $DIM_DICHIARATA byte decompressi (limite ${MAX_ESTRAZIONE_MB}MB). Archivio conservato, non estratto." >> "$LOG_ESTRAZIONI"
            notifica_click_log "⛔ Estrazione rifiutata" "$NOME supera il limite di ${MAX_ESTRAZIONE_MB}MB decompressi. Estrailo a mano se ti fidi." "$LOG_ESTRAZIONI"
            exit 0
        fi

        # Collision-safe extraction folder: "files (1)/" instead of silently
        # overwriting an existing "files/". mkdir without -p is an atomic
        # test-and-create (no TOCTOU between parallel extractions), so the folder is
        # guaranteed fresh and ours: rm -rf on it is safe.
        local PATH_DEST_ESTRAZIONE="$DIR_DEST/$NOME_CART"
        if ! mkdir "$PATH_DEST_ESTRAZIONE" 2>/dev/null; then
            local N=1
            # Cap at 999: avoid an endless loop if mkdir fails for other reasons.
            while [ "$N" -le 999 ] && ! mkdir "$DIR_DEST/$NOME_CART ($N)" 2>/dev/null; do N=$((N+1)); done
            if [ "$N" -gt 999 ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRORE: impossibile creare la cartella di estrazione per $NOME in $DIR_DEST" >> "$LOG_ESTRAZIONI"
                notifica_click_log "❌ Errore Estrazione" "Impossibile creare la cartella per $NOME." "$LOG_ESTRAZIONI"
                exit 0
            fi
            NOME_CART="$NOME_CART ($N)"
            PATH_DEST_ESTRAZIONE="$DIR_DEST/$NOME_CART"
        fi
        local SUCCESSO=1

        # Zip-bomb guard (2): ulimit -f caps EVERY file written by this subshell and
        # its children (bash units: 1 KiB blocks). Covers formats without a declared
        # total and lying indexes: the extractor dies (SIGXFSZ) instead of filling
        # the disk, and ends up in the error branch below.
        ulimit -f $((MAX_ESTRAZIONE_MB * 1024)) 2>/dev/null

        # Extract using absolute paths. Single compressed files (gz/bz2/xz/zst) also
        # go inside the collision-safe folder. Pattern order matters: *.tar.* and
        # *.tgz must come before *.gz etc.
        case "$NOME" in
            *.tar.*|*.tar|*.tgz) tar xf "$FILE_PATH" -C "$PATH_DEST_ESTRAZIONE" >> "$LOG_ESTRAZIONI" 2>&1 && SUCCESSO=0 ;;
            *.zip) unzip -q -o "$FILE_PATH" -d "$PATH_DEST_ESTRAZIONE" >> "$LOG_ESTRAZIONI" 2>&1 && SUCCESSO=0 ;;
            *.rar) unrar x -y -inul "$FILE_PATH" "$PATH_DEST_ESTRAZIONE/" >> "$LOG_ESTRAZIONI" 2>&1 && SUCCESSO=0 ;;
            *.7z) 7z x -y -bd -o"$PATH_DEST_ESTRAZIONE" "$FILE_PATH" >> "$LOG_ESTRAZIONI" 2>&1 && SUCCESSO=0 ;;
            *.gz)  gunzip -c "$FILE_PATH" > "$PATH_DEST_ESTRAZIONE/$NOME_CART" 2>> "$LOG_ESTRAZIONI" && SUCCESSO=0 ;;
            *.bz2) bunzip2 -c "$FILE_PATH" > "$PATH_DEST_ESTRAZIONE/$NOME_CART" 2>> "$LOG_ESTRAZIONI" && SUCCESSO=0 ;;
            *.xz)  xz -dc "$FILE_PATH" > "$PATH_DEST_ESTRAZIONE/$NOME_CART" 2>> "$LOG_ESTRAZIONI" && SUCCESSO=0 ;;
            *.zst)
                # zstd may be missing on minimal installs.
                if command -v zstd &>/dev/null; then
                    zstd -dc "$FILE_PATH" > "$PATH_DEST_ESTRAZIONE/$NOME_CART" 2>> "$LOG_ESTRAZIONI" && SUCCESSO=0
                else
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Formato ignorato o non supportato (zstd non installato): $NOME" >> "$LOG_ESTRAZIONI"
                    rm -rf "$PATH_DEST_ESTRAZIONE"
                    # The file stays where it was sorted: send the sorting notification.
                    notifica_click "✅ $NOME è sicuro" \
                        "Ordinato in: ${DIR_DEST#"$HOME"/} (non estratto: manca zstd)" "$DIR_DEST"
                    exit 0
                fi
                ;;
            *)
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Formato ignorato o non supportato: $NOME" >> "$LOG_ESTRAZIONI"
                rm -rf "$PATH_DEST_ESTRAZIONE"
                notifica_click "✅ $NOME è sicuro" \
                    "Ordinato in: ${DIR_DEST#"$HOME"/}" "$DIR_DEST"
                exit 0
                ;;
        esac

        # On success, delete the original archive.
        if [ $SUCCESSO -eq 0 ]; then
            rm -f "$FILE_PATH"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ OK: $NOME estratto in '$NOME_CART/' e rimosso." >> "$LOG_ESTRAZIONI"
            # The only notification for archives (sorting stays quiet on purpose):
            # clicking opens the extracted folder.
            notifica_click "📦 $NOME estratto" \
                "File sistemati in: ${PATH_DEST_ESTRAZIONE#"$HOME"/}" "$PATH_DEST_ESTRAZIONE"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRORE: Fallita estrazione di $NOME" >> "$LOG_ESTRAZIONI"
            # rm -rf (not rmdir) also removes partial output of a failed extraction.
            # Safe: the folder was freshly created by us (atomic mkdir above).
            rm -rf "$PATH_DEST_ESTRAZIONE"
            notifica_click_log "❌ Errore Estrazione" "Impossibile estrarre $NOME." "$LOG_ESTRAZIONI"
        fi
    ) &
}

# Strip metadata from a sorted file. Only formats exiftool can rewrite (Office
# files are read-only for it). Orientation and ICC profile are preserved
# (-tagsfromfile @) so photos keep their rotation and colours. Runs AFTER the
# antivirus; -overwrite_original leaves no "_original" copies. On failure the
# file is left untouched.
pulisci_metadati() {
    local FILE="$1" EST="$2"
    case "$EST" in
        jpg|jpeg|png|webp|gif|tif|tiff|heic|pdf)
            # < /dev/null: called from the while-read loop, must not consume the pipe.
            if ! exiftool -q -q -all= -tagsfromfile @ -Orientation -ICC_Profile \
                -overwrite_original "$FILE" < /dev/null 2>> "$LOG_ESTRAZIONI"; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Pulizia metadati fallita su $(basename "$FILE") (file lasciato com'era)." >> "$LOG_ESTRAZIONI"
            fi
            ;;
    esac
}

# Category of a (lowercase) extension and its folder. Shared by file and
# directory sorting. No forks: plain case + echo.
categoria_estensione() {
    case "$1" in
        pdf|doc|docx|txt|odt|rtf|xls|xlsx|csv) echo docs ;;
        jpg|jpeg|png|gif|webp|svg) echo img ;;
        mp4|mkv|avi|mov) echo vid ;;
        mp3|wav|flac|m4a) echo mus ;;
        # Keep in sync with the formats handled by estrai_archivio.
        zip|rar|7z|tar|gz|bz2|xz|zst|tgz) echo arch ;;
        stl|obj|3mf) echo 3d ;;
    esac
}
dir_categoria() {
    case "$1" in
        docs) echo "$DIR_DOCS" ;;
        img)  echo "$DIR_IMG" ;;
        vid)  echo "$DIR_VID" ;;
        mus)  echo "$DIR_MUS" ;;
        arch) echo "$DIR_ARCH" ;;
        3d)   echo "$DIR_3D" ;;
        *)    echo "$DIR_DOWN" ;;
    esac
}

smista_file() {
    local FILE_DA_SMISTARE="$1"
    local NOME_FILE
    NOME_FILE=$(basename "$FILE_DA_SMISTARE")
    local ESTENSIONE=""
    # Without an extension "${NOME##*.}" would return the whole name.
    if [[ "$NOME_FILE" == *.* ]]; then
        ESTENSIONE=$(tr '[:upper:]' '[:lower:]' <<< "${NOME_FILE##*.}")
    fi

    # Archive detection is independent of sorting: extraction must work even
    # when everything goes to Downloads.
    local CATEGORIA E_ARCHIVIO=0
    CATEGORIA=$(categoria_estensione "$ESTENSIONE")
    [ "$CATEGORIA" = arch ] && E_ARCHIVIO=1

    local DESTINAZIONE="$DIR_DOWN"
    if [ "$SMISTA_ESTENSIONE" = 1 ]; then
        DESTINAZIONE=$(dir_categoria "$CATEGORIA")
    fi

    # Add a numeric suffix instead of overwriting an existing file.
    local DEST_PATH="$DESTINAZIONE/$NOME_FILE"
    if [ -e "$DEST_PATH" ]; then
        local BASE="${NOME_FILE%.*}" EXT=""
        [[ "$NOME_FILE" == *.* ]] && EXT=".${NOME_FILE##*.}"
        local N=1
        while [ -e "$DESTINAZIONE/${BASE} ($N)$EXT" ]; do N=$((N+1)); done
        DEST_PATH="$DESTINAZIONE/${BASE} ($N)$EXT"
    fi

    if mv "$FILE_DA_SMISTARE" "$DEST_PATH"; then
        # Clean metadata after the move (final path) and before notifying.
        [ "$PULISCI_METADATI" = 1 ] && pulisci_metadati "$DEST_PATH" "$ESTENSIONE"

        # --- Archive (if extraction is enabled): extract it ---
        # Decided by extension, not destination, so it works without sorting.
        # No notification here: the extractor sends one when done.
        if [ "$ESTRAI_ARCHIVI" = 1 ] && [ "$E_ARCHIVIO" = 1 ]; then
            estrai_archivio "$DEST_PATH"
        else
            # In background so the loop does not wait for the click.
            notifica_click "✅ $NOME_FILE è sicuro" \
                "Ordinato in: ${DESTINAZIONE#"$HOME"/}" "$DESTINAZIONE" &
        fi
    else
        # < /dev/null: called from the while-read loop, must not consume the pipe.
        zenity --error --text="Impossibile spostare $(escape_markup "$NOME_FILE") in $(escape_markup "$DESTINAZIONE")" < /dev/null 2>/dev/null
    fi
}

# Destination of a DIRECTORY (e.g. a multi-file torrent): the category with
# the most BYTES wins, not the most files (a movie folder has one large .mkv
# among many .jpg/.nfo/.srt). No forks inside the loop.
destinazione_cartella() {
    local D="$1" DIM NOME EXT CAT
    declare -A PESO=()
    while read -r DIM NOME; do
        [[ "$NOME" == *.* ]] || continue
        EXT="${NOME##*.}"
        CAT=$(categoria_estensione "${EXT,,}")
        [ -n "$CAT" ] || continue
        PESO[$CAT]=$(( ${PESO[$CAT]:-0} + DIM ))
    done < <(find "$D" -type f -printf '%s %f\n' 2>/dev/null)

    local MIGLIORE="" MAX=0
    for CAT in "${!PESO[@]}"; do
        if [ "${PESO[$CAT]}" -gt "$MAX" ]; then MAX="${PESO[$CAT]}"; MIGLIORE="$CAT"; fi
    done
    dir_categoria "$MIGLIORE"
}

# Move a whole DIRECTORY without opening it, so albums/series stay together.
# For the same reason contained archives are not extracted and exiftool is
# not run.
smista_cartella() {
    local CARTELLA="$1" NOME DESTINAZIONE
    NOME=$(basename "$CARTELLA")

    DESTINAZIONE="$DIR_DOWN"
    if [ "$SMISTA_ESTENSIONE" = 1 ]; then
        DESTINAZIONE=$(destinazione_cartella "$CARTELLA")
    fi

    # Same collision handling as files (suffix at the end, no extension).
    local DEST_PATH="$DESTINAZIONE/$NOME"
    if [ -e "$DEST_PATH" ]; then
        local N=1
        while [ -e "$DESTINAZIONE/$NOME ($N)" ]; do N=$((N+1)); done
        DEST_PATH="$DESTINAZIONE/$NOME ($N)"
    fi

    if mv "$CARTELLA" "$DEST_PATH"; then
        notifica_click "📁 $NOME è sicura" \
            "Cartella ordinata in: ${DESTINAZIONE#"$HOME"/}" "$DEST_PATH" &
    else
        zenity --error --text="Impossibile spostare la cartella $(escape_markup "$NOME") in $(escape_markup "$DESTINAZIONE")" < /dev/null 2>/dev/null
    fi
}

# Print the processes holding the file open FOR WRITING; returns 0 if any.
# This is the decisive test for torrents (size alone says nothing).
# lsof -F emits one field per line: p<pid>, c<command>, f<fd>, a<mode>
# (r/w/u). Readers only (players, thumbnailers, seeding clients) don't count.
scrittori_attivi() {
    local F="$1" REAL
    REAL=$(readlink -f -- "$F" 2>/dev/null) || return 1
    if command -v lsof &>/dev/null; then
        lsof -Fpcfa -- "$REAL" 2>/dev/null | awk '
            /^c/ { CMD = substr($0, 2) }
            /^a[wu]/ { print CMD }' | sort -u | grep . || return 1
    else
        # Fallback without lsof: scan /proc fd links and open flags
        # (octal; low bits 1=O_WRONLY, 2=O_RDWR).
        local FD PID NUM FLAGS TROVATI=""
        while IFS= read -r FD; do
            PID=${FD#/proc/}; PID=${PID%%/*}; NUM=${FD##*/}
            FLAGS=$(awk '/^flags:/{print $2; exit}' "/proc/$PID/fdinfo/$NUM" 2>/dev/null)
            [[ "$FLAGS" =~ ^[0-7]+$ ]] || continue
            case $(( 8#$FLAGS & 3 )) in
                1|2) TROVATI+="$(cat "/proc/$PID/comm" 2>/dev/null)"$'\n' ;;
            esac
        done < <(find /proc -maxdepth 3 -path '/proc/[0-9]*/fd/*' -lname "$REAL" 2>/dev/null)
        [ -n "$TROVATI" ] || return 1
        sort -u <<< "$TROVATI" | grep .
    fi
}

# A torrent still downloading is sparse: pieces arrive out of order, so the
# apparent size is already final while allocated blocks are far fewer.
# Everything in PreDownload comes from the network, so sparse = incomplete.
# Call AFTER a sync, or ext4 delayed allocation makes fresh files look sparse.
file_sparso() {
    local S B
    read -r S B < <(stat -c '%s %b' "$1" 2>/dev/null) || return 1
    [[ "${S:-}" =~ ^[0-9]+$ && "${B:-}" =~ ^[0-9]+$ ]] || return 1
    [ "$S" -gt 65536 ] || return 1   # small files: block granularity misleads
    [ $((B * 512)) -lt $((S / 10 * 9)) ]
}

# --- The three probes, for a file or a DIRECTORY (recursive) ---
scrittori() {
    local P="$1"
    if [ -d "$P" ]; then
        # +D recurses. The most expensive call, but it runs every 15 s only
        # while a download is active.
        lsof -Fpcfa +D "$P" 2>/dev/null | awk '
            /^c/ { CMD = substr($0, 2) }
            /^a[wu]/ { print CMD }' | sort -u | grep . || return 1
    else
        scrittori_attivi "$P"
    fi
}
sparso() {
    local P="$1"
    if [ -d "$P" ]; then
        # A single sparse file means the torrent is not finished.
        find "$P" -type f -printf '%s %b\n' 2>/dev/null |
            awk '$1 > 65536 && $2 * 512 < $1 / 10 * 9 { trovato = 1 }
                 END { exit !trovato }'
    else
        file_sparso "$P"
    fi
}
istantanea() {
    local P="$1"
    if [ -d "$P" ]; then
        # Signature of all contents: size and mtime of every file. Torrent files
        # are preallocated, so the size does not change but the mtime does.
        find "$P" -printf '%s %T@ %p\n' 2>/dev/null | sort | sha1sum
    else
        stat -c '%s %Y' "$P" 2>/dev/null
    fi
}

# Wait until the download is REALLY finished. All three must hold:
#   1) no process has it open for writing;
#   2) it is no longer sparse;
#   3) size and mtime are identical across two reads.
# (1) and (2) are needed for torrents: the client writes in place without a
# temporary suffix and the size jumps to the total early on.
# Returns 0 when ready, 1 to leave the entry where it is.
attendi_file_pronto() {
    local FILE_PATH="$1" FILENAME="$2"
    local STATO_PREC="" STATO_ATT SCRITTORI AVVISATO=0 SCADENZA MAI_VISTI_FILE=0
    SCADENZA=$(( $(date +%s) + ATTESA_MAX_MINUTI * 60 ))
    while [ "$(date +%s)" -lt "$SCADENZA" ]; do
        [ -e "$FILE_PATH" ] || return 1
        # Empty directory: just created by the torrent client, files are coming.
        # Do not sort it while empty.
        if [ -d "$FILE_PATH" ] && [ -z "$(find "$FILE_PATH" -type f -print -quit 2>/dev/null)" ]; then
            MAI_VISTI_FILE=1
            sleep 2
            continue
        fi
        MAI_VISTI_FILE=0
        if SCRITTORI=$(scrittori "$FILE_PATH"); then
            case "$SCRITTORI" in
                *qbittorrent*|*transmission*|*deluge*|*rtorrent*|*ktorrent*|*aria2*|*tixati*|*libtorrent*)
                    ERA_TORRENT=1 ;;
            esac
            if [ "$AVVISATO" = 0 ]; then
                AVVISATO=1
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏳ $FILENAME è aperto in scrittura da: $(tr '\n' ' ' <<< "$SCRITTORI")— aspetto la fine del download." >> "$LOG_ESTRAZIONI"
            fi
            STATO_PREC=""      # restart the stability check
            sleep 15           # long wait: torrents can take hours
            continue
        fi
        STATO_ATT=$(istantanea "$FILE_PATH")
        [ -n "$STATO_ATT" ] || return 1
        if [ "$STATO_ATT" = "$STATO_PREC" ]; then
            # Flush before checking sparseness (see file_sparso). For directories
            # sync the whole filesystem (-f): cheaper on a dedicated volume.
            if [ -d "$FILE_PATH" ]; then sync -f -- "$FILE_PATH" 2>/dev/null
            else sync -- "$FILE_PATH" 2>/dev/null; fi
            sparso "$FILE_PATH" || return 0
            STATO_PREC=""      # still sparse: keep waiting
        else
            STATO_PREC="$STATO_ATT"
        fi
        sleep 2
    done
    # Directory stayed empty the whole time: not a download, leave it.
    [ "$MAI_VISTI_FILE" = 1 ] && return 1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏳ $FILENAME: ancora in scrittura dopo $ATTESA_MAX_MINUTI minuti, lasciato in PreDownload." >> "$LOG_ESTRAZIONI"
    if command -v notify-send &>/dev/null; then
        notify-send --app-name="MusiGuard" --icon=dialog-warning "⏳ Download ancora in corso" "$FILENAME non è ancora completo: lasciato in PreDownload, verrà riprocessato a download finito." 2>/dev/null
    fi
    return 1
}

# Process ONE entry: wait, scan, then sort or quarantine. Runs in background
# because waiting can take hours and the main loop is serial.
# A per-entry flock -n deduplicates: a download fires many close_write events
# on the same name, only the first handler proceeds.
DIR_LOCK="${XDG_RUNTIME_DIR:-/tmp}/musiguard"
mkdir -p "$DIR_LOCK"
gestisci_file() {
    local FILENAME="$1" LOCK_FILE
    LOCK_FILE="$DIR_LOCK/$(printf '%s' "$FILENAME" | sha1sum | cut -d' ' -f1).lock"
    (
        exec 9>&-              # do not hold the global lock for hours
        flock -n 8 || exit 0   # already queued: duplicate event
        local FILE_PATH="$DIR_PRE/$FILENAME"
        ERA_TORRENT=0
        attendi_file_pronto "$FILE_PATH" "$FILENAME" || exit 0

        RISULTATO_AV=$("$SCRIPT_AV" "$FILE_PATH" 2>&1)
        IS_SAFE=$?

        if [ "$IS_SAFE" -eq 0 ]; then
            if [ -d "$FILE_PATH" ]; then smista_cartella "$FILE_PATH"
            else smista_file "$FILE_PATH"; fi
            # Moving a torrent's file breaks seeding in the client: tell the user.
            if [ "$ERA_TORRENT" = 1 ] && command -v notify-send &>/dev/null; then
                notify-send --app-name="MusiGuard" --icon=dialog-information \
                    "🌀 Torrent completato e smistato" \
                    "$FILENAME è stato spostato: rimuovi il torrent da qBittorrent (il seeding si fermerà)." 2>/dev/null
            fi
        else
            # Quarantine: move immediately into .Quarantena/ with chmod 000 (no app can
            # open it; the owner can still delete or restore it). The user prompt comes
            # afterwards, without blocking the queue.
            mkdir -p "$DIR_QUARANTENA"
            DEST_Q="$DIR_QUARANTENA/$FILENAME"
            if [ -e "$DEST_Q" ]; then
                BASE_Q="${FILENAME%.*}"; EXT_Q=""
                [[ "$FILENAME" == *.* ]] && EXT_Q=".${FILENAME##*.}"
                N=1
                while [ -e "$DIR_QUARANTENA/${BASE_Q} ($N)$EXT_Q" ]; do N=$((N+1)); done
                DEST_Q="$DIR_QUARANTENA/${BASE_Q} ($N)$EXT_Q"
            fi
            if ! mv "$FILE_PATH" "$DEST_Q"; then
                zenity --error --text="Impossibile mettere in quarantena $(escape_markup "$FILENAME")" < /dev/null 2>/dev/null
                exit 0
            fi
            chmod 000 "$DEST_Q"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ☣️ IN QUARANTENA: $(basename "$DEST_Q") | Motivo: $(tr '\n' ' ' <<< "$RISULTATO_AV")" >> "$LOG_QUARANTENA"

            # Non-blocking dialog in a background subshell: the file is already safe,
            # so an ignored dialog does not stall the queue. Pango escaping,
            # < /dev/null (don't steal inotifywait's stdin), ${SCELTA%%|*} for the
            # zenity --list double-click quirk.
            (
                exec 9>&- 8>&-   # no locks held by a long-open dialog
                RISULTATO_ESC=$(escape_markup "$RISULTATO_AV")
                SCELTA=$(zenity --list --title="⚠️ Attenzione: File Sospetto" \
                    --text="<b>$(escape_markup "$FILENAME")</b> è stato messo in QUARANTENA (PreDownload/.Quarantena).\n\n<b>Problemi rilevati:</b>\n\n$RISULTATO_ESC\n\n<b>Cosa facciamo?</b>" \
                    --column="ID" --column="Azione" --hide-column=1 \
                    1 "🗑️ 1. Elimina definitivamente" \
                    2 "🛡️ 2. Lascia in quarantena" \
                    3 "⚠️ 3. Ignora il rischio e Smista" \
                    --width=520 --height=360 < /dev/null 2>/dev/null)
                case "${SCELTA%%|*}" in
                    1) rm -rf -- "$DEST_Q"   # -r: may be a directory
                       echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🗑️ Eliminato dall'utente: $(basename "$DEST_Q")" >> "$LOG_QUARANTENA"
                       zenity --notification --text="🗑️ File $FILENAME eliminato." 2>/dev/null ;;
                    3) if [ -d "$DEST_Q" ]; then chmod 755 "$DEST_Q"; else chmod 644 "$DEST_Q"; fi
                       echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Rischio ignorato dall'utente, smistato: $(basename "$DEST_Q")" >> "$LOG_QUARANTENA"
                       if [ -d "$DEST_Q" ]; then smista_cartella "$DEST_Q"; else smista_file "$DEST_Q"; fi
                       zenity --warning --text="⚠️ $(escape_markup "$FILENAME") smistato (Rischio ignorato)." < /dev/null 2>/dev/null ;;
                    *) # Choice 2, dialog closed or no zenity: keep it.
                       zenity --notification --text="🛡️ $FILENAME resta in quarantena." 2>/dev/null ;;
                esac
            ) &
        fi
    ) 8>"$LOCK_FILE" < /dev/null &
}

# Entries never touched in PreDownload:
#  - partial files of browsers, download managers and torrent clients
#    (.part, .crdownload, .!qB, ...): the final file arrives via rename
#    (moved_to);
#  - lost+found (PreDownload may be its own ext4 filesystem);
#  - dotfiles, including .Quarantena (must never be re-queued).
da_ignorare() {
    case "$1" in
        .*|lost+found) return 0 ;;
        *.part|*.crdownload|*.partial|*.filepart|*.opdownload|*.download) return 0 ;;
        *.!qB|*.!ut|*.bc!|*.dctmp|*.aria2|*.td) return 0 ;;
    esac
    return 1
}

# Startup recovery: re-queue whatever is already in PreDownload (arrived while
# the guardian was stopped, timed out, or torrent folders created earlier).
# Handlers run in background and can wait, so in-progress downloads are fine.
while IFS= read -r -d '' PERCORSO; do
    VOCE=$(basename "$PERCORSO")
    da_ignorare "$VOCE" && continue
    gestisci_file "$VOCE"
done < <(find "$DIR_PRE" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

# read -r keeps backslashes, IFS= keeps leading/trailing spaces.
# 'create' is needed for multi-file torrents: their directory is created,
# not written or moved, so it emits neither close_write nor moved_to.
inotifywait -m -e close_write,moved_to,create --format "%f" "$DIR_PRE" | while IFS= read -r FILENAME
do
    da_ignorare "$FILENAME" && continue

    # -e, not -f: the entry may be a directory.
    if [ ! -e "$DIR_PRE/$FILENAME" ]; then continue; fi

    gestisci_file "$FILENAME"
done
