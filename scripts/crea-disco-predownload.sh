#!/bin/bash
# OPTIONAL: create the elastic PreDownload volume. MusiGuard works without it;
# this adds the recommended barrier: a sparse image file (default 50 GB
# virtual; only the space actually used is allocated) mounted on
# ~/PreDownload with noexec,nosuid,nodev.
# Run with sudo (needs mkfs, /etc/fstab and mount):
#   sudo ~/MusiGuard/scripts/crea-disco-predownload.sh [GB]
# Idempotent: an existing image is NEVER reformatted (it may hold downloads
# and quarantine); only fstab and the mount are fixed. Files already in
# ~/PreDownload are moved into the new volume.
set -eu

DIM_GB="${1:-50}"
case "$DIM_GB" in
    ''|*[!0-9]*) echo "Dimensione non valida: '$DIM_GB' (serve un numero intero di GB)" >&2; exit 1 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "Serve root: sudo $0" >&2
    exit 1
fi
# Under sudo $HOME is root's: use the real user's home (from SUDO_USER).
if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
    echo "Lancialo con sudo dal tuo utente normale, non da root diretto." >&2
    exit 1
fi
HOME_UTENTE=$(getent passwd "$SUDO_USER" | cut -d: -f6)
IMG="$HOME_UTENTE/pre_download_disk.img"
DIR_PRE="$HOME_UTENTE/PreDownload"

echo "== 1/3 Immagine disco: $IMG =="
if [ -f "$IMG" ]; then
    echo "Esiste già ($(du -h "$IMG" | cut -f1) occupati per davvero): la riuso senza formattarla."
else
    truncate -s "${DIM_GB}G" "$IMG"
    /sbin/mkfs.ext4 -q -F "$IMG"
    chown "$SUDO_USER:" "$IMG"
    echo "Creata: ${DIM_GB}GB virtuali (elastici)."
fi

echo
echo "== 2/3 /etc/fstab =="
# Drop any previous line and rewrite it, so re-runs never duplicate entries.
# nofail: a missing image never blocks boot.
sed -i '\|pre_download_disk\.img|d' /etc/fstab
echo "$IMG $DIR_PRE ext4 loop,rw,nofail,noexec,nosuid,nodev,data=ordered,errors=remount-ro,discard 0 2" >> /etc/fstab
systemctl daemon-reload
echo "Riga scritta (montaggio automatico a ogni avvio)."

echo
echo "== 3/3 Montaggio =="
mkdir -p "$DIR_PRE"
if findmnt -n "$DIR_PRE" >/dev/null; then
    echo "Già montato: niente da fare."
else
    # Existing files would be hidden under the mount point: park them and move
    # them back into the freshly mounted volume.
    PARCHEGGIO=""
    if [ -n "$(ls -A "$DIR_PRE")" ]; then
        PARCHEGGIO=$(mktemp -d "$HOME_UTENTE/.predownload-trasloco.XXXXXX")
        find "$DIR_PRE" -mindepth 1 -maxdepth 1 -exec mv -t "$PARCHEGGIO" {} +
        echo "File preesistenti parcheggiati temporaneamente."
    fi
    mount "$DIR_PRE"
    if [ -n "$PARCHEGGIO" ]; then
        find "$PARCHEGGIO" -mindepth 1 -maxdepth 1 -exec mv -t "$DIR_PRE" {} +
        rmdir "$PARCHEGGIO"
        echo "File preesistenti rimessi dentro al volume."
    fi
fi

# Always chown, even on the "already mounted" path: the daemon-reload above
# makes systemd mount the volume by itself, so the else branch is usually
# skipped and the ext4 root would stay root:root. Ownership is stored in the
# image's inode, so it survives remounts.
chown "$SUDO_USER:" "$DIR_PRE"

# Final check: the mount options must include noexec.
if findmnt -no OPTIONS "$DIR_PRE" | grep -q noexec; then
    echo "✅ $DIR_PRE è un volume noexec: nulla è eseguibile da lì."
else
    echo "⚠️ Montato ma SENZA noexec: controlla la riga in /etc/fstab." >&2
    exit 1
fi

# The guardian watches PreDownload via inotify: if it was running it now
# watches the old directory hidden under the mount, so restart it.
# try-restart only acts if it is running; another user's systemctl --user
# needs their XDG_RUNTIME_DIR.
UID_UTENTE=$(id -u "$SUDO_USER")
if runuser -u "$SUDO_USER" -- env XDG_RUNTIME_DIR="/run/user/$UID_UTENTE" \
        systemctl --user try-restart musiguard-guardiano.service 2>/dev/null; then
    echo "Guardiano riavviato: ora sorveglia il volume noexec."
else
    echo "Se il guardiano era attivo, riavvialo: systemctl --user restart musiguard-guardiano"
fi
