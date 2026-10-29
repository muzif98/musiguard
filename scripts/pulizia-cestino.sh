#!/bin/bash
# MusiGuard weekly maintenance (musiguard-cestino.timer -> .service):
#   0. ClamAV signature freshness: read-only. Updating needs sudo, so it only
#      warns if signatures are old or clamav-freshclam is not active.
#   1. System Trash: prompt only if SVUOTA_CESTINO=1 (off by default).
#   2. MusiGuard quarantine: ALWAYS prompted, not optional (it may hold
#      malware and must not pile up unnoticed).
#   3. Log rotation, self-contained (system logrotate is usually not set up
#      for files in $HOME).
set -u

CONF="${HOME}/.config/musiguard.conf"
DIR_QUARANTENA="${HOME}/PreDownload/.Quarantena"
DIR_CESTINO="${HOME}/.local/share/Trash/files"
LOG_QUARANTENA="${HOME}/MusiGuard/quarantena.log"
LOG_CESTINO="${HOME}/MusiGuard/cestino.log"
LOG_CLAMAV="${HOME}/MusiGuard/clamav.log"
LOG_ESTRAZIONI="${HOME}/MusiGuard/estrazioni.log"

leggi_conf() {
    local V=""
    [ -f "$CONF" ] && V=$(grep -E "^$1=[0-9]+$" "$CONF" | tail -n1 | cut -d= -f2)
    echo "${V:-$2}"
}
SVUOTA_CESTINO=$(leggi_conf SVUOTA_CESTINO 0)

# Single-instance lock (same pattern as the guardian).
LOCKFILE="${HOME}/MusiGuard/.cestino.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "Pulizia settimanale già in esecuzione (lock: $LOCKFILE), esco." >&2
    exit 0
fi

escape_markup() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$1"
}

# Clicking the notification body opens the given log file.
notifica_click_log() {
    local TITOLO="$1" CORPO="$2" LOGFILE="$3"
    if command -v notify-send &>/dev/null; then
        local AZIONE
        AZIONE=$(notify-send --app-name="MusiGuard" --icon=dialog-warning --urgency=critical \
            -h int:transient:1 -t 5000 \
            -A "default=Apri log" \
            "$TITOLO" "$CORPO" 2>/dev/null)
        [ "$AZIONE" = "default" ] && xdg-open "$LOGFILE" &>/dev/null
    fi
}

# Human-readable list: size, date, name. stat per entry (not ls|awk), so
# names with spaces are handled correctly.
costruisci_elenco() {
    local DIR="$1" F P SIZE MTIME
    shift
    for F in "$@"; do
        P="$DIR/$F"
        SIZE=$(stat -c '%s' "$P" 2>/dev/null)
        MTIME=$(date -d "@$(stat -c '%Y' "$P" 2>/dev/null || echo 0)" '+%Y-%m-%d %H:%M' 2>/dev/null)
        printf '%-10s %s  %s\n' "${SIZE:-?}" "${MTIME:-?}" "$F"
    done
}

# --- 0. ClamAV signature freshness (always, read-only) ---
# Silent if ClamAV is not installed (AntiVirusDIY.sh already warns per file).
if command -v clamscan &>/dev/null || command -v clamdscan &>/dev/null; then
    DB_DIR="/var/lib/clamav"
    SOGLIA_GIORNI=7
    PIU_RECENTE=$(find "$DB_DIR" -maxdepth 1 -type f \( -name '*.cvd' -o -name '*.cld' \) -printf '%T@\n' 2>/dev/null | sort -rn | head -n1)
    if [ -z "$PIU_RECENTE" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Database firme ClamAV non trovato in $DB_DIR: impossibile verificarne la freschezza." >> "$LOG_CLAMAV"
    else
        ETA_GIORNI=$(( ( $(date +%s) - ${PIU_RECENTE%.*} ) / 86400 ))
        SERVIZIO_MSG=""
        systemctl is-active --quiet clamav-freshclam 2>/dev/null || SERVIZIO_MSG=" (il servizio di sistema clamav-freshclam risulta NON attivo)"
        if [ "$ETA_GIORNI" -gt "$SOGLIA_GIORNI" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Firme ClamAV vecchie di $ETA_GIORNI giorni$SERVIZIO_MSG. Aggiorna con: sudo systemctl enable --now clamav-freshclam (oppure: sudo freshclam)." >> "$LOG_CLAMAV"
            notifica_click_log "⚠️ Firme ClamAV non aggiornate" "Vecchie di $ETA_GIORNI giorni$SERVIZIO_MSG." "$LOG_CLAMAV"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Firme ClamAV aggiornate (ultimo aggiornamento $ETA_GIORNI giorni fa)." >> "$LOG_CLAMAV"
        fi
    fi
fi

# --- 1. System Trash (only if SVUOTA_CESTINO=1) ---
# Safety guard: proceed only if the path is exactly the expected one (e.g.
# not built from an empty HOME).
case "$DIR_CESTINO" in
    */.local/share/Trash/files) : ;;
    *) echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRORE: percorso Cestino inatteso ('$DIR_CESTINO'), controllo saltato per sicurezza." >> "$LOG_CESTINO"
       DIR_CESTINO="" ;;
esac

if [ "$SVUOTA_CESTINO" = 1 ] && [ -n "$DIR_CESTINO" ] && [ -d "$DIR_CESTINO" ]; then
    mapfile -t FILE_CESTINO < <(find "$DIR_CESTINO" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)
    if [ "${#FILE_CESTINO[@]}" -gt 0 ]; then
        N=${#FILE_CESTINO[@]}
        ELENCO_ESC=$(escape_markup "$(costruisci_elenco "$DIR_CESTINO" "${FILE_CESTINO[@]}")")
        if command -v zenity &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            if zenity --question --title="🗑️ Pulizia settimanale: Cestino di sistema" \
                --text="Ci sono <b>$N</b> elementi nel Cestino:\n\n<tt>$ELENCO_ESC</tt>\n\nVuoi eliminarli TUTTI definitivamente adesso?" \
                --ok-label="🗑️ Elimina tutti" --cancel-label="🗑️ Lascia nel Cestino" \
                --width=560 2>/dev/null; then
                # gio trash --empty follows the XDG spec (other mounts, .trashinfo
                # metadata); manual rm is only the fallback.
                if command -v gio &>/dev/null && gio trash --empty 2>>"$LOG_CESTINO"; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🗑️ Pulizia settimanale: Cestino svuotato ($N elementi, conferma utente, gio trash --empty)." >> "$LOG_CESTINO"
                else
                    rm -rf -- "${FILE_CESTINO[@]/#/$DIR_CESTINO/}"
                    rm -rf "${DIR_CESTINO%/files}/info/"* 2>/dev/null
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🗑️ Pulizia settimanale: Cestino svuotato ($N elementi, conferma utente, fallback manuale)." >> "$LOG_CESTINO"
                fi
                zenity --notification --text="🗑️ Cestino svuotato: $N elementi eliminati." 2>/dev/null
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🛡️ Pulizia settimanale: Cestino lasciato invariato dall'utente ($N elementi)." >> "$LOG_CESTINO"
            fi
        else
            # No graphical session: notify only, never delete without confirmation.
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ℹ️ Pulizia settimanale: $N elementi nel Cestino, nessuna sessione grafica per chiedere conferma (lasciati intatti)." >> "$LOG_CESTINO"
            notifica_click_log "🗑️ Cestino di sistema" "$N elementi nel Cestino da rivedere." "$LOG_CESTINO"
        fi
    fi
fi

# --- 2. MusiGuard quarantine (always, independent of step 1) ---
case "$DIR_QUARANTENA" in
    */PreDownload/.Quarantena) : ;;
    *) echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ ERRORE: percorso Quarantena inatteso ('$DIR_QUARANTENA'), controllo quarantena saltato per sicurezza." >> "$LOG_QUARANTENA"
       DIR_QUARANTENA="" ;;
esac

if [ -n "$DIR_QUARANTENA" ] && [ -d "$DIR_QUARANTENA" ]; then
    # -mindepth 1 excludes the directory itself.
    mapfile -t FILE_QUARANTENA < <(find "$DIR_QUARANTENA" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)
    if [ "${#FILE_QUARANTENA[@]}" -gt 0 ]; then
        N=${#FILE_QUARANTENA[@]}
        # chmod 000 on the files does not hide their size/date, so
        # costruisci_elenco still works.
        ELENCO_ESC=$(escape_markup "$(costruisci_elenco "$DIR_QUARANTENA" "${FILE_QUARANTENA[@]}")")
        if command -v zenity &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            if zenity --question --title="🔒 Pulizia settimanale: Quarantena MusiGuard" \
                --text="Ci sono <b>$N</b> file in quarantena (sospetti, mai eseguibili) da tempo:\n\n<tt>$ELENCO_ESC</tt>\n\nVuoi eliminarli TUTTI definitivamente adesso?" \
                --ok-label="🗑️ Elimina tutti" --cancel-label="🛡️ Lascia in quarantena" \
                --width=560 2>/dev/null; then
                rm -rf -- "${FILE_QUARANTENA[@]/#/$DIR_QUARANTENA/}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🗑️ Pulizia settimanale: eliminati $N file dalla quarantena (conferma utente)." >> "$LOG_QUARANTENA"
                zenity --notification --text="🗑️ Quarantena svuotata: $N file eliminati." 2>/dev/null
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🛡️ Pulizia settimanale: quarantena lasciata invariata dall'utente ($N file)." >> "$LOG_QUARANTENA"
            fi
        else
            # No graphical session: notify only, never delete without confirmation.
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ℹ️ Pulizia settimanale: $N file in quarantena, nessuna sessione grafica per chiedere conferma (lasciati intatti)." >> "$LOG_QUARANTENA"
            notifica_click_log "🔒 Quarantena MusiGuard" "$N file in quarantena da rivedere." "$LOG_QUARANTENA"
        fi
    fi
fi

# --- 3. Log rotation (always, last) ---
# Size-based: a log that does not grow is never rotated. Cascade
# .3->.4 (dropped), .2->.3, .1->.2, FILE->.1. A plain mv is safe because every
# writer appends with ">>" and keeps no long-lived descriptor.
ruota_log() {
    local FILE="$1" MAX_BYTES=2097152 MAX_BACKUP=4 SIZE N
    [ -f "$FILE" ] || return 0
    SIZE=$(stat -c '%s' "$FILE" 2>/dev/null) || return 0
    [ "$SIZE" -le "$MAX_BYTES" ] && return 0
    for ((N = MAX_BACKUP; N >= 1; N--)); do
        if [ -f "${FILE}.${N}" ]; then
            if [ "$N" -eq "$MAX_BACKUP" ]; then rm -f "${FILE}.${N}"; else mv "${FILE}.${N}" "${FILE}.$((N + 1))"; fi
        fi
    done
    mv "$FILE" "${FILE}.1"
    : > "$FILE"
}
ruota_log "$LOG_ESTRAZIONI"
ruota_log "$LOG_QUARANTENA"
ruota_log "$LOG_CESTINO"
ruota_log "$LOG_CLAMAV"
