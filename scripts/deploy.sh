#!/bin/bash
# ============================================================================
# deploy.sh — Pullea la nueva imagen de ECR, recrea el container app, y
# verifica con healthcheck. Lo invoca AWS SSM desde GitHub Actions.
# El Dockerfile de la app corre `alembic upgrade head` antes de uvicorn,
# por lo que las migraciones se aplican al arrancar el container nuevo.
# ============================================================================
set -euxo pipefail

cd /opt/ml-traductores
set -a
. ./.env
. ./.env.infra
set +a

# 1. Login a ECR. Credenciales vienen del IAM role de la EC2 (sin keys en disco).
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# 2. Pull de la nueva imagen `latest` (que GitHub Actions acaba de pushear).
docker compose -f docker-compose.prod.yml pull app

# 3. Asegurar que postgres y caddy estén arriba (idempotente).
docker compose -f docker-compose.prod.yml up -d postgres caddy

# 4. Recrear container `app` con la nueva imagen.
#    --no-deps evita reiniciar postgres/caddy que ya están bien.
docker compose -f docker-compose.prod.yml up -d --no-deps --force-recreate app

# 5. Limpiar imágenes antiguas para no llenar el disco.
docker image prune -f

# 6. Healthcheck post-deploy. Si /health no responde 200 en 60s, fallar.
echo "Esperando que /health responda..."
for i in {1..60}; do
  if docker compose -f docker-compose.prod.yml exec -T app \
       curl -fsS http://localhost:8000/health > /dev/null 2>&1; then
    echo "Healthcheck OK tras ${i}s"
    exit 0
  fi
  sleep 1
done

echo "Healthcheck FAILED tras 60s"
docker compose -f docker-compose.prod.yml logs --tail 100 app
exit 1
