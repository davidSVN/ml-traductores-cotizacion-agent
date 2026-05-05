# RFC: Migración a AWS — ML Traductores Agent

**Estado:** Propuesta para revisión del equipo
**Autor:** Equipo ML Traductores
**Fecha:** 2026-05-05
**Tiempo estimado de lectura:** 30–45 min

---

## Cómo leer este documento

- **Si quieres entender solo la decisión:** lee §1 (resumen) y §5 (arquitectura). 5 min.
- **Si vas a revisar la propuesta antes de aprobarla:** lee §1 a §6 + §11 (riesgos) + §13 (preguntas abiertas). 15 min.
- **Si te toca implementar / operar:** lee todo, prestando atención a §7 (Terraform), §9 (logging), §10 (backups) y §12 (plan de migración).
- **Si no entiendes algún término técnico:** consulta el **Apéndice A: Glosario** al final.

Todos los bloques de código están comentados línea a línea para que sean revisables sin ejecutarlos. Si una decisión no te queda clara, abre un comentario sobre la sección — no asumas.

---

## Índice

1. [Resumen ejecutivo](#1-resumen-ejecutivo)
2. [Contexto y motivación](#2-contexto-y-motivación)
3. [Objetivos y no-objetivos](#3-objetivos-y-no-objetivos)
4. [Arquitectura propuesta](#4-arquitectura-propuesta)
5. [Inventario de recursos AWS](#5-inventario-de-recursos-aws)
6. [Estructura del Terraform](#6-estructura-del-terraform)
7. [CI/CD con GitHub Actions](#7-cicd-con-github-actions)
8. [Logging y observabilidad](#8-logging-y-observabilidad)
9. [Backups y disaster recovery](#9-backups-y-disaster-recovery)
10. [Operaciones recurrentes](#10-operaciones-recurrentes)
11. [Riesgos y mitigaciones](#11-riesgos-y-mitigaciones)
12. [Plan de migración paso a paso](#12-plan-de-migración-paso-a-paso)
13. [Preguntas abiertas](#13-preguntas-abiertas)
14. [Resumen de entregables](#14-resumen-de-entregables)
15. [Aprobación](#15-aprobación)

**Apéndice A:** [Glosario](#apéndice-a-glosario)
**Apéndice B:** [Comandos rápidos del operador](#apéndice-b-comandos-rápidos-del-operador)

---

## 1. Resumen ejecutivo

Migrar el backend (FastAPI + LangGraph + Postgres) desde Railway a una arquitectura **monolítica en AWS EC2** dentro de la capa gratuita, con backups automatizados de Postgres a S3, observabilidad vía CloudWatch + LangSmith, y despliegue continuo con GitHub Actions + Terraform. El frontend permanece en Cloudflare Pages (gratis).

| Métrica | Valor objetivo |
|---|---|
| Costo año 1 | **$0** (free tier AWS) |
| Costo año 2+ | **~$10/mes** (solo EC2 + EBS) |
| RPO (cuánta data podemos perder) | **6 horas** |
| RTO (cuánto tarda recuperarse) | **15–30 min** |
| Esfuerzo total de migración | **3 días + semana de monitoreo** |

---

## 2. Contexto y motivación

### 2.1 Estado actual

- Backend Python/FastAPI desplegado en **Railway** (`railway.toml` + `Dockerfile`).
- LangGraph corre **embebido como librería** dentro del proceso FastAPI (ver §4.2).
- Postgres en **AWS RDS**, gestionado externamente fuera de Railway.
- Frontend Next.js en **Cloudflare Pages** (`*.ml-traductores-dashboard.pages.dev`).
- LangSmith activo para tracing del agente (free tier, 5k traces/mes).
- Meta WhatsApp Cloud API conectada vía webhook público de Railway.

### 2.2 Por qué migrar

- **Costo:** Railway no tiene capa gratuita real para servicios always-on. El gasto crece linealmente con el tiempo en línea.
- **Control:** queremos manejar nosotros backups, retención y políticas de seguridad de la DB.
- **Consolidación:** todo en una sola cuenta cloud (AWS) facilita facturación, permisos y auditoría.
- **Aprendizaje y portabilidad:** dejar la infraestructura como código (Terraform) versionada en el repo nos permite recrearla en minutos.

### 2.3 Por qué NO usar las opciones más "cloud-native"

| Opción | Por qué no |
|---|---|
| **ECS Fargate** | No entra en free tier (~$15–25/mes mínimo). Configuración de VPC/ALB/IAM es excesiva para un solo servicio. |
| **EKS (Kubernetes)** | Solo el control plane cuesta $73/mes. Overkill absoluto para nuestro tráfico. |
| **App Runner** | No tiene free tier (~$25–50/mes mínimo). |
| **Lambda + API Gateway** | Cold starts de 2–3s degradan la UX del webhook de WhatsApp. Más piezas que mantener. |
| **RDS dedicado** | Después del año 1, cuesta ~$15/mes adicionales. Postgres en docker da el mismo servicio para nuestro volumen, con backups manuales bien hechos. |

---

## 3. Objetivos y no-objetivos

### 3.1 Objetivos

1. **Costo cero durante el año 1**, máximo $15/mes a partir del año 2.
2. **Despliegue por `git push`** sin tocar AWS manualmente después del setup inicial.
3. **Backups automatizados** que sobrevivan a la pérdida total de la EC2.
4. **Notificación inmediata** ante errores de aplicación o caídas del servicio.
5. **Recuperación documentada** ante desastre, ejecutable por cualquier miembro del equipo en <30 min.
6. **Infraestructura como código** (Terraform) versionada y revisable por PR.

### 3.2 No-objetivos

- Alta disponibilidad multi-AZ.
- Escalado automático.
- RPO menor a 6 horas (la pérdida tolerable es de medio turno laboral de cotizaciones).
- Failover automático.
- Compliance (PCI, HIPAA, etc.).
- **Usar LangGraph Platform / Cloud.** La app ya corre LangGraph como librería embebida en FastAPI (`src/agent/graph.py`), con `AsyncPostgresSaver` apuntando a nuestro propio Postgres. El servicio hosted de LangChain se descarta por costo y porque añade dependencia externa sin beneficio para nuestro volumen.

---

## 4. Arquitectura propuesta

### 4.1 Diagrama

```
                                      Internet
                                          │
                          ┌───────────────┼─────────────────┐
                          │               │                 │
                          ▼               ▼                 ▼
                  ┌────────────┐  ┌──────────────┐  ┌────────────────┐
                  │  WhatsApp  │  │   Cloudflare │  │  Operadores    │
                  │   (Meta)   │  │  Pages (UI)  │  │  (uptime, etc) │
                  └─────┬──────┘  └──────┬───────┘  └────────────────┘
                        │                │
                        │ HTTPS webhook  │ HTTPS API
                        │                │
                        └───────┬────────┘
                                │
                                ▼
                  ┌────────────────────────────┐
                  │  Cloudflare DNS            │
                  │  api.midominio.com         │
                  └────────────┬───────────────┘
                               │
                               ▼
   ┌────────────────────────────────────────────────────────┐
   │  AWS region us-east-1                                  │
   │  ┌──────────────────────────────────────────────────┐  │
   │  │  EC2 t4g.micro (Amazon Linux 2023, ARM)          │  │
   │  │  ┌─────────────────────────────────────────────┐ │  │
   │  │  │  Caddy (HTTPS termination, Let's Encrypt)   │ │  │
   │  │  └────────────────┬────────────────────────────┘ │  │
   │  │  ┌────────────────▼────────────────────────────┐ │  │
   │  │  │  docker-compose:                            │ │  │
   │  │  │   - app (FastAPI uvicorn:8000 + LangGraph)  │ │  │
   │  │  │   - postgres (16, datos en /mnt/pgdata)     │ │  │
   │  │  │   - caddy                                   │ │  │
   │  │  │   - cloudwatch-agent (logs/metrics)         │ │  │
   │  │  └─────────────────────────────────────────────┘ │  │
   │  │                                                  │  │
   │  │  EBS root (8 GB)         EBS data (10 GB)       │  │
   │  │  /                       /mnt/pgdata             │  │
   │  └──────┬───────────────────────────┬──────────────┘  │
   │         │                           │                 │
   │         │ (logs)                    │ (cron pg_dump)  │
   │         ▼                           ▼                 │
   │  ┌──────────────┐         ┌────────────────────┐      │
   │  │ CloudWatch   │         │ S3 (versionado +   │      │
   │  │ Logs +       │         │ lifecycle 30d)     │      │
   │  │ Metrics +    │         │ ml-traductores-bk  │      │
   │  │ Alarms       │         └────────────────────┘      │
   │  └──────┬───────┘                                     │
   │         │                                             │
   │         ▼                                             │
   │  ┌──────────────┐                                     │
   │  │ SNS topic    │───▶ email/SMS al equipo             │
   │  └──────────────┘                                     │
   │                                                       │
   │  ┌──────────────┐                                     │
   │  │ ECR (imagen  │                                     │
   │  │ docker app)  │                                     │
   │  └──────────────┘                                     │
   │                                                       │
   │  ┌──────────────┐                                     │
   │  │ AWS Backup   │───▶ EBS snapshots diarios (7d)      │
   │  └──────────────┘                                     │
   └───────────────────────────────────────────────────────┘
                               │
                               ▼
                       ┌──────────────┐
                       │  LangSmith   │ (tracing del agente)
                       └──────────────┘
                       ┌──────────────┐
                       │ Healthchecks │ (deadman switch backups)
                       │     .io      │
                       └──────────────┘
```

### 4.2 Cómo corre LangGraph en esta arquitectura

LangGraph **NO se despliega como servicio aparte**. Es una librería Python que vive dentro del proceso FastAPI:

```python
# src/main.py (estado actual, no cambia con la migración)
async with build_graph(settings.database_url) as graph:
    app.state.graph = graph
```

El grafo se compila al arrancar uvicorn, mantiene un pool de conexiones a Postgres, y los checkpoints se persisten en las tablas `checkpoints`, `checkpoint_blobs`, `checkpoint_writes` y `checkpoint_migrations` que el `AsyncPostgresSaver` crea automáticamente.

**Implicación operativa:** los backups de Postgres incluyen todo el estado de las conversaciones, así que al restaurar un backup recuperamos también las conversaciones que estaban en curso (con un RPO de 6h).

### 4.3 Decisiones de diseño clave

| Decisión | Justificación |
|---|---|
| `t4g.micro` (Graviton ARM) | Free tier 750h/mes año 1. Después ~$6.13/mes. ARM es 20% más barato que x86 a igual capacidad. |
| EBS de datos separado del root | Permite recrear la EC2 sin perder la DB. Re-attach en 30 segundos. |
| Postgres en docker (no RDS) | Postgres oficial 16 en container con volumen montado. RDS añade $13–15/mes después del año 1. |
| Caddy como reverse proxy | HTTPS automático con Let's Encrypt sin configurar nada. Más simple que nginx + certbot. |
| Imagen en ECR | 500 MB free permanente. GitHub Actions pushea, EC2 pullea con un IAM role (sin credenciales hardcodeadas). |
| CloudWatch Agent | Streamea logs de Docker → CloudWatch. Métricas custom de la app (CPU, memoria, disco). |
| Cloudflare DNS | Ya está usándose para el frontend. Mantener un solo proveedor de DNS reduce complejidad. |
| SSM en vez de SSH | Acceso remoto vía AWS Systems Manager. No hay puerto 22 abierto, no hay claves SSH que rotar. |

---

## 5. Inventario de recursos AWS

| Recurso | Tipo | Free tier | Costo año 2+ |
|---|---|---|---|
| EC2 instance | `t4g.micro` | 750h/mes × 12 meses | ~$6.13/mes |
| EBS root | gp3, 8 GB | 30 GB total free | ~$0.64/mes |
| EBS data | gp3, 10 GB | (incluido en los 30 GB) | ~$0.80/mes |
| EBS snapshots (AWS Backup) | 7 días retención | hasta 1 GB free | ~$0.50/mes |
| S3 bucket backups | Standard, ~1 GB | 5 GB free permanente | ~$0 |
| ECR repository | privado, ~500 MB | 500 MB free permanente | ~$0 |
| CloudWatch Logs | 1 GB/mes ingesta | 5 GB free permanente | ~$0 |
| CloudWatch Alarms | 5 alarmas | 10 free permanente | ~$0 |
| SNS topic | email | 1000 emails/mes free | ~$0 |
| IP elástica | 1 (siempre asociada) | gratis si está asociada | ~$0 |
| Data transfer out | < 100 GB/mes | 100 GB free permanente | ~$0 |
| Secrets Manager | 4 secrets (opcional) | 30 días free, luego $0.40/secret | ~$1.60/mes (opcional) |
| Route 53 (si lo usamos) | 1 hosted zone | no free | ~$0.50/mes |
| **Total estimado** | | **$0** año 1 | **~$8–10/mes** año 2+ |

> **Nota:** para esta etapa optamos por **NO usar AWS Secrets Manager**. Los secrets viven en `/opt/ml-traductores/.env` en la EC2, gestionados manualmente vía SSM. Ahorra ~$1.60/mes y simplifica el deploy. Si el equipo crece y necesitamos rotación automática, migrar a Secrets Manager son ~30 min de trabajo.

---

## 6. Estructura del Terraform

Todo el código de infraestructura vive bajo `infra/terraform/`. La estructura de archivos:

```
infra/
├── terraform/
│   ├── main.tf              # Provider AWS + backend remoto del state
│   ├── variables.tf         # Inputs configurables (region, dominio, etc.)
│   ├── outputs.tf           # Valores que exportamos para CI/CD
│   ├── network.tf           # VPC default + security group de la EC2
│   ├── ec2.tf               # Instance + EBS data + IAM role + Elastic IP
│   ├── s3.tf                # Bucket de backups con versionado + lifecycle
│   ├── ecr.tf               # Repositorio Docker para la imagen de la app
│   ├── monitoring.tf        # Log group + alarmas + SNS topic + budget
│   ├── backup.tf            # AWS Backup vault + plan diario para EBS
│   ├── github_oidc.tf       # Rol IAM que GitHub Actions asume (sin secrets)
│   └── user_data.sh         # Script de bootstrap que corre al primer boot
└── README.md                # Cómo aplicar y operar Terraform
```

> Cada archivo a continuación está comentado línea a línea. La convención: `#` comentarios en español explicando **qué** y **por qué**. Si una línea no tiene comentario, su nombre o valor es autoexplicativo.

### 6.1 `main.tf`

Configura el provider AWS y guarda el state de Terraform en un bucket S3 compartido (no en la máquina del desarrollador). Esto permite que cualquier miembro del equipo aplique cambios sin pisarse con otro.

```hcl
terraform {
  # Versión mínima de Terraform. Fijar evita romper la infra si alguien
  # corre una versión muy vieja o muy nueva.
  required_version = ">= 1.6"

  # Versionado del provider AWS. ~> 5.0 = cualquier 5.x, no 6.x.
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }

  # Backend remoto: el archivo terraform.tfstate (que contiene IDs y, peor,
  # secretos) se guarda cifrado en S3 en lugar de en el filesystem local.
  # DynamoDB hace de "lock" para que dos personas no apliquen cambios a la vez.
  #
  # IMPORTANTE: este bucket y la tabla DynamoDB se crean MANUALMENTE una vez
  # antes del primer `terraform init`. No se gestionan con Terraform porque
  # serían un huevo-y-gallina (Terraform necesita el bucket para guardar
  # state, pero no puede crear el bucket sin tener state).
  backend "s3" {
    bucket         = "ml-traductores-tfstate"      # bucket pre-creado
    key            = "infra/terraform.tfstate"     # path del state dentro del bucket
    region         = "us-east-1"
    dynamodb_table = "ml-traductores-tflock"       # tabla pre-creada para locking
    encrypt        = true                          # cifra el state at rest
  }
}

provider "aws" {
  region = var.region

  # Tags que se aplican a TODOS los recursos de AWS automáticamente.
  # Ayuda a filtrar costos en Cost Explorer y a saber qué recurso pertenece a qué.
  default_tags {
    tags = {
      Project   = "ml-traductores-agent"
      ManagedBy = "terraform"
      Env       = "prod"
    }
  }
}
```

### 6.2 `variables.tf`

Inputs que el operador define al aplicar Terraform. Los valores reales viven en un archivo `terraform.tfvars` (no commiteado) o en variables de entorno `TF_VAR_*`.

```hcl
# Región AWS donde se crea todo. us-east-1 es la más barata y con más servicios.
# Latencia desde Bogotá: ~80ms (irrelevante para nuestro uso async).
variable "region" {
  type        = string
  description = "Región AWS donde se desplegará la infraestructura"
  default     = "us-east-1"
}

# Tipo de instancia EC2. t4g.micro: 2 vCPU ARM + 1 GB RAM. Free tier 750h/mes año 1.
# Si en el futuro necesitamos más memoria, cambiar a t4g.small (2 GB) son ~$13/mes.
variable "instance_type" {
  type        = string
  description = "Tipo de instancia EC2"
  default     = "t4g.micro"
}

# Nombre del key pair de EC2 que se usa para acceso SSH de emergencia.
# El key pair se crea ANTES de aplicar Terraform en la consola AWS.
# En operación normal usamos SSM Session Manager, no SSH.
variable "ssh_key_name" {
  type        = string
  description = "Nombre del key pair en EC2 (creado fuera de Terraform)"
}

# CIDR desde el cual permitimos SSH. Formato: 1.2.3.4/32 (tu IP pública).
# Si pones 0.0.0.0/0 abres SSH a todo internet — NO LO HAGAS.
# Para emergencias podemos abrirlo temporalmente y cerrarlo de nuevo.
variable "ssh_allowed_cidr" {
  type        = string
  description = "CIDR permitido para SSH (ej: tu IP/32)"
}

# Lista de emails que reciben las alertas de SNS (errores, CPU alta, etc.).
# Cada email recibe un correo de confirmación al aplicar; hay que aceptarlo.
variable "alert_emails" {
  type        = list(string)
  description = "Emails que reciben alertas de SNS"
}

# Dominio que apuntará a la EC2 (ej: api.mltraductores.co).
# Caddy genera el cert HTTPS automáticamente para este dominio.
# El registro DNS se crea en Cloudflare manualmente apuntando a la Elastic IP.
variable "domain_name" {
  type        = string
  description = "Dominio HTTPS de la API (ej: api.mltraductores.co)"
}

# URL del repo GitHub (formato owner/repo). Usado por github_oidc.tf
# para limitar qué repo puede asumir el rol de deploy.
variable "github_repo" {
  type        = string
  description = "Repo GitHub que puede desplegar (formato: owner/repo)"
}
```

### 6.3 `outputs.tf`

Valores que Terraform imprime al final de `apply`. Los usamos para configurar GitHub Secrets y el DNS de Cloudflare.

```hcl
# IP pública estática de la EC2. Esta es la que apuntamos en Cloudflare DNS.
# La IP elástica NO cambia ni siquiera si destruimos y recreamos la instancia
# (mientras no destruyamos la `aws_eip` misma).
output "elastic_ip" {
  description = "IP pública estática para apuntar el DNS"
  value       = aws_eip.app.public_ip
}

# ID de la instancia EC2. Lo usamos en GitHub Actions para mandar comandos
# vía SSM (`aws ssm send-command --instance-ids ...`).
output "ec2_instance_id" {
  description = "ID de la EC2 (usado por GitHub Actions con SSM)"
  value       = aws_instance.app.id
}

# URL del repositorio ECR. La imagen se publica como
# <ecr_url>:<git-sha> y <ecr_url>:latest.
output "ecr_repository_url" {
  description = "URL completa del repo ECR"
  value       = aws_ecr_repository.app.repository_url
}

# ARN del rol IAM que GitHub Actions asume vía OIDC.
# Va al secret AWS_DEPLOY_ROLE_ARN en GitHub.
output "github_actions_role_arn" {
  description = "Rol IAM que GitHub Actions asume para deploy"
  value       = aws_iam_role.github_actions.arn
}

# Nombre del bucket de backups. Va al .env de la EC2 como S3_BACKUPS_BUCKET.
output "backups_bucket" {
  description = "Bucket S3 para backups de Postgres"
  value       = aws_s3_bucket.backups.bucket
}
```

### 6.4 `network.tf`

Usamos la VPC default de la cuenta (sin crear una propia) para mantener la infra mínima. El único recurso de red que creamos es el security group de la EC2.

```hcl
# Referencia a la VPC default de la cuenta. AWS la crea automáticamente
# en cada cuenta nueva. No la modificamos, solo la usamos.
data "aws_vpc" "default" {
  default = true
}

# Subnets de la VPC default (una por AZ). Tomaremos la primera.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security group = firewall stateful asociado a la EC2.
# Define qué tráfico de entrada/salida está permitido.
resource "aws_security_group" "app" {
  name        = "ml-traductores-app"
  description = "App: HTTP/HTTPS público, SSH desde IP admin, salida libre"
  vpc_id      = data.aws_vpc.default.id

  # Puerto 80: HTTP. Caddy lo usa para el challenge ACME (renovar certificado)
  # y para redirigir todo el tráfico HTTP a HTTPS.
  ingress {
    description = "HTTP (Caddy redirige a HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # accesible desde cualquier IP de internet
  }

  # Puerto 443: HTTPS. Aquí entra el webhook de WhatsApp y la API del dashboard.
  ingress {
    description = "HTTPS (webhook + API)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Puerto 22: SSH. Solo desde la IP del admin (definida en variables).
  # En operación normal NO necesitamos SSH (usamos SSM Session Manager).
  # Mantenemos abierto para emergencias.
  ingress {
    description = "SSH solo desde IP admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  # Tráfico de salida: completamente libre. La EC2 necesita salir a internet
  # para pullear de ECR, llamar a Anthropic/Meta, mandar logs a CloudWatch, etc.
  egress {
    description = "Salida libre"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"     # todos los protocolos
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

### 6.5 `ec2.tf` — el archivo más importante

Define la instancia, su disco de datos separado, el rol IAM con los permisos necesarios y la IP elástica. **Este es el corazón de la infra.**

```hcl
# ------------------------------------------------------------------------------
# AMI (imagen de SO base) que usa la EC2.
# ------------------------------------------------------------------------------
# Buscamos la versión más reciente de Amazon Linux 2023 para arquitectura ARM
# (porque la EC2 es t4g, que es Graviton/ARM).
# `data` en vez de `resource` porque NO la creamos, solo la consultamos.
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]   # solo AMIs oficiales de Amazon
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
}

# ------------------------------------------------------------------------------
# Rol IAM que la EC2 asume al arrancar.
# ------------------------------------------------------------------------------
# Sin este rol, la EC2 no podría pullear imágenes de ECR, escribir backups a S3,
# mandar logs a CloudWatch, etc. AWS inyecta credenciales temporales rotadas
# automáticamente — nunca hay claves de larga duración en disco.
resource "aws_iam_role" "ec2" {
  name = "ml-traductores-ec2"

  # Esto dice "permito a EC2 (el servicio) asumir este rol".
  # Sin esto, ningún recurso podría usarlo.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Permite que SSM (Systems Manager) administre la instancia: Session Manager,
# Run Command, Patch Manager. Es lo que reemplaza al SSH para deploys.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Permite que el CloudWatch Agent envíe métricas y logs.
resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Política inline custom: permisos específicos a S3 (solo nuestro bucket de backups)
# y a ECR (cualquier repo, porque ECR no permite limitar por repo en GetAuthToken).
resource "aws_iam_role_policy" "app" {
  role = aws_iam_role.ec2.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3: subir/leer/listar SOLO el bucket de backups.
      # No tiene acceso a ningún otro bucket de la cuenta.
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*"
        ]
      },
      # ECR: pullear imágenes (necesario para `docker pull`).
      # `GetAuthorizationToken` no acepta limitación por repo (limitación de AWS).
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "*"
      }
    ]
  })
}

# El "instance profile" es el wrapper que conecta el rol IAM con la instancia EC2.
# Por razones históricas son dos cosas distintas en AWS.
resource "aws_iam_instance_profile" "ec2" {
  name = "ml-traductores-ec2"
  role = aws_iam_role.ec2.name
}

# ------------------------------------------------------------------------------
# La instancia EC2 propiamente dicha.
# ------------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # Protección contra terminación accidental por consola/API.
  # Si quieres terminar la instancia, primero hay que poner esto en false con
  # `terraform apply`, luego sí terminarla. Capa extra contra "click sin querer".
  disable_api_termination = true

  # Disco raíz: SO + docker + binarios. NO va aquí Postgres (eso está en EBS aparte).
  # gp3 es la generación más reciente (más barata y rápida que gp2).
  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true   # cifrado at-rest sin costo extra
    delete_on_termination = true   # al terminar la EC2, se borra el disco root
  }

  # `user_data`: script que corre UNA SOLA VEZ al primer boot de la instancia.
  # Aquí se instala Docker, se monta el EBS de datos, se configura el agente
  # de CloudWatch, se programan los crons de backup, etc.
  # Si lo modificas y quieres aplicarlo, hay que destruir y recrear la EC2
  # (Terraform lo detecta como cambio que requiere replace).
  user_data = templatefile("${path.module}/user_data.sh", {
    ecr_registry = aws_ecr_repository.app.repository_url
    s3_backups   = aws_s3_bucket.backups.bucket
    region       = var.region
    domain       = var.domain_name
  })

  # Habilita auto-recovery: si AWS detecta que el hardware subyacente falla,
  # la instancia se reinicia automáticamente en otro hardware.
  # NO incluye reinicio si la app crashea, solo fallos de infra.
  maintenance_options {
    auto_recovery = "default"
  }

  tags = { Name = "ml-traductores-app" }

  # Si la AMI cambia (ej: nueva versión menor de Amazon Linux), NO queremos
  # que Terraform recree la EC2 (perderíamos el EBS root y datos).
  # Para upgrade del SO usamos `dnf update -y` dentro de la EC2.
  lifecycle {
    ignore_changes = [ami]
  }
}

# ------------------------------------------------------------------------------
# Disco EBS separado para Postgres data.
# ------------------------------------------------------------------------------
# Este disco vive INDEPENDIENTE de la EC2. Si destruimos la EC2 sin querer,
# el disco sobrevive y podemos re-attacharlo a una EC2 nueva con la DB intacta.
resource "aws_ebs_volume" "data" {
  # Debe estar en la misma zona de disponibilidad que la EC2.
  availability_zone = aws_instance.app.availability_zone
  size              = 10               # 10 GB. Crece a 20 con expansión online si hace falta.
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "ml-traductores-pgdata" }

  # Protección extra: si Terraform intenta destruirlo, falla.
  # Para borrarlo a propósito, primero quitar este bloque, apply, luego destroy.
  lifecycle {
    prevent_destroy = true
  }
}

# Conecta el volumen EBS con la instancia EC2.
# /dev/sdf es el nombre lógico que AWS expone; Linux lo ve como /dev/nvme1n1.
resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
}

# ------------------------------------------------------------------------------
# IP elástica (IP pública estática).
# ------------------------------------------------------------------------------
# La IP pública asignada por defecto cambia cada vez que la EC2 se detiene.
# Con Elastic IP la IP queda fija — apuntamos Cloudflare DNS a ella y nunca
# tenemos que actualizarlo.
#
# Costo: gratis MIENTRAS esté asociada a una instancia corriendo.
# Si la dejas sin asociar, AWS cobra ~$3.60/mes para desincentivar IPs ociosas.
resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
}
```

### 6.6 `s3.tf` — bucket de backups

```hcl
# Bucket donde se guardan los pg_dump diarios.
resource "aws_s3_bucket" "backups" {
  bucket = "ml-traductores-backups"

  # No permitir borrar el bucket si tiene objetos. Capa extra contra "rm -rf".
  # Para destruir a propósito: primero vaciar el bucket, luego destroy.
  lifecycle {
    prevent_destroy = true
  }
}

# Activa versionado: si alguien sobrescribe o borra un objeto, queda una
# "noncurrent version" recuperable durante 30 días (ver lifecycle).
# Esto nos protege contra ransomware o errores humanos sobre los backups.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Política de retención automática: borra backups después de 30 días.
# Sin esto, los backups se acumularían indefinidamente y eventualmente
# saldríamos del free tier de S3 (5 GB).
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-30d"
    status = "Enabled"

    # Versiones actuales: borrar a los 30 días.
    expiration { days = 30 }

    # Versiones antiguas (sobrescritas/borradas): borrar a los 30 días después
    # de pasar a noncurrent. Total máximo: 60 días retenidas.
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

# Bloquea CUALQUIER intento de hacer el bucket público.
# Capa de defensa contra mis-clicks: aunque alguien pongan una ACL pública,
# AWS la rechaza a nivel del bucket. Backups NUNCA deben ser públicos.
resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Cifrado at-rest con clave gestionada por AWS (gratis, automático).
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
```

### 6.7 `ecr.tf` — repositorio de imágenes Docker

```hcl
resource "aws_ecr_repository" "app" {
  name = "ml-traductores-app"

  # Cifrado at-rest de las imágenes.
  encryption_configuration {
    encryption_type = "AES256"
  }

  # Análisis automático de vulnerabilidades en cada push.
  # Útil para detectar CVEs en las dependencias del Dockerfile.
  image_scanning_configuration {
    scan_on_push = true
  }
}

# Política de retención: mantener solo las últimas 5 imágenes.
# Sin esto, ECR acumula imágenes para siempre y eventualmente cobramos por
# almacenamiento (free tier es 500 MB).
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
```

### 6.8 `monitoring.tf` — alarmas, logs y notificaciones

Este archivo es el que activa las alertas que el equipo recibe por email cuando algo va mal.

```hcl
# ------------------------------------------------------------------------------
# SNS topic = canal de notificaciones.
# ------------------------------------------------------------------------------
# Las alarmas mandan mensajes a este "topic" y SNS los reenvía a todos los
# suscriptores (emails en nuestro caso, podría ser SMS, Slack, Lambda, etc.).
resource "aws_sns_topic" "alerts" {
  name = "ml-traductores-alerts"
}

# Suscribimos cada email de la lista. AWS manda un correo de confirmación;
# hay que clickear el link la primera vez para activar la suscripción.
resource "aws_sns_topic_subscription" "emails" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# ------------------------------------------------------------------------------
# Log group de CloudWatch.
# ------------------------------------------------------------------------------
# Todos los logs de la app y de Postgres aterrizan aquí. CloudWatch Insights
# permite hacer queries SQL-like sobre estos logs.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ml-traductores/app"
  retention_in_days = 30   # 30 días de retención. Free tier cubre 5 GB/mes.
}

# ------------------------------------------------------------------------------
# Métrica derivada de logs: contar líneas con ERROR/CRITICAL/Traceback.
# ------------------------------------------------------------------------------
# CloudWatch escanea los logs en tiempo real. Cuando ve uno de esos patrones,
# incrementa una métrica custom llamada AppErrors. Sobre esa métrica creamos
# una alarma (ver abajo).
resource "aws_cloudwatch_log_metric_filter" "errors" {
  name           = "app-errors"
  log_group_name = aws_cloudwatch_log_group.app.name

  # Sintaxis "?A ?B ?C" = OR. Match si la línea contiene cualquiera.
  pattern = "?ERROR ?CRITICAL ?Traceback"

  metric_transformation {
    name      = "AppErrors"
    namespace = "MLTraductores"
    value     = "1"
  }
}

# ------------------------------------------------------------------------------
# Alarma 1: pico de errores en la app.
# ------------------------------------------------------------------------------
# Si en 5 minutos vemos 5+ líneas de error, mandar alerta.
# Threshold ajustable: si genera demasiados falsos positivos, subir a 10.
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "app-error-spike"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "AppErrors"
  namespace           = "MLTraductores"
  period              = 300       # 5 min en segundos
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "5+ errores en 5 min en la app"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  # Si no llegan datos (logs detenidos), considera "OK". Sin esto las alarmas
  # disparan cada vez que la EC2 se reinicia y tarda en mandar logs.
  treat_missing_data = "notBreaching"
}

# ------------------------------------------------------------------------------
# Alarma 2: CPU sostenida alta.
# ------------------------------------------------------------------------------
# 3 períodos de 5 min con CPU > 80%. Indica probable saturación o ataque.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "ec2-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  dimensions          = { InstanceId = aws_instance.app.id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ------------------------------------------------------------------------------
# Alarma 3: disco casi lleno.
# ------------------------------------------------------------------------------
# Métrica `disk_used_percent` la reporta el CloudWatch Agent (no es nativa de EC2).
# Importante: si Postgres llena su disco, todo deja de funcionar.
resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "ec2-disk-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ------------------------------------------------------------------------------
# Alarma 4: status check failed (la EC2 no responde).
# ------------------------------------------------------------------------------
# AWS pingea la instancia cada minuto. Si falla 2 veces seguidas, alerta.
# Junto con `auto_recovery` en ec2.tf, AWS reinicia la EC2 automáticamente.
resource "aws_cloudwatch_metric_alarm" "instance_status" {
  alarm_name          = "ec2-status-failed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  dimensions          = { InstanceId = aws_instance.app.id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ------------------------------------------------------------------------------
# Alarma 5: presupuesto AWS.
# ------------------------------------------------------------------------------
# Si el gasto del mes supera 80% de $5, alerta. Esto nos protege contra
# explosiones inesperadas (cripto-jacking, log explosion, error de config).
resource "aws_budgets_budget" "monthly" {
  name         = "ml-traductores-monthly"
  budget_type  = "COST"
  limit_amount = "5"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_emails
  }
}

# ------------------------------------------------------------------------------
# Dashboard de CloudWatch.
# ------------------------------------------------------------------------------
# Vista única en la consola AWS para revisar el estado del sistema en 30 segundos.
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "ml-traductores-overview"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0, y = 0, width = 12, height = 6
        properties = {
          metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id]]
          period  = 300
          stat    = "Average"
          region  = var.region
          title   = "CPU EC2"
        }
      },
      {
        type   = "metric"
        x      = 12, y = 0, width = 12, height = 6
        properties = {
          metrics = [["MLTraductores", "AppErrors"]]
          period  = 300
          stat    = "Sum"
          region  = var.region
          title   = "Errores app (últimos 5 min)"
        }
      },
      {
        type   = "metric"
        x      = 0, y = 6, width = 12, height = 6
        properties = {
          metrics = [["CWAgent", "disk_used_percent", "path", "/mnt/pgdata"]]
          period  = 300
          stat    = "Average"
          region  = var.region
          title   = "Uso disco Postgres"
        }
      }
    ]
  })
}
```

### 6.9 `backup.tf` — snapshots automáticos del EBS

`pg_dump` cubre el caso típico (corruption, error humano en DB). Los snapshots EBS cubren el caso "perdimos la instancia entera" — restauran el FS completo en otra EC2.

```hcl
# Vault = bucket lógico donde viven los snapshots.
resource "aws_backup_vault" "ebs" {
  name = "ml-traductores-ebs"
}

# Plan: cuándo hacer snapshots y cuánto retenerlos.
resource "aws_backup_plan" "daily" {
  name = "daily-7d"
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.ebs.name

    # Cron: 07:00 UTC = 02:00 hora Bogotá. Hora de baja actividad.
    schedule = "cron(0 7 ? * * *)"

    lifecycle {
      delete_after = 7   # 7 días de retención
    }
  }
}

# Rol IAM que AWS Backup usa para acceder a los volúmenes EBS.
# Usamos la política managed que AWS provee (no inventamos permisos).
resource "aws_iam_role" "backup" {
  name = "ml-traductores-backup"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# Selección: qué recursos cubre el plan. Solo el EBS de datos.
# El root no lo backupeamos porque se reconstruye con Terraform + user_data + deploy.
resource "aws_backup_selection" "ebs" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "ebs-data"
  plan_id      = aws_backup_plan.daily.id
  resources    = [aws_ebs_volume.data.arn]
}
```

### 6.10 `github_oidc.tf` — GitHub Actions sin secrets de AWS

OIDC permite que GitHub Actions asuma roles IAM **sin necesidad de credenciales hardcodeadas**. La autenticación se basa en el JWT firmado por GitHub. Más seguro que `AWS_ACCESS_KEY_ID` en GitHub Secrets.

```hcl
# Provider OIDC: registra a GitHub como emisor de tokens en el que confiamos.
# Solo se hace una vez por cuenta AWS.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]   # huella conocida de GitHub
}

# Rol que GitHub Actions asume al desplegar.
resource "aws_iam_role" "github_actions" {
  name = "ml-traductores-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        # SOLO permite asumir el rol desde nuestro repo, rama master.
        # Si alguien forkea el repo, no puede usarlo. Si intenta desde otra rama, tampoco.
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/master"
        }
      }
    }]
  })
}

# Permisos del rol: pushear a ECR + mandar comandos via SSM a la EC2.
# Nada más. NO tiene acceso a S3, EC2 (excepto SSM), Cloudwatch, etc.
resource "aws_iam_role_policy" "github_deploy" {
  role = aws_iam_role.github_actions.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ECR: login + push de la imagen.
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      # SSM: mandar el comando de deploy a NUESTRA instancia específica.
      # `Resource` limita a esta sola EC2 — no puede mandar comandos a otras.
      {
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = [
          aws_instance.app.arn,
          "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation"]
        Resource = "*"
      }
    ]
  })
}
```

### 6.11 `user_data.sh` — bootstrap de la EC2 al primer boot

Script que corre **una sola vez** cuando la EC2 arranca por primera vez. Instala todo lo necesario y deja el sistema listo para recibir el primer deploy. Si lo modificas, hay que destruir y recrear la EC2 para que se aplique.

```bash
#!/bin/bash
# ============================================================================
# Bootstrap de la EC2 ml-traductores-app
# Corre AUTOMÁTICAMENTE al primer boot. Idempotente para los pasos que se pueden
# re-ejecutar; el resto solo aplica una vez.
# ============================================================================

# -e: corta si algún comando falla
# -u: corta si se usa una variable no definida
# -x: imprime cada comando antes de ejecutarlo (útil para debug en /var/log/cloud-init-output.log)
# -o pipefail: si un pipe falla, todo el pipeline falla
set -euxo pipefail

# ----------------------------------------------------------------------------
# 1. Actualizar el SO
# ----------------------------------------------------------------------------
# Aplica todos los patches de seguridad disponibles.
dnf update -y

# ----------------------------------------------------------------------------
# 2. Instalar paquetes base
# ----------------------------------------------------------------------------
# - docker: runtime de containers
# - amazon-cloudwatch-agent: ya viene preinstalado en algunas AMIs, lo aseguramos
# - awscli viene preinstalado en Amazon Linux 2023
dnf install -y docker amazon-cloudwatch-agent

# Habilita docker como servicio (arranque automático en cada boot)
systemctl enable --now docker

# Permite al usuario ec2-user usar docker sin sudo
usermod -aG docker ec2-user

# ----------------------------------------------------------------------------
# 3. Instalar docker compose (plugin v2)
# ----------------------------------------------------------------------------
# Compose v2 NO viene en los repos de Amazon Linux 2023. Lo descargamos del repo oficial.
# `aarch64` porque la EC2 es ARM (t4g).
DOCKER_CONFIG=$${DOCKER_CONFIG:-/usr/local/lib/docker}
mkdir -p $DOCKER_CONFIG/cli-plugins
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64 \
  -o $DOCKER_CONFIG/cli-plugins/docker-compose
chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose

# ----------------------------------------------------------------------------
# 4. Esperar y formatear el EBS de datos
# ----------------------------------------------------------------------------
# El volumen EBS attached aparece como /dev/nvme1n1 (en t4g con NVMe).
# Esperamos a que esté disponible (el attachment puede tardar unos segundos
# después de que la EC2 arranque).
DEVICE=/dev/nvme1n1
echo "Esperando dispositivo $DEVICE..."
while [ ! -e $DEVICE ]; do sleep 2; done

# Si NO tiene filesystem, formatear con XFS (mejor para Postgres que ext4 por
# soporte de extents grandes).
# `blkid` retorna 0 si hay filesystem, 2 si no.
if ! blkid $DEVICE; then
  echo "Formateando $DEVICE con XFS (primera vez)"
  mkfs.xfs $DEVICE
fi

# Crear punto de montaje y montarlo
mkdir -p /mnt/pgdata

# Agregar a /etc/fstab para que se monte automáticamente en cada boot.
# `nofail`: si el disco no está, el boot continúa (mejor que quedarse colgado).
echo "$DEVICE /mnt/pgdata xfs defaults,nofail 0 2" >> /etc/fstab
mount /mnt/pgdata

# El uid 999 es el del usuario `postgres` dentro de la imagen oficial de Docker Hub.
# Si no le damos ownership, Postgres no puede escribir en el volumen.
chown -R 999:999 /mnt/pgdata

# ----------------------------------------------------------------------------
# 5. Configurar el agente de CloudWatch
# ----------------------------------------------------------------------------
# Define qué métricas y logs reportar.
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<EOF
{
  "metrics": {
    "metrics_collected": {
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/", "/mnt/pgdata"],
        "drop_device": true
      },
      "mem": {
        "measurement": ["used_percent"]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/docker-compose.log",
            "log_group_name": "/ml-traductores/app",
            "log_stream_name": "{instance_id}/host"
          },
          {
            "file_path": "/var/log/backup.log",
            "log_group_name": "/ml-traductores/app",
            "log_stream_name": "{instance_id}/backup"
          }
        ]
      }
    }
  }
}
EOF
systemctl enable --now amazon-cloudwatch-agent

# ----------------------------------------------------------------------------
# 6. Crear directorio de la aplicación y descargar archivos del repo
# ----------------------------------------------------------------------------
# `docker-compose.prod.yml`, `Caddyfile` y los scripts viven en el repo.
# Aquí los traemos del último commit de master via raw.githubusercontent.com.
# El primer deploy real luego sobrescribe estos via SSM si es necesario.
mkdir -p /opt/ml-traductores
cd /opt/ml-traductores

REPO_RAW="https://raw.githubusercontent.com/${var.github_repo}/master"
curl -sSL $REPO_RAW/docker-compose.prod.yml -o docker-compose.prod.yml || true
curl -sSL $REPO_RAW/Caddyfile -o Caddyfile || true

mkdir -p scripts
for s in backup.sh restore.sh test_restore.sh deploy.sh; do
  curl -sSL $REPO_RAW/scripts/$s -o scripts/$s || true
  chmod +x scripts/$s || true
done

# ----------------------------------------------------------------------------
# 7. Configurar variables de entorno básicas
# ----------------------------------------------------------------------------
# El .env REAL (con secrets de Anthropic, Meta, etc.) se crea manualmente
# después del primer boot via SSM. Aquí solo dejamos los valores de infra.
cat > /opt/ml-traductores/.env.infra <<EOF
ECR_REGISTRY=${ecr_registry}
S3_BACKUPS_BUCKET=${s3_backups}
AWS_REGION=${region}
DOMAIN_NAME=${domain}
EOF

# ----------------------------------------------------------------------------
# 8. Crons de backup y test de restore
# ----------------------------------------------------------------------------
# pg_dump cada 6 horas. Logs van a /var/log/backup.log (que CloudWatch monitorea).
# Test de restore semanal los domingos 05:00 UTC = 00:00 BOG.
cat > /etc/cron.d/ml-traductores <<EOF
# m h dom mon dow user command
0 */6 * * * root /opt/ml-traductores/scripts/backup.sh >> /var/log/backup.log 2>&1
0 5 * * 0  root /opt/ml-traductores/scripts/test_restore.sh >> /var/log/restore_test.log 2>&1
EOF

echo "============================================"
echo "Bootstrap completo. Falta:"
echo "  1. Crear /opt/ml-traductores/.env via SSM con los secrets reales"
echo "  2. Hacer el primer deploy desde GitHub Actions"
echo "============================================"
```

---

## 7. CI/CD con GitHub Actions

Dos workflows: uno para tests en cada PR, otro para deploy en cada merge a `master`.

### 7.1 `.github/workflows/test.yml` — Tests + lint en cada PR

```yaml
name: test

# Trigger: corre en cada PR y en cada push a master.
# Lo segundo es por si alguien pushea directo a master (saltándose PR).
on:
  pull_request: {}
  push:
    branches: [master]

jobs:
  test:
    runs-on: ubuntu-latest

    # Levanta un Postgres temporal para que los tests de integración tengan DB.
    # Vive solo durante este job; se descarta al terminar.
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: test
          POSTGRES_DB: test
        ports:
          - 5432:5432
        # Healthcheck: el job no continúa hasta que Postgres responda.
        # Sin esto, los tests fallan al intentar conectar antes de que esté listo.
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 5s
          --health-retries 5

    steps:
      # Trae el código del repo al runner.
      - uses: actions/checkout@v4

      # Setup Python 3.12. Cache de pip para que las instalaciones sean rápidas.
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
          cache: pip

      # Instala el proyecto + dependencias de desarrollo (pytest, ruff, etc.).
      - name: Instalar dependencias
        run: pip install -e ".[dev]"

      # Linter: chequea formato y errores comunes.
      - name: Lint
        run: ruff check src/

      # Tests. -q = quiet, --tb=short para tracebacks compactos en logs.
      - name: Tests
        run: pytest -q --tb=short
        env:
          DATABASE_URL: postgresql+asyncpg://postgres:test@localhost:5432/test
```

### 7.2 `.github/workflows/deploy.yml` — Build + push + deploy en cada merge

Este workflow se dispara automáticamente cuando se mergea a `master`. Construye la imagen Docker, la sube a ECR, y le dice a la EC2 que se actualice.

```yaml
name: deploy

on:
  push:
    branches: [master]

# Permisos del workflow (no del repo).
# `id-token: write` es CRÍTICO: permite a GitHub firmar el JWT de OIDC que
# usamos para autenticar contra AWS sin tener credenciales en GitHub Secrets.
permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      # 1. Trae el código.
      - uses: actions/checkout@v4

      # 2. Configura Docker Buildx para builds multi-arquitectura.
      # Necesario porque el runner es x86 pero la EC2 es ARM (t4g).
      - name: Setup Buildx
        uses: docker/setup-buildx-action@v3

      # 3. Asume el rol IAM de AWS via OIDC.
      # NO usa AWS_ACCESS_KEY/SECRET_KEY: la autenticación es via JWT de GitHub.
      # Las credenciales temporales duran solo lo que tarda este job.
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
          aws-region: us-east-1

      # 4. Login a ECR. Genera un token corto (12h) usando el rol asumido arriba.
      - name: Login a ECR
        id: ecr
        uses: aws-actions/amazon-ecr-login@v2

      # 5. Build de la imagen Docker para arquitectura ARM (linux/arm64).
      # Tag con el SHA del commit (immutable) y `latest` (mutable).
      # Se sube a ECR directamente con `--push` (no necesitamos guardar local).
      - name: Build & push imagen
        run: |
          IMAGE=${{ steps.ecr.outputs.registry }}/ml-traductores-app
          docker buildx build \
            --platform linux/arm64 \
            -t $IMAGE:${{ github.sha }} \
            -t $IMAGE:latest \
            --push \
            .

      # 6. Le dice a la EC2 que pullee la nueva imagen y reinicie el container.
      # AWS SSM Run Command ejecuta el script remotamente sin necesidad de SSH.
      # El comando real (deploy.sh) ya está en /opt/ml-traductores/scripts/.
      - name: Trigger deploy via SSM
        run: |
          COMMAND_ID=$(aws ssm send-command \
            --instance-ids ${{ secrets.EC2_INSTANCE_ID }} \
            --document-name AWS-RunShellScript \
            --parameters 'commands=["cd /opt/ml-traductores && ./scripts/deploy.sh"]' \
            --output text \
            --query "Command.CommandId")

          # Espera hasta que el comando termine (max 5 min).
          # Si falla, este step falla y nos enteramos en GitHub.
          aws ssm wait command-executed \
            --command-id $COMMAND_ID \
            --instance-id ${{ secrets.EC2_INSTANCE_ID }}

          # Imprime el output del comando (logs del deploy.sh) en GitHub Actions.
          aws ssm get-command-invocation \
            --command-id $COMMAND_ID \
            --instance-id ${{ secrets.EC2_INSTANCE_ID }} \
            --query "StandardOutputContent" \
            --output text
```

### 7.3 Secrets requeridos en GitHub

Estos son los **únicos** secrets que viven en GitHub. NO hay AWS access keys, NO hay claves de Anthropic, NO hay nada sensible más allá de identificadores.

| Secret | Origen | Sensibilidad |
|---|---|---|
| `AWS_DEPLOY_ROLE_ARN` | Output de Terraform `github_actions_role_arn` | Baja (es solo un ARN, no permite acceso por sí solo) |
| `EC2_INSTANCE_ID` | Output de Terraform `ec2_instance_id` | Nula (es público en la consola AWS) |

Las credenciales sensibles (Anthropic, Meta WhatsApp, Postgres password) viven en `/opt/ml-traductores/.env` **solo en la EC2**, gestionadas via SSM.

---

## 8. Logging y observabilidad

### 8.1 Capas de observabilidad

| Capa | Herramienta | Free | Para qué |
|---|---|---|---|
| Aplicación (LLM) | LangSmith | sí (5k traces/mes) | Conversaciones, tool calls, latencia del agente, costo de tokens |
| Aplicación (HTTP/Python) | CloudWatch Logs | sí (5 GB/mes) | Logs de FastAPI, errores Python, requests |
| Sistema (EC2) | CloudWatch Metrics | sí | CPU, memoria, disco, network |
| Disponibilidad externa | UptimeRobot / BetterStack | sí (50 monitores) | Pings al `/health`, alerta si cae |
| Backups | Healthchecks.io | sí (20 checks) | Deadman switch: alerta si no llega ping en 25h |

### 8.2 Flujo de logs

```
FastAPI (logging.getLogger) ──▶ stdout
                                    │
                                    ▼
                         Docker (awslogs driver)
                                    │
                                    ▼
                  Log Group: /ml-traductores/app
                                    │
                  ┌─────────────────┼──────────────────┐
                  ▼                 ▼                  ▼
         Log Insights query  Metric filter "ERROR"  Retención 30d
                                    │
                                    ▼
                         Custom metric: AppErrors
                                    │
                                    ▼
                         Alarm: 5+ en 5min
                                    │
                                    ▼
                          SNS → email del equipo
```

### 8.3 `docker-compose.prod.yml` — compose para producción

Versión específica para la EC2. Diferencias con el `docker-compose.yml` de desarrollo: sin volúmenes de código (la imagen viene de ECR), Caddy como reverse proxy, drivers de logging hacia CloudWatch.

```yaml
services:
  # --------------------------------------------------------------------------
  # App: FastAPI + LangGraph + uvicorn
  # --------------------------------------------------------------------------
  app:
    # La imagen se pullea de ECR. ${ECR_REGISTRY} viene del .env.
    # Tag `latest` se actualiza con cada deploy desde GitHub Actions.
    image: ${ECR_REGISTRY}/ml-traductores-app:latest

    # Si crashea, docker la reinicia automáticamente (a menos que sea por
    # `docker stop` explícito).
    restart: unless-stopped

    # Variables de entorno: secrets viven en .env, no en este yaml.
    env_file: .env

    # No arranca hasta que postgres responda al healthcheck.
    depends_on:
      postgres:
        condition: service_healthy

    # Logs: driver awslogs los manda directo a CloudWatch sin pasar por archivos.
    # `awslogs-create-group: true` crea el log group si no existe (idempotente).
    logging:
      driver: awslogs
      options:
        awslogs-region: us-east-1
        awslogs-group: /ml-traductores/app
        awslogs-stream: app
        awslogs-create-group: "true"

  # --------------------------------------------------------------------------
  # Postgres 16 oficial
  # --------------------------------------------------------------------------
  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${PG_USER}
      POSTGRES_PASSWORD: ${PG_PASSWORD}
      POSTGRES_DB: ${PG_DB}

    # CRÍTICO: el data directory NO está en el container, sino en el EBS de
    # datos montado en /mnt/pgdata. Sobrevive a destrucción del container.
    volumes:
      - /mnt/pgdata:/var/lib/postgresql/data

    # Healthcheck para que `app` espere antes de arrancar.
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${PG_USER}"]
      interval: 10s
      retries: 5

    logging:
      driver: awslogs
      options:
        awslogs-region: us-east-1
        awslogs-group: /ml-traductores/app
        awslogs-stream: postgres

  # --------------------------------------------------------------------------
  # Caddy: reverse proxy con HTTPS automático
  # --------------------------------------------------------------------------
  # Caddy genera el certificado de Let's Encrypt automáticamente la primera
  # vez, y lo renueva cada 60 días sin intervención.
  # Necesita el dominio apuntado al IP de la EC2 ANTES de arrancar.
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped

    # Puertos públicos. Solo Caddy escucha en 80/443; la app está oculta dentro
    # de la red de docker.
    ports:
      - "80:80"
      - "443:443"

    volumes:
      # Config del reverse proxy (read-only).
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      # Persistencia de certs y challenges. Si pierdes esto, Caddy re-genera
      # el cert al próximo arranque (límite Let's Encrypt: 5/semana por dominio).
      - caddy-data:/data
      - caddy-config:/config

    depends_on: [app]

    logging:
      driver: awslogs
      options:
        awslogs-region: us-east-1
        awslogs-group: /ml-traductores/app
        awslogs-stream: caddy

volumes:
  caddy-data:
  caddy-config:
```

### 8.4 `Caddyfile` — config del reverse proxy

```
# El dominio se sustituye en deploy.sh con `envsubst`.
# Caddy:
# - Genera y renueva el cert HTTPS de Let's Encrypt automáticamente.
# - Redirige HTTP → HTTPS automáticamente.
# - Manda la request al container `app:8000`.
{$DOMAIN_NAME} {
    # Reverse proxy a FastAPI. `app` es el nombre del servicio en compose.
    reverse_proxy app:8000

    # Compresión gzip (reduce ancho de banda en respuestas JSON).
    encode gzip

    # Esconde el header `Server: Caddy` para no revelar el stack.
    header -Server

    # Logs de acceso a stdout (los recoge el awslogs driver).
    log {
        output stdout
        format json
    }
}
```

### 8.5 Queries útiles de CloudWatch Logs Insights

Guardar estas queries en la consola para inspecciones rápidas:

```sql
-- Errores recientes (lo primero que mira el operador en una incidencia)
fields @timestamp, @message
| filter @message like /ERROR|CRITICAL|Traceback/
| sort @timestamp desc
| limit 50

-- Volumen de webhooks por minuto (carga real)
filter @message like /POST \/webhook\/whatsapp/
| stats count() by bin(1m)

-- Latencia del agente (asumiendo logueamos `agent_response_ms=N`)
filter @message like /agent_response_ms/
| parse @message "agent_response_ms=*" as ms
| stats avg(ms), max(ms), pct(ms, 95) by bin(5m)

-- Top errores agrupados por mensaje
filter @message like /ERROR/
| stats count() as freq by @message
| sort freq desc
| limit 20
```

---

## 9. Backups y disaster recovery

### 9.1 Las 3 capas de backup

| Capa | Frecuencia | Almacenamiento | Retención | Sirve para |
|---|---|---|---|---|
| `pg_dump` lógico | Cada 6h | S3 versionado | 30 días | Restaurar a cualquier punto cada 6h. Portátil entre versiones de Postgres. |
| EBS snapshot | Diario 02:00 BOG | AWS Backup vault | 7 días | Recrear EC2 entera con el FS de Postgres tal cual. |
| Test de restore | Semanal (domingo) | (verifica) | — | Confirma que los backups son restorables (sin esto, los backups son solo un deseo). |

> **Nota sobre estado del agente:** los checkpoints de LangGraph (`AsyncPostgresSaver`) viven en las mismas tablas de Postgres, así que los backups capturan también el estado de las conversaciones en curso. Tras un restore, una conversación puede seguir desde donde estaba (módulo el RPO de 6h).

### 9.2 `scripts/backup.sh` — pg_dump → S3

```bash
#!/bin/bash
# ============================================================================
# backup.sh — pg_dump comprimido subido a S3 + ping a healthchecks.io
# Se ejecuta cada 6h via cron (ver user_data.sh §6.11).
# Salida va a /var/log/backup.log (CloudWatch lo recoge).
# ============================================================================
set -euo pipefail

cd /opt/ml-traductores
# Carga variables: PG_USER, PG_DB, S3_BACKUPS_BUCKET, HC_BACKUP_UUID, etc.
source .env
source .env.infra

# Path en S3 con estructura por fecha: postgres/AÑO/MES/DÍA/HHMMSS.sql.gz
# Esto facilita listar y filtrar backups por rango de fechas.
TS=$(date -u +%Y/%m/%d/%H%M%S)
S3_PATH="s3://${S3_BACKUPS_BUCKET}/postgres/${TS}.sql.gz"

# pg_dump dentro del container -> gzip nivel 9 (máxima compresión, CPU OK)
# -> aws s3 cp con stdin (-) sin escribir a disco intermedio.
# `--expected-size` ayuda a aws-cli a calcular el part size para multipart upload.
docker compose -f docker-compose.prod.yml exec -T postgres \
    pg_dump -U "$PG_USER" "$PG_DB" \
  | gzip -9 \
  | aws s3 cp - "$S3_PATH" \
      --expected-size 100000000 \
      --storage-class STANDARD

# Deadman switch: si esta línea no se ejecuta (porque algo arriba falló por
# `set -e`), healthchecks.io NO recibe el ping y nos manda email después de 25h.
curl -fsS --retry 3 "https://hc-ping.com/${HC_BACKUP_UUID}"

echo "OK $S3_PATH"
```

### 9.3 `scripts/restore.sh` — restaurar un dump específico

```bash
#!/bin/bash
# ============================================================================
# restore.sh — Restaura un dump de S3 sobre la DB actual.
# USO: ./restore.sh postgres/2026/05/05/0600.sql.gz
# ATENCIÓN: destructivo. Renombra la DB actual a <db>_old antes de restaurar
# para no perder data si el restore falla.
# ============================================================================
set -euo pipefail

cd /opt/ml-traductores
source .env
source .env.infra

# Validación: requiere argumento.
KEY="${1:?Uso: ./restore.sh <s3-key> (ej. postgres/2026/05/05/0600.sql.gz)}"

echo "============================================"
echo "Vas a restaurar:"
echo "  Origen: s3://${S3_BACKUPS_BUCKET}/${KEY}"
echo "  Destino DB: ${PG_DB}"
echo "  La DB actual quedará renombrada como ${PG_DB}_old"
echo ""
echo "Ctrl-C en 10 segundos para cancelar..."
echo "============================================"
sleep 10

# 1. Backup defensivo del estado actual (por si el restore corrompe algo).
./scripts/backup.sh

# 2. Renombrar DB actual a <db>_old. Si ya existía un _old previo, lo borra.
#    Hacemos esto en lugar de DROP directo: si el restore falla, podemos volver
#    con un simple ALTER DATABASE.
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U "$PG_USER" -d postgres \
      -c "DROP DATABASE IF EXISTS ${PG_DB}_old;" \
      -c "ALTER DATABASE $PG_DB RENAME TO ${PG_DB}_old;" \
      -c "CREATE DATABASE $PG_DB OWNER $PG_USER;"

# 3. Restaurar el dump. Streaming desde S3 sin disco intermedio.
aws s3 cp "s3://${S3_BACKUPS_BUCKET}/${KEY}" - \
  | gunzip \
  | docker compose -f docker-compose.prod.yml exec -T postgres \
      psql -U "$PG_USER" "$PG_DB"

echo "============================================"
echo "Restore COMPLETO."
echo "La DB anterior quedó como ${PG_DB}_old."
echo "Verifica que la app funcione antes de borrarla con:"
echo "  docker compose exec postgres psql -U $PG_USER -c 'DROP DATABASE ${PG_DB}_old;'"
echo "============================================"
```

### 9.4 `scripts/test_restore.sh` — verificación semanal automática

```bash
#!/bin/bash
# ============================================================================
# test_restore.sh — Restaura el último backup en una DB temporal y verifica
# que tenga datos esperados. Corre todos los domingos via cron.
# Si falla, healthchecks.io alerta al equipo.
# ============================================================================
set -euo pipefail

cd /opt/ml-traductores
source .env
source .env.infra

# 1. Obtener la key del backup más reciente en S3.
LATEST=$(aws s3 ls "s3://${S3_BACKUPS_BUCKET}/postgres/" --recursive \
  | sort | tail -1 | awk '{print $4}')

if [ -z "$LATEST" ]; then
  curl -fsS "https://hc-ping.com/${HC_RESTORE_UUID}/fail" -d "No hay backups en S3"
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
      psql -U "$PG_USER" restore_test

# 4. Sanity check: ¿la tabla clientes tiene filas?
#    -t = solo el valor, -c = command. Trim whitespace con tr.
COUNT=$(docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U "$PG_USER" -d restore_test -tA \
      -c "SELECT COUNT(*) FROM clientes;" | tr -d '[:space:]')

if [ "$COUNT" -lt 1 ]; then
  curl -fsS "https://hc-ping.com/${HC_RESTORE_UUID}/fail" \
       -d "restore_test got 0 clientes"
  exit 1
fi

# 5. Limpiar.
docker compose -f docker-compose.prod.yml exec -T postgres \
    psql -U "$PG_USER" -d postgres \
      -c "DROP DATABASE restore_test;"

# 6. Notificar éxito.
curl -fsS "https://hc-ping.com/${HC_RESTORE_UUID}"
echo "Test restore OK ($LATEST, $COUNT clientes)"
```

### 9.5 `scripts/deploy.sh` — lo que SSM ejecuta tras un push

```bash
#!/bin/bash
# ============================================================================
# deploy.sh — Pullea la nueva imagen de ECR, recrea el container app, y corre
# las migraciones de Alembic.
# Lo invoca AWS SSM desde GitHub Actions (NO se ejecuta manualmente
# en operación normal).
# ============================================================================
set -euxo pipefail

cd /opt/ml-traductores
source .env.infra

# 1. Login a ECR. Las credenciales vienen del IAM role de la EC2 (no hay keys
#    en disco). El token dura 12h, suficiente para el deploy.
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# 2. Pull de la nueva imagen `latest` (que GitHub Actions acaba de pushear).
docker compose -f docker-compose.prod.yml pull app

# 3. Recrear SOLO el container `app`.
#    `up -d --no-deps app` evita reiniciar postgres y caddy.
docker compose -f docker-compose.prod.yml up -d --no-deps app

# 4. Limpiar imágenes antiguas. Sin esto, el disco se llena con tags viejos.
docker image prune -f

# 5. Migraciones de Alembic.
#    Ejecutadas DESPUÉS de pullear la imagen para garantizar que el binario
#    de alembic es el de la nueva versión.
#    Si una migración falla, el deploy falla y nos enteramos en GitHub Actions.
docker compose -f docker-compose.prod.yml exec -T app alembic upgrade head

# 6. Healthcheck post-deploy. Si /health no responde 200 en 30s, fallar.
for i in {1..30}; do
  if curl -fsS http://localhost:8000/health > /dev/null; then
    echo "Healthcheck OK"
    exit 0
  fi
  sleep 1
done

echo "Healthcheck FAILED tras 30s"
exit 1
```

### 9.6 Runbook: la EC2 está caída

```
Si la EC2 está caída TOTAL:

1. Revisa CloudWatch alarms para ver qué disparó.

2. Caso A: instance está "stopped" (no terminada):
   a. Consola EC2 → Start instance.
   b. Espera 1 min. Verifica https://api.midominio.com/health.
   c. Si responde, fin. Investiga la causa del stop en logs.

3. Caso B: instance terminada pero EBS de datos sobrevive:
   a. cd infra/terraform && terraform apply
      (recrea la EC2 y re-attachea el EBS de datos automáticamente)
   b. Espera ~3 min a que termine user_data.
   c. Vía SSM: aws ssm start-session --target <instance-id>
   d. Restaurar /opt/ml-traductores/.env desde tu password manager.
   e. cd /opt/ml-traductores && ./scripts/deploy.sh
   f. Verifica /health.

4. Caso C: EBS de datos también perdido:
   a. Ejecutar terraform apply (con confirmación de prevent_destroy desactivado).
   b. Repetir 3.b a 3.d.
   c. Listar backups: aws s3 ls s3://ml-traductores-backups/postgres/ --recursive | tail
   d. ./scripts/restore.sh <key-del-último-backup>
   e. ./scripts/deploy.sh
   f. Verifica /health.

5. Caso D: la cuenta AWS entera no responde:
   a. Status: https://health.aws.amazon.com/
   b. Esperar. (No tenemos contingencia multi-cloud por costo.)

ETA: 10 min (caso A), 20 min (caso B), 30 min (caso C).
```

---

## 10. Operaciones recurrentes

| Tarea | Frecuencia | Automatizado | Acción manual |
|---|---|---|---|
| `pg_dump` a S3 | cada 6h | sí (cron) | revisar healthcheck si falla |
| EBS snapshot | diario | sí (AWS Backup) | — |
| Test de restore | semanal (dom 00:00 BOG) | sí (cron) | revisar healthcheck si falla |
| Borrado de backups antiguos | continuo | sí (S3 lifecycle + AWS Backup) | — |
| Patches de SO | mensual | parcial (requiere reboot) | reboot manual o SSM patch baseline |
| Major upgrade Postgres | cada 1–2 años | no | seguir runbook `pg_upgrade` |
| Renovación cert HTTPS | continuo | sí (Caddy + Let's Encrypt) | — |
| Rotación claves SSH | cuando alguien sale del equipo | no | actualizar key pair + re-attach |
| Revisar billing AWS | mensual | sí (alarma de presupuesto $5) | revisar email |
| Revisar dashboard CloudWatch | semanal | — | mirada general 2 min |
| Rotar credenciales (Anthropic, Meta) | cuando se filtren / 6 meses | no | actualizar `.env` vía SSM |
| Limpieza de imágenes ECR | continuo | sí (lifecycle) | — |
| Recordatorio fin free tier | mes 11 (2027-04) | no (calendario) | revisar costos esperados |

---

## 11. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| EC2 se cae por hardware AWS | Baja | Alto (downtime hasta restart) | Alarma `StatusCheckFailed` → email. Auto-recovery activado. |
| Postgres llena el disco | Media | Total (todo se cae) | Alarma disk_used_percent > 80%. EBS expandible online a 20/30 GB. |
| `pg_dump` falla silenciosamente | Media | Catastrófico (descubres al querer restaurar) | Healthchecks.io alerta tras 25h sin ping + test_restore semanal. |
| Pérdida total del bucket S3 | Muy baja | Catastrófico | Versionado activado + AWS Backup snapshots en otro vault. |
| Compromiso de la EC2 | Baja | Alto | SSH bloqueado por IP, acceso primario via SSM con IAM. Imagen privada en ECR. Secrets solo en `.env` (nunca en imagen). |
| Costo se dispara (cripto-jacking, log explosion) | Baja | Medio | Budget alarm a $5/mes. CloudWatch retention 30d. ECR lifecycle 5 imágenes. |
| Disrupción de DNS | Baja | Total | Cloudflare DNS, TTL 300s. IP elástica AWS no cambia. |
| El equipo pierde acceso (claves perdidas) | Baja | Medio | SSM en lugar de SSH. Root AWS con MFA + recovery codes guardados offline. |
| Major upgrade Postgres falla | Baja | Alto | Snapshot manual antes de upgrade. Probar en EC2 paralela. |
| Free tier expira sin que nos demos cuenta | Alta (mes 12) | Bajo ($10–15 sorpresa) | Recordatorio en calendario para mes 11. Budget alarm ya alerta. |
| Compromiso del repo GitHub | Baja | Alto (push malicioso → deploy malicioso) | Branch protection en master + reviews requeridos + 2FA obligatorio en GitHub. |

---

## 12. Plan de migración paso a paso

### 12.1 Pre-trabajo (1–2 días, sin downtime)

1. **Comprar/configurar dominio** (si no lo tenemos): `mltraductores.co` o similar. Apuntar `api.mltraductores.co` quedará pendiente del paso 12.2.
2. **Crear cuenta AWS** (si no existe). Activar MFA en root. Crear usuario IAM admin para nosotros, nunca usar root para tareas diarias.
3. **Configurar OIDC entre GitHub y AWS** vía Terraform (`github_oidc.tf`).
4. **Crear bucket de tfstate y tabla DynamoDB** del backend de Terraform (manual, una vez).
5. **`terraform apply`** la infra completa. Verifica que la EC2 arranca y los CloudWatch logs llegan.
6. **Crear cuenta Healthchecks.io**, generar 2 UUIDs (backup + restore_test), guardarlos para el `.env`.
7. **Generar primer build** ejecutando manualmente el workflow `deploy.yml` en una rama de prueba. La imagen queda en ECR.
8. **Vía SSM**, crear `/opt/ml-traductores/.env` con todas las credenciales (Anthropic, Meta, Postgres, S3, Healthchecks UUIDs).
9. **Primer deploy manual** vía SSM. Verifica `/health` por la IP elástica.
10. **Smoke test**: ejecutar `./scripts/backup.sh` y `./scripts/test_restore.sh`. Confirmar que aparece el ping en healthchecks.

### 12.2 Día de la migración (downtime ~10 min)

1. **Snapshot final de la DB de Railway** y subirlo a S3.
2. **Restaurar ese dump en la EC2 nueva**: `./scripts/restore.sh <path>`.
3. **Apuntar `api.mltraductores.co` a la IP elástica de AWS** en Cloudflare DNS (TTL bajo, 60s, configurado horas antes para que propague rápido).
4. **Cambiar la URL del webhook en el panel de Meta WhatsApp** a `https://api.mltraductores.co/webhook/whatsapp`. Verificar challenge.
5. **Mandar mensaje de prueba por WhatsApp** desde un celular del equipo. Confirmar que llega, se procesa, y aparece en CloudWatch Logs.
6. **Apagar el servicio en Railway** (no borrar todavía).
7. **Verificar el frontend** (Cloudflare Pages) consume bien la nueva API. Ajustar `NEXT_PUBLIC_API_URL` si aplica.

### 12.3 Post-migración (semana 1)

- **Día 1:** monitorear errors en CloudWatch + email cada hora.
- **Día 2:** verificar que el primer EBS snapshot del AWS Backup se generó.
- **Día 7:** revisar el primer test de restore semanal. Si todo OK, pausar Railway oficialmente.
- **Día 14:** si todo estable, eliminar el servicio de Railway.

---

## 13. Preguntas abiertas

1. **¿Dominio?** ¿Tenemos uno disponible o lo registramos? Costo: ~$12/año en Cloudflare Registrar (al costo, sin markup).
2. **¿Región AWS?** Recomendación: `us-east-1` (más barata + más servicios). Latencia desde Bogotá: ~80ms, irrelevante para WhatsApp async.
3. **¿Quiénes reciben las alertas SNS?** Necesitamos lista de emails iniciales.
4. **¿Multi-AZ para futuro?** Documentado como upgrade path: si en el futuro el negocio lo justifica, migrar Postgres a RDS Multi-AZ son ~2h de trabajo.
5. **¿Cómo manejamos secrets sensibles?** Propuesta inicial: `.env` en la EC2 (manual via SSM). Alternativa: Secrets Manager (~$1.60/mes, más seguro pero rompe free tier total). Decisión por costo: empezamos con `.env`.
6. **¿Auditar el código antes de migrar?** Razonable correr `bandit` y revisar manejo de errores antes de dejarlo solo en prod.
7. **¿Qué hacemos con el frontend de Cloudflare Pages a futuro?** Mantener allí (gratis). No mover a AWS.

---

## 14. Resumen de entregables

Una vez aprobado este RFC, estos archivos se crean en este repo:

- `infra/terraform/*.tf` — todo el Terraform descrito en §6.
- `infra/terraform/user_data.sh` — bootstrap de la EC2.
- `infra/README.md` — cómo aplicar y operar Terraform.
- `docker-compose.prod.yml` — compose de producción.
- `Caddyfile` — config del reverse proxy.
- `scripts/backup.sh`, `scripts/restore.sh`, `scripts/test_restore.sh`, `scripts/deploy.sh`.
- `.github/workflows/test.yml` y `.github/workflows/deploy.yml`.
- `RUNBOOK.md` — runbook de incidentes (resumen del §9.6 + §10).

**Estimación de esfuerzo:** 2 días para el setup inicial (Terraform + scripts) + 1 día para la migración real con ventana de downtime + 1 semana de monitoreo cercano.

---

## 15. Aprobación

- [ ] Arquitectura aprobada
- [ ] Costo objetivo aceptado
- [ ] RPO/RTO aceptados
- [ ] Lista de `alert_emails` confirmada
- [ ] Dominio decidido
- [ ] Listos para crear el branch `infra/aws-migration`

**Comentarios / preguntas:** abrir issue en GitHub con el tag `rfc:aws-migration`.

---

## Apéndice A: Glosario

Términos técnicos del documento, ordenados alfabéticamente.

| Término | Definición |
|---|---|
| **AMI** (Amazon Machine Image) | Imagen de SO + paquetes que se usa para arrancar una EC2. Equivalente a una "ISO" pero gestionada por AWS. |
| **AWS Backup** | Servicio de AWS para programar snapshots de EBS, RDS, etc., con un plan de retención. |
| **Caddy** | Servidor web/reverse proxy escrito en Go. Característica clave: HTTPS automático con Let's Encrypt sin configurar nada. |
| **CIDR** | Notación de rango de IPs (ej: `10.0.0.0/16`, `192.168.1.5/32`). El número después del `/` indica cuántos bits son fijos. |
| **CloudWatch** | Servicio de observabilidad de AWS: métricas, logs, alarmas y dashboards. |
| **Cron** | Programador de tareas en Linux. Sintaxis: `m h dom mon dow command` (ej: `0 */6 * * *` = cada 6 horas). |
| **DNS A record** | Registro DNS que mapea un dominio a una IP (ej: `api.midominio.com → 54.123.45.67`). |
| **EBS** (Elastic Block Store) | Disco virtual que se attachea a una EC2. Como un SSD externo. Sobrevive a la terminación de la EC2 si se configura así. |
| **EC2** (Elastic Compute Cloud) | Máquina virtual de AWS. La unidad básica de cómputo. |
| **ECR** (Elastic Container Registry) | Servicio de AWS para guardar imágenes Docker privadas (equivalente a Docker Hub privado). |
| **Elastic IP** | IP pública estática que no cambia aunque reinicies la EC2. |
| **Healthcheck** | Endpoint o comando que reporta si un servicio está vivo y sano. Ej: `GET /health → 200 OK`. |
| **IAM** (Identity & Access Management) | Sistema de permisos de AWS. Define quién puede hacer qué sobre qué recurso. |
| **IAM Role** | "Identidad" que un recurso (ej: EC2) puede asumir para obtener credenciales temporales. Reemplaza a tener access keys hardcodeadas. |
| **Lifecycle policy** | Reglas que aplican acciones a recursos basadas en su edad (ej: borrar backups después de 30 días). |
| **OIDC** (OpenID Connect) | Estándar de autenticación. GitHub puede emitir tokens que AWS valida sin compartir credenciales. |
| **RPO** (Recovery Point Objective) | Cuánta data podemos perder en caso de desastre. Ej: RPO 6h = "podemos perder hasta 6h de transacciones". |
| **RTO** (Recovery Time Objective) | Cuánto tarda volver a estar online después de un desastre. Ej: RTO 30min = "máximo 30 min de downtime". |
| **SNS** (Simple Notification Service) | Servicio de AWS para mandar mensajes a múltiples destinatarios (email, SMS, otros servicios). |
| **SSM** (Systems Manager) | Servicio de AWS para gestionar EC2s remotamente sin SSH: ejecutar comandos, abrir sesiones interactivas, aplicar patches. |
| **Security Group** | Firewall stateful asociado a una EC2. Define qué puertos están abiertos y desde qué IPs. |
| **State (Terraform)** | Archivo que Terraform mantiene para saber qué recursos existen y cuáles necesitan crear/modificar/destruir. |
| **Subnet** | Subdivisión de una VPC. Las EC2s viven dentro de subnets. |
| **t4g.micro** | Tipo de instancia EC2: 2 vCPU ARM (Graviton) + 1 GB RAM. La más barata con free tier. |
| **VPC** (Virtual Private Cloud) | Red privada virtual de AWS. Cada cuenta tiene una VPC default por región. |
| **WAL** (Write-Ahead Log) | Mecanismo de Postgres para durabilidad. Pre-condición para point-in-time recovery (no lo tenemos en este setup). |

---

## Apéndice B: Comandos rápidos del operador

Comandos útiles del día a día. Ejecutar desde la EC2 vía SSM Session Manager (no requiere SSH).

```bash
# Abrir sesión interactiva en la EC2 (reemplazar al SSH).
aws ssm start-session --target <instance-id>

# Ver logs en vivo de la app.
docker compose -f /opt/ml-traductores/docker-compose.prod.yml logs -f app

# Reiniciar solo la app sin afectar Postgres ni Caddy.
docker compose -f /opt/ml-traductores/docker-compose.prod.yml restart app

# Hacer un backup manual ya mismo (útil antes de un cambio riesgoso).
/opt/ml-traductores/scripts/backup.sh

# Listar backups disponibles en S3 (últimos 20).
aws s3 ls s3://ml-traductores-backups/postgres/ --recursive | sort | tail -20

# Restaurar un backup específico.
/opt/ml-traductores/scripts/restore.sh postgres/2026/05/05/060000.sql.gz

# Conectarse al Postgres.
docker compose -f /opt/ml-traductores/docker-compose.prod.yml exec postgres \
  psql -U mluser ml_traductores

# Ver uso de disco.
df -h

# Ver uso de memoria.
free -h

# Ver containers corriendo.
docker compose -f /opt/ml-traductores/docker-compose.prod.yml ps

# Aplicar parches del SO (requiere reboot después).
sudo dnf update -y && sudo reboot

# Ver errores recientes en CloudWatch (vía CLI, también disponible en consola).
aws logs filter-log-events \
  --log-group-name /ml-traductores/app \
  --filter-pattern "ERROR" \
  --start-time $(date -d '1 hour ago' +%s)000
```

**Fin del documento.**
