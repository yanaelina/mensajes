#!/usr/bin/env bash
# Genera una URL pre-firmada para abrir el frontend desde el bucket S3 privado
# de la cuenta 2. Con credenciales de Learner Lab la URL deja de funcionar
# cuando caduca la sesión del lab (~4 h), aunque se pida más tiempo.
#
# Uso: ./scripts/generar_url.sh [segundos]   (por defecto 3600 = 1 h)
set -euo pipefail
cd "$(dirname "$0")/.."
expira="${1:-3600}"
bucket="$(terraform -chdir=terraform output -raw frontend_bucket)"
perfil="${PERFIL_MENSAJERIA:-cuenta-mensajeria}"
aws s3 presign "s3://$bucket/index.html" --expires-in "$expira" --profile "$perfil" --region "${REGION:-us-east-1}"
3