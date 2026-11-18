#!/usr/bin/env bash
# ===================================================================
# Test de restauration : prouve que la dernière sauvegarde est utilisable
# Usage : sudo /opt/infra/scripts/restore-test.sh [base]   (défaut : db-dinthialma)
#
# Restaure la sauvegarde la plus récente dans une base TEMPORAIRE
# (restore_test), compte les tables, puis supprime la base temporaire.
# Ne touche jamais aux bases réelles.
# ===================================================================
set -euo pipefail

CONTAINER="${CONTAINER:-postgres-shared}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/backups/postgres}"
DB="${1:-db-dinthialma}"
TMP_DB="restore_test"

LATEST=$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -n 1)
FILE="${LATEST}${DB}.dump"
[ -f "$FILE" ] || { echo "Aucune sauvegarde trouvée pour $DB"; exit 1; }

echo "Restauration de $FILE dans la base temporaire $TMP_DB…"
docker exec "$CONTAINER" sh -c 'dropdb -U "$POSTGRES_USER" --if-exists "$1" && createdb -U "$POSTGRES_USER" "$1"' _ "$TMP_DB"
docker exec -i "$CONTAINER" sh -c 'pg_restore -U "$POSTGRES_USER" -d "$1" --no-owner --exit-on-error' _ "$TMP_DB" < "$FILE"

TABLES=$(docker exec "$CONTAINER" sh -c 'psql -U "$POSTGRES_USER" -d "$1" -Atc "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('"'"'pg_catalog'"'"','"'"'information_schema'"'"')"' _ "$TMP_DB")
echo "Tables restaurées : $TABLES"

docker exec "$CONTAINER" sh -c 'dropdb -U "$POSTGRES_USER" "$1"' _ "$TMP_DB"
echo "Base temporaire supprimée. Test réussi."
