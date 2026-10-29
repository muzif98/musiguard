#!/bin/bash
# set -u: undefined variables are fatal, not silently empty.
set -u

# "${1-}": with set -u a missing $1 would abort before our own error message.
FILE="${1-}"
NOME_FILE=$(basename "$FILE")
# A DIRECTORY is accepted too (multi-file torrents). The same checks run on
# every contained file; ClamAV runs once, recursively (without the daemon,
# clamscan reloads ~1 GB of signatures per call), and the two hash-based
# checks are disabled (see below).
MODO_CARTELLA=0
if [ -d "$FILE" ]; then
    MODO_CARTELLA=1
elif [ ! -f "$FILE" ]; then
    echo "Errore: File non trovato."; exit 1
fi
PROBLEMI=""

# CHIEDI_SHA from ~/.config/musiguard.conf (default on). The config is only
# parsed, never sourced: only "CHIEDI_SHA=number" is accepted, anything else
# is ignored; the last occurrence wins.
CHIEDI_SHA=1
CONF="${HOME}/.config/musiguard.conf"
if [ -f "$CONF" ]; then
    VALORE=$(grep -E '^CHIEDI_SHA=[0-9]+$' "$CONF" | tail -n1 | cut -d= -f2)
    [ -n "$VALORE" ] && CHIEDI_SHA="$VALORE"
fi

# Optional VirusTotal second opinion: lookup of the SHA256 only (API v3), the
# file never leaves the machine. Enabled only if CONTROLLO_VT=1 (default) AND
# ~/.config/musiguard-vt.key holds an API key (strictly one 64-hex line;
# parsed, never executed).
CONTROLLO_VT=1
if [ -f "$CONF" ]; then
    VALORE=$(grep -E '^CONTROLLO_VT=[0-9]+$' "$CONF" | tail -n1 | cut -d= -f2)
    [ -n "$VALORE" ] && CONTROLLO_VT="$VALORE"
fi
VT_KEYFILE="${HOME}/.config/musiguard-vt.key"
VT_KEY=""
if [ "$CONTROLLO_VT" = "1" ] && [ -f "$VT_KEYFILE" ] && command -v curl &>/dev/null; then
    VT_KEY=$(grep -iE '^[a-f0-9]{64}$' "$VT_KEYFILE" | head -n1)
fi

# --- Hash-based checks (clipboard SHA256 + VirusTotal), in background ---
# If the clipboard holds a SHA256 copied from the download page, it is
# compared automatically; otherwise nothing happens (no popup, no hashing).
# sha256sum runs only if needed, and once for both checks. The subshell
# writes to a temp file joined later, so it runs in parallel with the local
# checks below without races.
# VirusTotal results that are not detections (unknown hash, no network,
# rate limit, rejected key) are silent: network trouble must not block
# downloads; ClamAV coverage remains.
# Clipboard tools: wl-paste (wl-clipboard, Wayland) or xclip (X11).
# Disabled for directories: one clipboard hash cannot match many files, and
# the free VirusTotal quota (4 requests/min) cannot cover a folder.
HASH_PID=""
HASH_TMP=""
if [ "$MODO_CARTELLA" = 0 ] && { [ "$CHIEDI_SHA" = "1" ] || [ -n "$VT_KEY" ]; }; then
HASH_TMP=$(mktemp)
(
    HASH_ATTESO=""
    if [ "$CHIEDI_SHA" = "1" ]; then
        CLIP=""
        if command -v wl-paste &>/dev/null; then
            CLIP=$(wl-paste 2>/dev/null)
        elif command -v xclip &>/dev/null; then
            CLIP=$(xclip -o -selection clipboard 2>/dev/null)
        fi
        # First 64-hex sequence in the clipboard, lowercased.
        HASH_ATTESO=$(grep -ioE '[a-f0-9]{64}' <<< "$CLIP" | head -n1 | tr '[:upper:]' '[:lower:]')
    fi
    HASH_CALCOLATO=""
    if [ -n "$HASH_ATTESO" ] || [ -n "$VT_KEY" ]; then
        HASH_CALCOLATO=$(sha256sum "$FILE" | awk '{print $1}')
    fi
    if [ -n "$HASH_ATTESO" ] && [ "$HASH_CALCOLATO" != "$HASH_ATTESO" ]; then
        printf '%s' "❌ SHA256 NON CORRISPONDE (hash preso dagli APPUNTI): il file potrebbe essere alterato — oppure l'hash copiato si riferisce a un ALTRO file (falso positivo possibile, controlla cosa avevi negli appunti).\n   Calcolato: $HASH_CALCOLATO\n   Atteso (appunti): $HASH_ATTESO\n\n" >> "$HASH_TMP"
    fi
    if [ -n "$VT_KEY" ]; then
        # curl -f: on 404/4xx/5xx the body is empty, nothing is parsed -> silent.
        # --max-time 15: a hanging network must not stall the download queue.
        RISPOSTA=$(curl -sf --max-time 15 -H "x-apikey: $VT_KEY" \
            "https://www.virustotal.com/api/v3/files/$HASH_CALCOLATO" 2>/dev/null)
        if command -v jq &>/dev/null; then
            VT_MAL=$(jq -r '.data.attributes.last_analysis_stats.malicious // ""' <<< "$RISPOSTA" 2>/dev/null)
            VT_SUS=$(jq -r '.data.attributes.last_analysis_stats.suspicious // ""' <<< "$RISPOSTA" 2>/dev/null)
        else
            # Fallback without jq: last_analysis_stats is a flat object, extracted
            # with grep after removing whitespace.
            STATS=$(tr -d ' \n' <<< "$RISPOSTA" | grep -oE '"last_analysis_stats":\{[^}]*\}' | head -n1)
            VT_MAL=$(grep -oE '"malicious":[0-9]+' <<< "$STATS" | head -n1 | cut -d: -f2)
            VT_SUS=$(grep -oE '"suspicious":[0-9]+' <<< "$STATS" | head -n1 | cut -d: -f2)
        fi
        [[ "${VT_MAL:-}" =~ ^[0-9]+$ ]] || VT_MAL=0
        [[ "${VT_SUS:-}" =~ ^[0-9]+$ ]] || VT_SUS=0
        if [ "$VT_MAL" -gt 0 ] || [ "$VT_SUS" -gt 0 ]; then
            printf '%s' "☣️ VIRUSTOTAL: questo file è segnalato da $VT_MAL motori antivirus come MALEVOLO e da $VT_SUS come sospetto (verificato il solo hash, il file non è stato inviato).\n   Dettagli: https://www.virustotal.com/gui/file/$HASH_CALCOLATO\n\n" >> "$HASH_TMP"
        fi
    fi
) &
HASH_PID=$!
fi

# --- Local checks, started immediately in parallel with the hash checks ---

# Extension vs. real content. A function because it is used both for single
# files and for each file in a directory (where MIME types come from a single
# "file" call).
problemi_mime() {
    local NOME="$1" REAL_TYPE="$2" EXT="" OUT=""
    [[ "$NOME" == *.* ]] && EXT="${NOME##*.}" && EXT="${EXT,,}"
    if [[ "$REAL_TYPE" == *"x-shellscript"* || "$REAL_TYPE" == *"x-executable"* || "$REAL_TYPE" == *"x-sharedlib"* || "$REAL_TYPE" == *"x-pie-executable"* ]]; then
        if [[ "$EXT" != "sh" && "$EXT" != "bin" && "$EXT" != "run" && "$EXT" != "appimage" && "$EXT" != "deb" ]]; then
            OUT+="❌ NATURA INGANNEVOLE: \"$NOME\" sembra un .$EXT ma contiene CODICE ESEGUIBILE nascosto.\n\n"
        fi
    # Windows PE executables (x-dosexec / x-msdownload) disguised as other
    # types; separate whitelist (exe/msi only).
    elif [[ "$REAL_TYPE" == *"x-dosexec"* || "$REAL_TYPE" == *"x-msdownload"* ]]; then
        if [[ "$EXT" != "exe" && "$EXT" != "msi" ]]; then
            OUT+="❌ NATURA INGANNEVOLE: \"$NOME\" sembra un .$EXT ma è un ESEGUIBILE WINDOWS camuffato.\n\n"
        fi
    fi
    printf '%s' "$OUT"
}

# Name anti-spoofing (the MIME check looks at content; this looks at what the
# user actually sees):
# 1) Invisible/bidirectional Unicode (RTLO U+202E, zero-width U+200B..,
#    isolates U+2066..): "invoice<RTLO>fdp.exe" displays as "invoiceexe.pdf".
# 2) Misleading double extension ("fattura.pdf.exe"): an executable/script
#    final extension after a document/media one. Also covers types the MIME
#    check misses (js/vbs/ps1 are plain text, jar is a zip). Spaces around
#    the second-to-last extension are dropped to defeat padding tricks.
problemi_nome() {
    local NOME="$1" EXT="" OUT="" SENZA_ULTIMA EXT_PENULTIMA
    [[ "$NOME" == *.* ]] && EXT="${NOME##*.}" && EXT="${EXT,,}"
    if grep -qP '[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}]' <<< "$NOME"; then
        OUT+="❌ NOME INGANNEVOLE: \"$NOME\" contiene caratteri Unicode invisibili o direzionali (trucco RTLO): quello che leggi NON è il vero nome del file.\n\n"
    fi
    if [[ "$NOME" == *.*.* ]]; then
        SENZA_ULTIMA="${NOME%.*}"
        EXT_PENULTIMA="${SENZA_ULTIMA##*.}"
        EXT_PENULTIMA="${EXT_PENULTIMA,,}"
        EXT_PENULTIMA="${EXT_PENULTIMA// /}"
        case "$EXT" in
            exe|scr|com|pif|bat|cmd|msi|js|jse|vbs|vbe|wsf|ps1|hta|jar|sh|run|bin|appimage)
                case "$EXT_PENULTIMA" in
                    pdf|doc|docx|xls|xlsx|ppt|pptx|odt|txt|rtf|csv|jpg|jpeg|png|gif|webp|svg|mp3|wav|flac|mp4|mkv|avi|mov|zip|rar|7z)
                        OUT+="❌ DOPPIA ESTENSIONE INGANNEVOLE: \"$NOME\" si spaccia per un .$EXT_PENULTIMA ma in realtà è un .$EXT (eseguibile/script). Trucco classico per far aprire malware.\n\n"
                        ;;
                esac
                ;;
        esac
    fi
    printf '%s' "$OUT"
}

if [ "$MODO_CARTELLA" = 0 ]; then
    REAL_TYPE=$(file -b --mime-type "$FILE")
    PROBLEMI+=$(problemi_mime "$NOME_FILE" "$REAL_TYPE")
    PROBLEMI+=$(problemi_nome "$NOME_FILE")
else
    # Directory: a single "file" call for all contents (-N no padding, -F TAB
    # separator; the leftover leading space is removed with ${MIME# }).
    # Capped: on huge folders name checks would cost more than the scan itself;
    # ClamAV still covers everything recursively.
    MAX_CONTROLLI=5000
    N_ESAMINATI=0
    while IFS=$'\t' read -r PERCORSO MIME; do
        N_ESAMINATI=$((N_ESAMINATI + 1))
        if [ "$N_ESAMINATI" -gt "$MAX_CONTROLLI" ]; then
            PROBLEMI+="⚠️ Cartella con più di $MAX_CONTROLLI file: i controlli su nome ed estensione sono stati fermati al tetto (la scansione ClamAV ha comunque coperto tutto).\n\n"
            break
        fi
        NOME_INTERNO="${PERCORSO##*/}"
        PROBLEMI+=$(problemi_mime "$NOME_INTERNO" "${MIME# }")
        PROBLEMI+=$(problemi_nome "$NOME_INTERNO")
    done < <(find "$FILE" -type f -exec file --mime-type -N -F $'\t' {} + 2>/dev/null)
    # The directory name itself can be misleading too.
    PROBLEMI+=$(problemi_nome "$NOME_FILE")
fi

# ClamAV: exit 1 = virus, >=2 = scan error (not a threat).
# Prefer clamdscan (signatures already loaded in the daemon, near-instant;
# clamscan reloads them for every file). --fdpass lets the daemon read the
# file without access to $HOME. Fall back to clamscan if the daemon fails.
# clamdscan recurses by itself, clamscan needs -r.
CLAM_RIC=()
[ "$MODO_CARTELLA" = 1 ] && CLAM_RIC=(-r)
CLAM_RC=""
CLAM_OUT=""
if command -v clamdscan &> /dev/null; then
    CLAM_OUT=$(clamdscan --no-summary --fdpass "$FILE" 2>&1)
    CLAM_RC=$?
    if [ "$CLAM_RC" -ge 2 ] && command -v clamscan &> /dev/null; then
        CLAM_OUT=$(clamscan --no-summary "${CLAM_RIC[@]}" "$FILE" 2>&1)
        CLAM_RC=$?
    fi
elif command -v clamscan &> /dev/null; then
    CLAM_OUT=$(clamscan --no-summary "${CLAM_RIC[@]}" "$FILE" 2>&1)
    CLAM_RC=$?
fi
if [ -z "$CLAM_RC" ]; then
    PROBLEMI+="⚠️ ATTENZIONE: ClamAV non è installato.\n\n"
elif [ "$CLAM_RC" -eq 1 ]; then
    PROBLEMI+="☣️ MINACCIA RILEVATA DA CLAMAV:\n$CLAM_OUT\n\n"
elif [ "$CLAM_RC" -ge 2 ]; then
    PROBLEMI+="⚠️ ERRORE CLAMAV (scansione non riuscita):\n$CLAM_OUT\n\n"
fi

# --- Join the hash-based checks ---
# (skipped if both clipboard SHA and VirusTotal are off)
if [ -n "$HASH_PID" ]; then
    wait "$HASH_PID"
    if [ -s "$HASH_TMP" ]; then PROBLEMI+="$(cat "$HASH_TMP")"; fi
    rm -f "$HASH_TMP"
fi

if [ -n "$PROBLEMI" ]; then echo -e "Sono state rilevate anomalie:\n\n$PROBLEMI"; exit 1; else exit 0; fi
