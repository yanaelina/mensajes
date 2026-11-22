#!/usr/bin/env bash
# Fuerza la alarma "errores-aplicacion" de cada cuenta a ALARM para comprobar
# la cadena CloudWatch → SNS → Lambda → Telegram. En la siguiente evaluación
# (≈5 min) CloudWatch la devuelve a OK y llega también el aviso "RESUELTA".
#
#   bash scripts/probar_alertas.sh                 # las tres cuentas
#   bash scripts/probar_alertas.sh mensajeria      # solo una
set -euo pipefail
PREFIJO="${PREFIJO:-mensajeria}"
REGION="${REGION:-us-east-1}"

perfil() {
  case "$1" in
    identidad)  echo "${PERFIL_IDENTIDAD:-cuenta-identidad}" ;;
    mensajeria) echo "${PERFIL_MENSAJERIA:-cuenta-mensajeria}" ;;
    datos)      echo "${PERFIL_DATOS:-cuenta-datos}" ;;
    *) echo "Cuenta desconocida: $1 (usa identidad, mensajeria o datos)" >&2; exit 1 ;;
  esac
}

if [ $# -eq 0 ]; then set -- identidad mensajeria datos; fi
for c in "$@"; do
  p="$(perfil "$c")"
  alarma="${PREFIJO}-${c}-errores-aplicacion"
  aws cloudwatch set-alarm-state --profile "$p" --region "$REGION" \
    --alarm-name "$alarma" --state-value ALARM \
    --state-reason "Prueba manual de notificaciones (scripts/probar_alertas.sh)"
  echo "✔ ${alarma} → ALARM (perfil ${p})"
done
echo "Revisa Telegram. Si no llega nada: CloudWatch → Log groups → /aws/lambda/${PREFIJO}-alertas-telegram"
