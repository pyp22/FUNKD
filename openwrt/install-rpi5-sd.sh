#!/bin/bash
# install-rpi5-sd.sh — Installation OpenWrt 25.12.2 pour Raspberry Pi 5
# Carte SD 512 Go, partition root de 256 Go
# Paquets supplémentaires : kmod-r8169 kmod-rtw88-8821cu kmod-rtw88 kbd kbd-keymaps

set -euo pipefail

# ============================================================
# Configuration
# ============================================================
EXTRA_PACKAGES="kmod-r8169 kmod-rtw88-8821cu kmod-rtw88 kbd kbd-keymaps"
ROOT_SIZE_GB=256
MOUNT_POINT="/tmp/openwrt-rpi5-root"

# ============================================================
# Utilitaires
# ============================================================
log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "ERREUR: $*" >&2; exit 1; }

confirm() {
    local ans
    read -r -p "$1 [y/N] " ans
    [[ "${ans,,}" == "y" ]] || die "Annulé."
}

CHROOT_ACTIVE=0
RESOLV_ORIG=""   # cible du symlink original, vide si c'était un fichier

cleanup() {
    if [[ $CHROOT_ACTIVE -eq 1 ]]; then
        for sub in sys dev proc; do
            umount "${MOUNT_POINT}/${sub}" 2>/dev/null || true
        done
        # Restaure resolv.conf
        rm -f "${MOUNT_POINT}/etc/resolv.conf"
        if [[ -n "$RESOLV_ORIG" ]]; then
            ln -s "$RESOLV_ORIG" "${MOUNT_POINT}/etc/resolv.conf"
        fi
        rm -f "${MOUNT_POINT}/usr/bin/qemu-aarch64-static"
        CHROOT_ACTIVE=0
    fi
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log "Démontage en cours (nettoyage)..."
        umount -R "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" || true
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

usage() {
    cat <<EOF
Usage : sudo $0 [image] [périphérique]

  image        Fichier image OpenWrt (.img, .img.gz ou .img.zst) — optionnel
               ex : openwrt-25.12.2-bcm27xx-bcm2712-rpi-5-ext4-factory.img.gz
               Si omis, les fichiers openwrt-25.12.2* du répertoire courant
               sont listés et vous êtes invité à choisir.
  périphérique Bloc-device de la carte SD — optionnel
               ex : /dev/sdb  ou  /dev/mmcblk0
               Si omis, la liste des périphériques USB est affichée
               et vous êtes invité à choisir.

Exemples :
  sudo $0
  sudo $0 openwrt-25.12.2-bcm27xx-bcm2712-rpi-5-ext4-factory.img.gz /dev/sdb
EOF
    exit 0
}

IMAGE_GLOB="openwrt-25.12.2*"

select_image() {
    local files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find . -maxdepth 1 -name "$IMAGE_GLOB" \
             \( -name "*.img" -o -name "*.img.gz" -o -name "*.img.zst" \) \
             -print0 | sort -z)

    if [[ ${#files[@]} -eq 0 ]]; then
        echo ""
        echo "  Aucun fichier correspondant à « $IMAGE_GLOB » trouvé dans :"
        echo "  $(pwd)"
        echo ""
        return 1
    fi

    echo ""
    echo "  Images OpenWrt disponibles dans $(pwd) :"
    echo "  ┌────┬──────────┬──────────────────────────────────────────────────┐"
    printf "  │ %-2s │ %-8s │ %-48s │\n" "N°" "TAILLE" "FICHIER"
    echo "  ├────┼──────────┼──────────────────────────────────────────────────┤"
    local i
    for i in "${!files[@]}"; do
        local size
        size=$(du -h "${files[$i]}" 2>/dev/null | cut -f1)
        printf "  │ %-2d │ %-8s │ %-48s │\n" \
            $(( i + 1 )) "$size" "$(basename "${files[$i]}")"
    done
    echo "  └────┴──────────┴──────────────────────────────────────────────────┘"
    echo ""

    local choice
    while true; do
        read -r -p "  Choisissez une image [1-${#files[@]}] : " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           [[ "$choice" -ge 1 && "$choice" -le ${#files[@]} ]]; then
            IMAGE="${files[$(( choice - 1 ))]}"
            IMAGE="${IMAGE#./}"
            return 0
        else
            echo "  Choix invalide : entrez un nombre entre 1 et ${#files[@]}."
        fi
    done
}

list_usb_devices() {
    local devices=()
    while IFS= read -r line; do
        devices+=("$line")
    done < <(lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN --sort NAME \
             | awk 'NR==1 { print; next } /usb/ { print }')

    if [[ ${#devices[@]} -le 1 ]]; then
        echo ""
        echo "  Aucun périphérique USB de stockage détecté."
        echo "  Branchez la carte SD et relancez le script."
        echo ""
        return 1
    fi

    echo ""
    echo "  Périphériques USB de stockage détectés :"
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    # en-tête
    printf "  │  %-10s %-8s %-20s %-12s │\n" \
        "${devices[0]%% *}" "TAILLE" "MODÈLE" "SÉRIE"
    echo "  ├─────────────────────────────────────────────────────────────┤"
    local i=1
    while [[ $i -lt ${#devices[@]} ]]; do
        local dev size model serial
        read -r dev size model serial _ <<< "${devices[$i]}"
        printf "  │  %-10s %-8s %-20s %-12s │\n" \
            "/dev/${dev}" "${size}" "${model:0:20}" "${serial:0:12}"
        (( i++ ))
    done
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
}

select_device() {
    list_usb_devices || return 1

    local input
    while true; do
        read -r -p "  Entrez le périphérique cible (ex: /dev/sdb) : " input
        input="${input// /}"                    # supprime les espaces
        [[ "$input" == /dev/* ]] || input="/dev/${input}"   # accepte "sdb" aussi
        if [[ -b "$input" ]]; then
            DEVICE="$input"
            return 0
        else
            echo "  Périphérique invalide ou introuvable : $input"
        fi
    done
}

check_root() {
    [[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en tant que root (sudo $0 ...)."
}

check_deps() {
    local missing=()
    for cmd in dd parted resize2fs e2fsck partprobe lsblk gzip chroot; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    # binfmt_misc doit être configuré pour aarch64
    [[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] || missing+=("binfmt_misc/qemu-aarch64 (apt install qemu-user-static binfmt-support)")
    [[ ${#missing[@]} -eq 0 ]] || \
        die "Commandes/config manquantes : ${missing[*]}
Installez-les avec : apt install parted e2fsprogs qemu-user-static binfmt-support"
}

download_packages_offline() {
    local mount_pt="$1"
    local pkg_dest="${mount_pt}/root/packages"

    mkdir -p "$pkg_dest"

    # ---- Mise en place du chroot aarch64 ----
    # binfmt_misc (flag P) gère la traduction aarch64→x86_64 automatiquement
    log "  Préparation du chroot aarch64…"
    mount --bind /proc  "${mount_pt}/proc"
    mount --bind /dev   "${mount_pt}/dev"
    mount --bind /sys   "${mount_pt}/sys"

    # resolv.conf est un symlink mort dans OpenWrt (→ /tmp/resolv.conf inexistant)
    # On le remplace temporairement par une copie du resolv.conf de l'hôte
    if [[ -L "${mount_pt}/etc/resolv.conf" ]]; then
        RESOLV_ORIG=$(readlink "${mount_pt}/etc/resolv.conf")
        rm -f "${mount_pt}/etc/resolv.conf"
    else
        RESOLV_ORIG=""
    fi
    cp /etc/resolv.conf "${mount_pt}/etc/resolv.conf"
    CHROOT_ACTIVE=1

    # ---- Mise à jour de l'index apk ----
    log "  Mise à jour de l'index apk (depuis les dépôts officiels)…"
    chroot "$mount_pt" /usr/bin/apk update 2>&1 | while IFS= read -r l; do log "    $l"; done

    # ---- Téléchargement des paquets + dépendances (paquet par paquet) ----
    log "  Téléchargement des paquets et de leurs dépendances…"
    local pkg_ok=() pkg_fail=()
    for pkg in $EXTRA_PACKAGES; do
        local out rc
        out=$(chroot "$mount_pt" /usr/bin/apk fetch --recursive --output /root/packages "$pkg" 2>&1) && rc=0 || rc=$?
        if [[ $rc -eq 0 ]]; then
            log "    OK : $pkg"
            pkg_ok+=("$pkg")
        else
            log "    INTROUVABLE : $pkg"
            echo "$out" | grep -v '^$' | while IFS= read -r l; do log "      $l"; done
            pkg_fail+=("$pkg")
        fi
    done
    [[ ${#pkg_fail[@]} -gt 0 ]] && \
        log "  AVERTISSEMENT : paquets absents des dépôts : ${pkg_fail[*]}"

    # ---- Démontage du chroot ----
    for sub in sys dev proc; do
        umount "${mount_pt}/${sub}" 2>/dev/null || true
    done
    # Restaure resolv.conf
    rm -f "${mount_pt}/etc/resolv.conf"
    if [[ -n "$RESOLV_ORIG" ]]; then
        ln -s "$RESOLV_ORIG" "${mount_pt}/etc/resolv.conf"
    fi
    CHROOT_ACTIVE=0

    local count
    count=$(find "$pkg_dest" -name "*.apk" 2>/dev/null | wc -l)
    log "  ${count} paquet(s) téléchargé(s) dans /root/packages/ (${#pkg_ok[@]} demandé(s) OK, ${#pkg_fail[@]} absent(s))"
    [[ $count -gt 0 ]] || die "Aucun paquet téléchargé — vérifiez la connexion internet de l'hôte."
}

# ============================================================
# Arguments
# ============================================================
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

IMAGE="${1:-}"
DEVICE="${2:-}"

# ============================================================
# Vérifications
# ============================================================
check_root
check_deps

if [[ -z "$IMAGE" ]]; then
    select_image || die "Aucune image sélectionnable. Placez un fichier openwrt-25.12.2*.img[.gz|.zst] dans le répertoire courant."
fi
[[ -f "$IMAGE" ]] || die "Fichier image introuvable : $IMAGE"

if [[ -z "$DEVICE" ]]; then
    select_device || die "Impossible de sélectionner un périphérique."
fi
[[ -b "$DEVICE" ]] || die "Périphérique invalide ou absent : $DEVICE"

# Taille de la carte
DEVICE_SIZE_BYTES=$(lsblk -b -d -n -o SIZE "$DEVICE")
DEVICE_SIZE_GB=$(( DEVICE_SIZE_BYTES / 1024 / 1024 / 1024 ))
log "Périphérique : $DEVICE — ${DEVICE_SIZE_GB} Go détectés"
[[ $DEVICE_SIZE_GB -ge $ROOT_SIZE_GB ]] || \
    die "Carte trop petite (${DEVICE_SIZE_GB} Go). Minimum requis : ${ROOT_SIZE_GB} Go."

# Vérifier qu'aucune partition du device n'est montée
if lsblk -n -o MOUNTPOINT "$DEVICE" | grep -q .; then
    die "$DEVICE ou l'une de ses partitions est montée. Démontez d'abord."
fi

# ============================================================
# Confirmation finale
# ============================================================
echo ""
echo "  Image   : $IMAGE"
echo "  Cible   : $DEVICE  (${DEVICE_SIZE_GB} Go)"
echo "  Root    : ${ROOT_SIZE_GB} Go (partition 2)"
echo "  Paquets : $EXTRA_PACKAGES"
echo ""
confirm "ATTENTION : toutes les données sur $DEVICE seront EFFACÉES. Continuer ?"

# ============================================================
# Écriture de l'image
# ============================================================
log "Écriture de l'image sur $DEVICE…"

case "$IMAGE" in
    *.img.gz|*.gz)
        command -v gzip &>/dev/null || die "gzip introuvable."
        log "  (décompression gzip à la volée)"
        gzip -dc "$IMAGE" | dd of="$DEVICE" bs=4M conv=fsync status=progress
        ;;
    *.img.zst|*.zst)
        command -v zstd &>/dev/null || die "zstd introuvable. Installez-le : apt install zstd"
        log "  (décompression zstd à la volée)"
        zstd -dc "$IMAGE" | dd of="$DEVICE" bs=4M conv=fsync status=progress
        ;;
    *.img)
        dd if="$IMAGE" of="$DEVICE" bs=4M conv=fsync status=progress
        ;;
    *)
        die "Format non reconnu : $IMAGE  (attendu : .img  .img.gz  .img.zst)"
        ;;
esac

sync
log "Image écrite."

# ============================================================
# Relecture de la table de partitions
# ============================================================
log "Relecture de la table de partitions…"
partprobe "$DEVICE" 2>/dev/null || blockdev --rereadpt "$DEVICE" || true
sleep 2

# Nommage des partitions selon le type de périphérique
if [[ "$DEVICE" =~ mmcblk|nvme ]]; then
    BOOT_PART="${DEVICE}p1"
    ROOT_PART="${DEVICE}p2"
else
    BOOT_PART="${DEVICE}1"
    ROOT_PART="${DEVICE}2"
fi

[[ -b "$ROOT_PART" ]] || die "Partition root introuvable après écriture : $ROOT_PART"

# ============================================================
# Agrandissement de la partition root à 256 Go
# ============================================================
log "Agrandissement de la partition root à ${ROOT_SIZE_GB} Go…"

# La partition 2 se termine maintenant à ROOT_SIZE_GB depuis le début du disque
parted -s "$DEVICE" resizepart 2 "${ROOT_SIZE_GB}GB"

partprobe "$DEVICE" 2>/dev/null || blockdev --rereadpt "$DEVICE" || true
sleep 2

log "Vérification du système de fichiers ext4…"
e2fsck -f -y "$ROOT_PART" || true

log "Extension du système de fichiers…"
resize2fs "$ROOT_PART"

log "Partition root : ${ROOT_SIZE_GB} Go — OK"

# ============================================================
# Correction du PARTUUID dans cmdline.txt
# parted écrase la signature MBR lors du resize ; on met cmdline.txt
# en cohérence avec le PARTUUID réellement présent sur le disque.
# ============================================================
log "Vérification du PARTUUID dans cmdline.txt…"
mkdir -p "${MOUNT_POINT}-boot"
mount "$BOOT_PART" "${MOUNT_POINT}-boot"

ACTUAL_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART")
CMDLINE_FILE="${MOUNT_POINT}-boot/cmdline.txt"

if grep -q "root=PARTUUID=" "$CMDLINE_FILE"; then
    CURRENT_PARTUUID=$(grep -o 'root=PARTUUID=[^ ]*' "$CMDLINE_FILE" | cut -d= -f3)
    if [[ "$CURRENT_PARTUUID" != "$ACTUAL_PARTUUID" ]]; then
        log "  PARTUUID corrigé : $CURRENT_PARTUUID → $ACTUAL_PARTUUID"
        sed -i "s/root=PARTUUID=[^ ]*/root=PARTUUID=${ACTUAL_PARTUUID}/" "$CMDLINE_FILE"
        # partuuid.txt (utilisé par le buildroot OpenWrt, pas critique au boot)
        [[ -f "${MOUNT_POINT}-boot/partuuid.txt" ]] && \
            echo "${ACTUAL_PARTUUID%-*}" > "${MOUNT_POINT}-boot/partuuid.txt"
    else
        log "  PARTUUID OK : $ACTUAL_PARTUUID"
    fi
else
    log "  AVERTISSEMENT : pas de root=PARTUUID= dans cmdline.txt — non modifié"
fi

sync
umount "${MOUNT_POINT}-boot"
rmdir  "${MOUNT_POINT}-boot"

# ============================================================
# Montage, téléchargement des paquets et configuration 1er boot
# ============================================================
log "Montage de la partition root…"
mkdir -p "$MOUNT_POINT"
mount "$ROOT_PART" "$MOUNT_POINT"

# ---- Téléchargement des paquets sur l'hôte ----
log "Téléchargement des paquets hors ligne (exécuté sur cet hôte)…"
download_packages_offline "$MOUNT_POINT"

# ---- Script uci-defaults : installation locale au 1er boot ----
log "Injection du script d'installation au 1er boot…"
mkdir -p "${MOUNT_POINT}/etc/uci-defaults"

# Ce script s'exécute une seule fois au premier démarrage.
# OpenWrt le supprime automatiquement s'il retourne 0.
cat > "${MOUNT_POINT}/etc/uci-defaults/99-install-extra-packages" <<'UCISCRIPT'
#!/bin/sh
PKG_DIR="/root/packages"
LOG="/var/log/openwrt-extra-packages.log"

logger -t extra-pkgs "Installation des paquets hors ligne depuis $PKG_DIR…"

if [ ! -d "$PKG_DIR" ] || [ -z "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then
    logger -t extra-pkgs "ERREUR : répertoire $PKG_DIR vide ou absent."
    exit 1
fi

apk add --allow-untrusted --no-network "$PKG_DIR"/*.apk >> "$LOG" 2>&1 && \
    logger -t extra-pkgs "Installation terminée avec succès." || \
    logger -t extra-pkgs "Installation terminée avec des erreurs (voir $LOG)."

exit 0
UCISCRIPT

chmod +x "${MOUNT_POINT}/etc/uci-defaults/99-install-extra-packages"

umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
sync

# ============================================================
# Résumé
# ============================================================
echo ""
log "======================================================"
log " Installation terminée avec succès"
log "======================================================"
log " Périphérique : $DEVICE"
log " Boot (p1)    : ${BOOT_PART}  (FAT32, inchangée)"
log " Root (p2)    : ${ROOT_PART}  (ext4, ${ROOT_SIZE_GB} Go)"
log " Espace libre : ~$(( DEVICE_SIZE_GB - ROOT_SIZE_GB )) Go non alloués"
log ""
log " Paquets pré-chargés sur la carte SD (/root/packages/) :"
log "   $EXTRA_PACKAGES"
log " Ils seront installés automatiquement au premier démarrage"
log " sans connexion internet."
log ""
log " Journal d'installation : /var/log/openwrt-extra-packages.log"
log "======================================================"
