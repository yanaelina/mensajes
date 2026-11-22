#!/usr/bin/env bash
# Herramienta para ver funcionando la cola SQS de entrega y su DLQ (cuenta 2).
#
#   bash scripts/sqs_dlq.sh demo            # recorrido completo: normales + veneno → DLQ (≈4 min)
#   bash scripts/sqs_dlq.sh vigilar         # estado de las dos colas en vivo (Ctrl+C para salir)
#   bash scripts/sqs_dlq.sh normal [N]      # N mensajes que se entregan bien (default 5)
#   bash scripts/sqs_dlq.sh veneno [N]      # N mensajes que fallan siempre → acaban en la DLQ (default 3)
#   bash scripts/sqs_dlq.sh ver-dlq         # muestra lo que hay en la DLQ (sin borrarlo)
#   bash scripts/sqs_dlq.sh logs            # sigue los logs de la Lambda "entregar" (éxitos y fallos)
#   bash scripts/sqs_dlq.sh reprocesar      # devuelve los mensajes de la DLQ a la cola (redrive)
#   bash scripts/sqs_dlq.sh vaciar-dlq      # borra todo lo que hay en la DLQ (pide confirmación)
#
# Cómo funciona la demo (ver terraform/modules/mensajeria/main.tf):
#   cola "entrega": visibility_timeout = 60 s, maxReceiveCount = 3 → DLQ "entrega-dlq"
#   - "normal": {"tipo":"demoSqs","para":[]} → entregar lo procesa sin destinatarios y SQS lo borra.
#     No toca usuarios ni chats reales.
#   - "veneno": mensaje sin chatId → entregar falla (KeyError) y lo reporta en batchItemFailures.
#     El mensaje vuelve a estar visible a los 60 s; tras 3 recepciones fallidas SQS lo mueve a la DLQ.
#   Al llegar a la DLQ se disparan las alarmas "dlq-con-mensajes" y "errores-aplicacion" (→ Telegram).
#
# Variables opcionales: PERFIL_MENSAJERIA (cuenta-mensajeria), REGION (us-east-1), PREFIJO (mensajeria)
set -euo pipefail

PERFIL="${PERFIL_MENSAJERIA:-cuenta-mensajeria}"
REGION="${REGION:-us-east-1}"
PREFIJO="${PREFIJO:-mensajeria}"
AWS=(aws --profile "$PERFIL" --region "$REGION")

B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'

case "${1:-}" in
  demo | vigilar | normal | veneno | ver-dlq | logs | reprocesar | vaciar-dlq) ;;
  *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

cola_url() { "${AWS[@]}" sqs get-queue-url --queue-name "$1" --query QueueUrl --output text; }

COLA="$(cola_url "${PREFIJO}-entrega")" || { echo "No encuentro la cola. ¿Credenciales del lab vigentes (perfil $PERFIL)?" >&2; exit 1; }
DLQ="$(cola_url "${PREFIJO}-entrega-dlq")"

# Imprime "disponibles en_vuelo" de una cola.
contar() {
  "${AWS[@]}" sqs get-queue-attributes --queue-url "$1" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query 'Attributes.[ApproximateNumberOfMessages, ApproximateNumberOfMessagesNotVisible]' --output text
}

barra() { local n=$1 c=$2 s=""; [ "$n" -gt 30 ] && n=30; while [ "$n" -gt 0 ]; do s="${s}■"; n=$((n - 1)); done; printf "%s%-30s%s" "$c" "$s" "$N"; }

enviar() {  # enviar <tipo> <cantidad>
  local tipo=$1 total=$2 i cuerpo ahora
  ahora="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for ((i = 1; i <= total; i++)); do
    if [ "$tipo" = normal ]; then
      cuerpo="{\"tipo\":\"demoSqs\",\"chatId\":\"demo-sqs\",\"para\":[],\"n\":$i,\"creado\":\"$ahora\"}"
    else
      cuerpo="{\"demo\":\"veneno\",\"n\":$i,\"creado\":\"$ahora\",\"nota\":\"sin chatId: entregar falla a proposito\"}"
    fi
    "${AWS[@]}" sqs send-message --queue-url "$COLA" --message-body "$cuerpo" \
      --message-attributes "correlacion={DataType=String,StringValue=demo-sqs-$tipo-$i}" >/dev/null
  done
  if [ "$tipo" = normal ]; then
    echo "${G}✔ $total mensajes normales enviados${N} ${D}(se entregan y se borran en segundos)${N}"
  else
    echo "${R}✔ $total mensajes veneno enviados${N} ${D}(fallarán 3 veces, cada ~60 s, y pasarán a la DLQ en ~3-4 min)${N}"
  fi
}

vigilar() {  # vigilar [esperar_dlq] [max_segundos]
  local esperar=${1:-0} max=${2:-0} inicio fila=0 c_d c_v d_d d_v t
  inicio=$(date +%s)
  echo "${D}Disponibles = esperando a que la Lambda los lea · En vuelo = la Lambda los tiene (o esperan reintento, 60 s)${N}"
  while true; do
    if [ $((fila % 15)) -eq 0 ]; then
      printf "\n${B}%-8s │ %-11s %-9s │ %-11s │ %s${N}\n" "Hora" "Cola: disp." "en vuelo" "DLQ" ""
    fi
    read -r c_d c_v <<<"$(contar "$COLA")"
    read -r d_d d_v <<<"$(contar "$DLQ")"
    t=$(( $(date +%s) - inicio ))
    printf "%-8s │ ${Y}%-11s${N} %-9s │ ${R}%-11s${N} │ " "$(date +%H:%M:%S)" "$c_d" "$c_v" "$d_d"
    barra "$d_d" "$R"; echo
    fila=$((fila + 1))
    if [ "$esperar" -gt 0 ] && [ "$d_d" -ge "$esperar" ] && [ "$c_d" -eq 0 ] && [ "$c_v" -eq 0 ]; then
      echo; echo "${G}✔ Los $esperar mensajes veneno llegaron a la DLQ en ${t} s y la cola principal quedó vacía.${N}"
      return 0
    fi
    if [ "$max" -gt 0 ] && [ "$t" -ge "$max" ]; then
      echo "${Y}Se acabó el tiempo de espera (${max} s).${N}"; return 0
    fi
    sleep 5
  done
}

ver_dlq() {
  local salida
  salida="$("${AWS[@]}" sqs receive-message --queue-url "$DLQ" --max-number-of-messages 10 \
    --visibility-timeout 0 --attribute-names All \
    --query 'Messages[].{Recepciones: Attributes.ApproximateReceiveCount, Cuerpo: Body}' --output table)"
  if [ -z "$salida" ]; then
    echo "La DLQ está vacía."
  else
    echo "$salida"
    echo "${D}(Muestra hasta 10. Recepciones = veces que se intentó entregar; quedan en la DLQ 14 días)${N}"
  fi
}

case "${1:-}" in
  demo)
    echo "${B}Demo SQS + DLQ${N}  cola: ${PREFIJO}-entrega  ·  DLQ: ${PREFIJO}-entrega-dlq"
    read -r antes _ <<<"$(contar "$DLQ")"
    enviar normal 5
    enviar veneno 3
    vigilar $((antes + 3)) 420
    echo; echo "${B}Contenido de la DLQ:${N}"; ver_dlq
    echo
    echo "Siguiente:"
    echo "  · Revisa Telegram/panel: alarmas ${PREFIJO}-mensajeria-dlq-con-mensajes y -errores-aplicacion"
    echo "  · bash scripts/sqs_dlq.sh reprocesar   # los devuelve a la cola (volverán a fallar: son veneno)"
    echo "  · bash scripts/sqs_dlq.sh vaciar-dlq   # limpia la DLQ"
    ;;
  vigilar) vigilar ;;
  normal) enviar normal "${2:-5}" ;;
  veneno) enviar veneno "${2:-3}" ;;
  ver-dlq) ver_dlq ;;
  logs)
    echo "${D}Logs de ${PREFIJO}-entregar (Ctrl+C para salir)${N}"
    "${AWS[@]}" logs tail "/aws/lambda/${PREFIJO}-entregar" --follow --since 10m --format short \
      --filter-pattern '{ $.evento = "entrega_completada" || $.evento = "entrega_fallida" }'
    ;;
  reprocesar)
    dlq_arn="$("${AWS[@]}" sqs get-queue-attributes --queue-url "$DLQ" --attribute-names QueueArn --query Attributes.QueueArn --output text)"
    "${AWS[@]}" sqs start-message-move-task --source-arn "$dlq_arn" >/dev/null
    echo "${G}✔ Redrive iniciado: los mensajes de la DLQ vuelven a ${PREFIJO}-entrega.${N}"
    echo "${D}Mira el movimiento con: bash scripts/sqs_dlq.sh vigilar${N}"
    ;;
  vaciar-dlq)
    read -r d_d _ <<<"$(contar "$DLQ")"
    read -r -p "Se borrarán ~${d_d} mensajes de la DLQ de forma permanente. ¿Continuar? (s/N) " ok
    if [ "$ok" = s ] || [ "$ok" = S ]; then
      "${AWS[@]}" sqs purge-queue --queue-url "$DLQ"
      echo "${G}✔ DLQ vaciada${N} ${D}(SQS puede tardar hasta 60 s en reflejarlo)${N}"
    else
      echo "Cancelado."
    fi
    ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
