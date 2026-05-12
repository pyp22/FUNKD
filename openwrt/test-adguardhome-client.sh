#!/bin/sh
# Wrapper de lancement pour test-adguardhome-client.py
# Vérifie les dépendances puis délègue au script Python.

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
BLU='\033[0;34m'
NC='\033[0m'

log()  { printf "${GRN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YLW}[!]${NC} %s\n" "$*"; }
err()  { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }
hdr()  { printf "\n${BLU}══ %s ══${NC}\n" "$*"; }

SCRIPT_DIR=$(dirname "$0")
PY_SCRIPT="${SCRIPT_DIR}/test-adguardhome-client.py"

hdr "Vérification des dépendances"

# ─── Script Python présent ────────────────────────────────────────────────────
[ -f "$PY_SCRIPT" ] || err "Script Python introuvable : $PY_SCRIPT"

# ─── Python 3 disponible ──────────────────────────────────────────────────────
PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
        PYTHON="$candidate"
        break
    fi
done
[ -n "$PYTHON" ] || err "Python 3 introuvable.
  → Installer Python 3.6+ :
      Debian/Ubuntu : apt install python3
      Fedora/RHEL   : dnf install python3
      Windows       : https://python.org/downloads"

# ─── Version Python >= 3.6 ────────────────────────────────────────────────────
PY_VER=$("$PYTHON" -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>/dev/null)
PY_MAJOR=$("$PYTHON" -c "import sys; print(sys.version_info[0])" 2>/dev/null)
PY_MINOR=$("$PYTHON" -c "import sys; print(sys.version_info[1])" 2>/dev/null)
if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 6 ]; }; then
    err "Python 3.6+ requis (version détectée : ${PY_VER}).
  → Mettre à jour Python : https://python.org/downloads"
fi
log "Python ${PY_VER} détecté ($PYTHON)"

# ─── Modules stdlib requis ────────────────────────────────────────────────────
MISSING_MODS=""
for mod in socket struct subprocess platform random os sys; do
    "$PYTHON" -c "import $mod" 2>/dev/null || MISSING_MODS="$MISSING_MODS $mod"
done
[ -z "$MISSING_MODS" ] || err "Modules Python manquants :$MISSING_MODS
  → Ces modules font partie de la stdlib, l'installation Python est peut-être corrompue."
log "Modules Python OK"

# ─── Outil réseau pour détecter la passerelle (Linux) ────────────────────────
case "$(uname -s 2>/dev/null)" in
    Linux*)
        if ! command -v ip >/dev/null 2>&1 && ! command -v route >/dev/null 2>&1; then
            warn "Aucun outil de routage trouvé (ip ou route).
  → Passer l'IP du routeur en argument : $0 <IP_ROUTEUR>"
        else
            log "Outil réseau OK ($(command -v ip || command -v route))"
        fi
        ;;
    *)
        # Windows/macOS : la détection se fait via powershell/netstat côté Python
        log "OS : $(uname -s 2>/dev/null || echo Windows)"
        ;;
esac

# ─── Lancement ────────────────────────────────────────────────────────────────
hdr "Lancement du test"
exec "$PYTHON" "$PY_SCRIPT" "$@"
