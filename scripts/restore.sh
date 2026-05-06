#!/bin/bash
# ============================================================================
# restore.sh — Restaura un dump de S3 sobre la DB actual.
# USO: ./restore.sh postgres/2026/05/05/060000.sql.gz
# ATENCIÓN: destructivo. Renombra la DB actual a <db>_old antes de restaurar.
# ============================================================================
set -euo pipefail

cd /opt/ml-traductores
set -a
. ./.env
. ./.env.infra
set +a

KEY="${1:?Uso: ./restore.sh <s3-key> (ej. postgres/2026/05/05/060000.sql.gz)}"

echo "============================================"
echo "Vas a restaurar:"
echo "  Origen:     s3://${S3_BACKUPS_BUCKET}/${KEY}"
echo "  Destino DB: ${PG_DB}"
echo "  La DB actual quedará como ${PG_DB}_old"
echo ""
echo "Ctrl-C en 10s para cancelar..."
echo "============================================"
sleep 10

# 1. Backup defensivo del estado actual antes de tocar nada.
echo "[1/4] Backup defensivo..."
./scripts/backup.sh

# 2. Renombrar DB actual a <db>_old. Si existe _old previa, borrarla.
echo "[2/4] Renombrando DB actual a ${PG_DB}_old..."
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U "$PG_USER" -d postgres \
      -c "DROP DATABASE IF EXISTS ${PG_DB}_old;" \
      -c "ALTER DATABASE $PG_DB RENAME TO ${PG_DB}_old;" \
      -c "CREATE DATABASE $PG_DB OWNER $PG_USER;"

# 3. Restaurar el dump (streaming desde S3, sin disco intermedio).
echo "[3/4] Restaurando dump..."
aws s3 cp "s3://${S3_BACKUPS_BUCKET}/${KEY}" - \
  | gunzip \
  | docker compose -f docker-compose.prod.yml exec -T postgres \
      psql -U "$PG_USER" "$PG_DB"

# 4. Restart de la app para que reconecte con la DB nueva.
echo "[4/4] Reiniciando app..."
docker compose -f docker-compose.prod.yml restart app

echo "============================================"
echo "Restore COMPLETO."
echo "La DB anterior quedó como ${PG_DB}_old."
echo "Verifica que la app funcione y luego bórrala con:"
echo "  docker compose -f docker-compose.prod.yml exec postgres \\"
echo "    psql -U $PG_USER -d postgres -c 'DROP DATABASE ${PG_DB}_old;'"
echo "============================================"
