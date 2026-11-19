#!/usr/bin/env bash
# ===================================================================
# Copie des sauvegardes hors du VPS — installation côté VPS (une seule fois)
#
# Crée l'utilisateur « backup-reader », limité à la LECTURE des sauvegardes
# PostgreSQL par SFTP :
#   - connexion par clé uniquement (clé dédiée, distincte de celle du déploiement) ;
#   - enfermé dans /opt/backups (ChrootDirectory), il n'y voit que /postgres ;
#   - SFTP en lecture seule (internal-sftp -R), sans shell, sans tunnel.
#
# Usage (en root, sur le VPS) :
#   sudo /opt/infra/scripts/installer-lecteur-sauvegardes.sh "ssh-ed25519 AAAA... commentaire"
#
# Le script peut être relancé sans risque (il remplace la clé et réapplique les droits).
# La configuration SSH est validée (sshd -t) avant rechargement ; en cas d'erreur,
# l'ancienne configuration est restaurée et rien n'est rechargé.
# ===================================================================
set -euo pipefail

UTILISATEUR="backup-reader"
GROUPE="backup-readers"
RACINE="/opt/backups"
SAUVEGARDES="$RACINE/postgres"
CLES_DIR="/etc/ssh/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"
DEBUT="# >>> backup-reader (spirit-infra) >>>"
FIN="# <<< backup-reader (spirit-infra) <<<"

log() { echo "[installer-lecteur-sauvegardes] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  log "ERREUR : à lancer en root (sudo)."
  exit 1
fi

CLE="${1:-}"
case "$CLE" in
  ssh-ed25519\ *) ;;
  *)
    log "ERREUR : fournir la clé publique ed25519 entre guillemets (\"ssh-ed25519 AAAA...\")."
    exit 1
    ;;
esac

# ── Groupe et utilisateur (sans mot de passe, sans shell) ─────────────
getent group "$GROUPE" > /dev/null || groupadd --system "$GROUPE"
if ! id "$UTILISATEUR" > /dev/null 2>&1; then
  useradd --system --gid "$GROUPE" --home-dir / --no-create-home \
    --shell /usr/sbin/nologin "$UTILISATEUR"
fi
passwd -l "$UTILISATEUR" > /dev/null

# ── Droits : la racine du chroot doit appartenir à root, sans écriture pour les autres
mkdir -p "$SAUVEGARDES"
chown root:root "$RACINE"
chmod 755 "$RACINE"
chown -R root:"$GROUPE" "$SAUVEGARDES"
find "$SAUVEGARDES" -type d -exec chmod 750 {} +
find "$SAUVEGARDES" -type f -exec chmod 640 {} +

# sshd refuse le chroot si un dossier parent n'appartient pas à root ou est
# modifiable par le groupe ou les autres : on vérifie au lieu de corriger en aveugle
for DOSSIER in / /opt "$RACINE"; do
  PROPRIO=$(stat -c '%U' "$DOSSIER")
  DROITS=$(stat -c '%a' "$DOSSIER")
  if [ "$PROPRIO" != "root" ] || [ $(( 8#$DROITS & 8#022 )) -ne 0 ]; then
    log "ERREUR : $DOSSIER doit appartenir à root sans écriture groupe/autres (actuel : $PROPRIO $DROITS)."
    exit 1
  fi
done

# ── Clé publique, hors du chroot (non visible par l'utilisateur) ──────
mkdir -p "$CLES_DIR"
chmod 755 "$CLES_DIR"
printf 'restrict %s\n' "$CLE" > "$CLES_DIR/$UTILISATEUR"
chown root:root "$CLES_DIR/$UTILISATEUR"
chmod 644 "$CLES_DIR/$UTILISATEUR"

# ── Configuration SSH : bloc ajouté EN FIN de fichier (un bloc Match doit être
#    le dernier, sinon il capture les directives qui le suivent) ─────────
cp "$SSHD_CONFIG" "$SSHD_CONFIG.avant-backup-reader"
sed -i "/^$DEBUT\$/,/^$FIN\$/d" "$SSHD_CONFIG"
cat >> "$SSHD_CONFIG" <<EOF
$DEBUT
Match User $UTILISATEUR
    AuthorizedKeysFile $CLES_DIR/%u
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ChrootDirectory $RACINE
    ForceCommand internal-sftp -R
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
$FIN
EOF

if ! sshd -t; then
  log "ERREUR : configuration SSH invalide, restauration de l'ancienne version."
  cp "$SSHD_CONFIG.avant-backup-reader" "$SSHD_CONFIG"
  exit 1
fi

# Rechargement : les sessions SSH ouvertes ne sont pas coupées
systemctl reload ssh 2> /dev/null || systemctl reload sshd

log "OK : $UTILISATEUR peut lire $SAUVEGARDES (visible comme /postgres en SFTP)."
log "Test depuis le poste de sauvegarde : sftp -i <clé> $UTILISATEUR@<hôte>  puis  ls /postgres"
