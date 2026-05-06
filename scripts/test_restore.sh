#!/bin/bash
# ============================================================================
# test_restore.sh — Restaura el último backup en una DB temporal y verifica
# que tenga datos esperados. Corre todos los domingos via cron.
# Si falla, Healthchecks.io alerta al equipo.
# ============================================================================
set -euo pipefail

cd /opt/ml-traductores
set -a
. ./.env
. ./.env.infra
set +a

echo "[$(date -Iseconds)] Iniciando test_restore"

# 1. Obtener la key del backup más reciente en S3.
LATEST=$(aws s3 ls "s3://${S3_BACKUPS_BUCKET}/postgres/" --recursive \
  | sort | tail -1 | awk '{print $4}')

if [ -z "$LATEST" ]; then
  echo "ERROR: No hay backups en S3"
  if [ -n "${HC_RESTORE_UUID:-}" ]; then
    curl -fsS "https://hc-ping.com/${HC_RESTORE_UUID}/fail" -d "No hay backups en S3"
  fi
  exit 1
fi

echo "Probando restore de: $LATEST"

# 2. Crear DB temporal (drop si quedó de un test previo).
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U "$PG_USER" -d postgres \
      -c "DROP DATABASE IF EXISTS restore_test;" \
      -c "CREATE DATABASE restore_test OWNER $PG_USER;"

# 3. Restaurar el dump en la DB temporal.
aws s3 cp "s3://${S3_BACKUPS_BUCKET}/${LATEST}" - \
  | gunzip \
  | docker compose -f docker-compose.prod.yml exec -T postgres \
      psql -U "$PG_USER" restore_test > /dev/null

# 4. Sanity check: ¿la tabla clientes tiene filas?
COUNT=$(docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U "$PG_USER" -d restore_test -tA \
      -c "SELECT COUNT(*) FROM clientes;" | tr -d '[:space:]')

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
  echo "ERROR: restore_test got $COUNT clientes (esperado ≥1)"
  if [ -n "${HC_RESTORE_UUID:-}" ]; then
    curl -fsS "https://hc-ping.com/${HC_RESTORE_UUID}/fail" \
         -d "restore_test got $COUNT clientes"
  fi
  exit 1
fi

# 5. Limpiar.
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U "$PG_USER" -d postgres \
      -c "DROP DATABASE restore_test;"

# 6. Notificar éxito.
if [ -n "${HC_RESTORE_UUID:-}" ]; then
  curl -fsS "https://hc-ping.com/${HC_RESTORE_UUID}" > /dev/null
fi
echo "[$(date -Iseconds)] Test restore OK ($LATEST, $COUNT clientes)"
