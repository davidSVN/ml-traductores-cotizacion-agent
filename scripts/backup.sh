#!/bin/bash
# ============================================================================
# backup.sh — pg_dump comprimido subido a S3 + ping a Healthchecks.io.
# Se ejecuta cada 6h via cron (ver infra/terraform/user_data.sh).
# Salida va a /var/log/backup.log (CloudWatch lo recoge).
# ============================================================================
set -euo pipefail

cd /opt/ml-traductores
# Carga PG_USER, PG_DB, HC_BACKUP_UUID, etc.
set -a
. ./.env
. ./.env.infra
set +a

# Path en S3 con estructura por fecha: postgres/AÑO/MES/DÍA/HHMMSS.sql.gz
TS=$(date -u +%Y/%m/%d/%H%M%S)
S3_PATH="s3://${S3_BACKUPS_BUCKET}/postgres/${TS}.sql.gz"

echo "[$(date -Iseconds)] Iniciando backup → $S3_PATH"

# pg_dump dentro del container → gzip → S3, sin disco intermedio.
docker compose -f docker-compose.prod.yml exec -T postgres \
    pg_dump -U "$PG_USER" "$PG_DB" \
  | gzip -9 \
  | aws s3 cp - "$S3_PATH" \
      --expected-size 100000000 \
      --storage-class STANDARD

# Deadman switch: si esto NO se ejecuta (porque algo arriba falló por set -e),
# Healthchecks.io alerta tras 25h sin ping.
if [ -n "${HC_BACKUP_UUID:-}" ]; then
  curl -fsS --retry 3 "https://hc-ping.com/${HC_BACKUP_UUID}" > /dev/null
fi

echo "[$(date -Iseconds)] Backup OK $S3_PATH"
