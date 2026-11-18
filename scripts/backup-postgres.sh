#!/usr/bin/env bash
# ===================================================================
# Sauvegarde quotidienne de toutes les bases de postgres-shared
# Lancée par systemd/postgres-backup.timer (02:00, heure du VPS)
#
# - un fichier pg_dump (format custom, compressé) par base
# - les rôles et droits (pg_dumpall --globals-only)
# - conservation : RETENTION_DAYS jours (14 par défaut)
#
# Aucune donnée n'est lue ni écrite en dehors de BACKUP_ROOT.
# Aucun mot de passe : on passe par le socket local du conteneur.
# ===================================================================
set -euo pipefail
umask 077

CONTAINER="${CONTAINER:-postgres-shared}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/backups/postgres}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
DAY="$(date +%F)"
TARGET="$BACKUP_ROOT/$DAY"

log() { echo "[backup-postgres] $*"; }

mkdir -p "$TARGET"

# Bases à sauvegarder : toutes sauf les modèles et la base « postgres »
DATABASES=$(docker exec "$CONTAINER" sh -c \
  'psql -U "$POSTGRES_USER" -d postgres -Atc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> '"'"'postgres'"'"' ORDER BY datname"')

if [ -z "$DATABASES" ]; then
  log "ERREUR : aucune base trouvée"
  exit 1
fi

for DB in $DATABASES; do
  FILE="$TARGET/$DB.dump"
  docker exec "$CONTAINER" sh -c 'pg_dump -U "$POSTGRES_USER" -Fc -d "$1"' _ "$DB" > "$FILE"
  if [ ! -s "$FILE" ]; then
    log "ERREUR : sauvegarde vide pour $DB"
    exit 1
  fi
  # Vérifie que l'archive est lisible (liste son contenu)
  docker exec -i "$CONTAINER" pg_restore --list > /dev/null < "$FILE"
  log "OK $DB ($(du -h "$FILE" | cut -f1))"
done

docker exec "$CONTAINER" sh -c 'pg_dumpall -U "$POSTGRES_USER" --globals-only' > "$TARGET/globals.sql"
log "OK rôles et droits (globals.sql)"

# Rotation : supprime les dossiers de plus de RETENTION_DAYS jours
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -print -exec rm -rf {} +

log "Terminé : $TARGET"
