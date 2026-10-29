#!/bin/bash
# MusiGuard module configuration. Runs automatically on first install (when
# ~/.config/musiguard.conf does not exist) and can be re-run at any time;
# current values are preselected.
# Writes only KEY=number lines: the config is parsed, never executed.
set -u

CONF="${HOME}/.config/musiguard.conf"
UNIT_DIR="${HOME}/.config/systemd/user"

# Read a numeric key from the config; fall back to the default ($2).
leggi() {
    local V=""
    [ -f "$CONF" ] && V=$(grep -E "^$1=[0-9]+$" "$CONF" | tail -n1 | cut -d= -f2)
    echo "${V:-$2}"
}

# Current state as wizard defaults (everything on at first run).
# SMISTA also honours the legacy key SMISTA_CATEGORIE.
GUARDIANO=$(leggi ATTIVA_GUARDIANO 1)
SHA=$(leggi CHIEDI_SHA 1)
VT=$(leggi CONTROLLO_VT 1)
ESTRAI=$(leggi ESTRAI_ARCHIVI 1)
SMISTA=$(leggi SMISTA_ESTENSIONE "$(leggi SMISTA_CATEGORIE 1)")
METADATI=$(leggi PULISCI_METADATI 1)
# Weekly "empty the Trash?" prompt (list + confirmation, never automatic):
# off by default.
CESTINO=$(leggi SVUOTA_CESTINO 0)
MAX_MB=$(leggi MAX_ESTRAZIONE_MB 10240)

b2z() { [ "$1" = 1 ] && echo TRUE || echo FALSE; }

if command -v zenity &>/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    # --print-column=2 returns the IDs of the checked rows, separated by |.
    SEL=$(zenity --list --checklist --title="MusiGuard — Configurazione moduli" \
        --text="Scegli i moduli da attivare (riconfigurabile con ./scripts/configura.sh):" \
        --column="Attivo" --column="ID" --column="Modulo" \
        --hide-column=2 --print-column=2 --separator="|" \
        "$(b2z "$GUARDIANO")" guardiano "🛡️ Antivirus download: controlla che i file scaricati NON siano pericolosi (da solo non smista: i file sicuri vanno in Downloads)" \
        "$(b2z "$SHA")"       sha       "🔎 Verifica SHA256 dagli appunti" \
        "$(b2z "$VT")"        vt        "🌐 Seconda opinione VirusTotal: 70+ antivirus (viaggia solo l'hash, MAI il file; serve chiave API gratuita)" \
        "$(b2z "$ESTRAI")"    estrai    "📦 Estrazione automatica degli archivi" \
        "$(b2z "$SMISTA")"    smista    "📂 Smistamento per estensione (senza: tutto in Downloads)" \
        "$(b2z "$METADATI")"  metadati  "🕵️ Privacy: rimozione metadati (GPS, autore) da foto e PDF smistati" \
        "$(b2z "$CESTINO")"   cestino   "🗑️ Chiedi se svuotare il Cestino una volta a settimana (elenco + conferma, come la Quarantena — che invece viene sempre chiesta, a parte)" \
        --width=640 --height=400 2>/dev/null) || {
        echo "Configurazione annullata: nessuna modifica."
        exit 0
    }
    attivo() { [[ "|$SEL|" == *"|$1|"* ]] && echo 1 || echo 0; }
    GUARDIANO=$(attivo guardiano)
    SHA=$(attivo sha)
    VT=$(attivo vt)
    ESTRAI=$(attivo estrai)
    SMISTA=$(attivo smista)
    METADATI=$(attivo metadati)
    CESTINO=$(attivo cestino)
else
    # Fallback without a graphical session: terminal prompts.
    chiedi() { # text default -> 0/1
        local R
        if [ "$2" = 1 ]; then
            read -rp "$1 [S/n] " R; [[ "$R" =~ ^[nN] ]] && echo 0 || echo 1
        else
            read -rp "$1 [s/N] " R; [[ "$R" =~ ^[sS] ]] && echo 1 || echo 0
        fi
    }
    echo "MusiGuard — configurazione moduli (Invio = valore tra parentesi)"
    GUARDIANO=$(chiedi "🛡️ Attivare l'antivirus download? (controlla che i file non siano pericolosi; da solo non smista)" "$GUARDIANO")
    SHA=$(chiedi "🔎 Attivare la verifica SHA256 dagli appunti?" "$SHA")
    VT=$(chiedi "🌐 Attivare la seconda opinione VirusTotal? (viaggia solo l'hash, mai il file; serve chiave API gratuita)" "$VT")
    ESTRAI=$(chiedi "📦 Attivare l'estrazione automatica degli archivi?" "$ESTRAI")
    SMISTA=$(chiedi "📂 Attivare lo smistamento per estensione?" "$SMISTA")
    METADATI=$(chiedi "🕵️ Attivare la rimozione dei metadati privacy da foto e PDF?" "$METADATI")
    CESTINO=$(chiedi "🗑️ Chiedere se svuotare il Cestino una volta a settimana? (elenco + conferma, come la Quarantena — che invece viene comunque sempre chiesta, a parte)" "$CESTINO")
fi

mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<EOF
# MusiGuard — configurazione moduli (generata da configura.sh, rilanciabile).
# Solo righe CHIAVE=numero: tutto il resto viene ignorato, mai eseguito.
ATTIVA_GUARDIANO=$GUARDIANO
CHIEDI_SHA=$SHA
CONTROLLO_VT=$VT
ESTRAI_ARCHIVI=$ESTRAI
SMISTA_ESTENSIONE=$SMISTA
PULISCI_METADATI=$METADATI
# Chiede se svuotare il Cestino una volta a settimana (musiguard-cestino.timer,
# elenco + conferma, mai automatico). La domanda sulla Quarantena, invece,
# arriva SEMPRE ogni settimana a parte: non è un modulo disattivabile.
SVUOTA_CESTINO=$CESTINO
# Tetto (MB) alla dimensione decompressa degli archivi estratti in automatico.
MAX_ESTRAZIONE_MB=$MAX_MB
EOF
echo "Configurazione salvata in $CONF"

# Metadata cleaning needs exiftool; the guardian disables it by itself if
# missing, here we just warn upfront.
if [ "$METADATI" = 1 ] && ! command -v exiftool &>/dev/null; then
    echo "⚠️ Pulizia metadati attivata ma exiftool non è installato: resterà spenta finché non lo installi (sudo apt install libimage-exiftool-perl)."
fi

# VirusTotal needs an API key; without it the check stays silently off.
VT_KEYFILE="${HOME}/.config/musiguard-vt.key"
if [ "$VT" = 1 ] && ! grep -qiE '^[a-f0-9]{64}$' "$VT_KEYFILE" 2>/dev/null; then
    echo "⚠️ Controllo VirusTotal attivato ma manca la chiave API: resterà spento finché non la metti."
    echo "   1) Account gratuito su https://www.virustotal.com -> menu profilo -> 'API key'"
    echo "   2) echo INCOLLA_QUI_LA_CHIAVE > $VT_KEYFILE && chmod 600 $VT_KEYFILE"
fi

# Apply to the services if the units are installed; the guardian reads the
# config only at startup, so it must be restarted.
if [ -f "$UNIT_DIR/musiguard-guardiano.service" ]; then
    if [ "$GUARDIANO" = 1 ]; then
        systemctl --user enable musiguard-guardiano.service >/dev/null 2>&1
        systemctl --user restart musiguard-guardiano.service
        echo "Guardiano: attivo (riavviato con la nuova configurazione)."
    else
        systemctl --user disable --now musiguard-guardiano.service 2>/dev/null
        echo "Guardiano: disattivato."
    fi
else
    echo "Unit systemd non ancora installate: lancia ./installa-servizio.sh"
fi
