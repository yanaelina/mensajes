#!/usr/bin/env bash
# Crea o actualiza un perfil de AWS CLI con las credenciales de UNA cuenta de
# Learner Lab. Ejecútalo 3 veces (una por cuenta) cada vez que inicies el lab,
# porque las credenciales caducan a las ~4 horas.
#
# Uso: ./scripts/configurar_perfiles.sh cuenta-identidad
#      (pega el bloque de "AWS Details > AWS CLI" y termina con una línea vacía)
set -euo pipefail
perfil="${1:?Uso: $0 <nombre-perfil>}"
echo "Pega el bloque [default] de AWS Details de la cuenta '$perfil' y deja una línea vacía:"
bloque=""
while IFS= read -r linea; do
  [[ -z "$linea" ]] && break
  bloque+="$linea"$'\n'
done
valor() { echo "$bloque" | grep -i "^$1" | head -1 | cut -d= -f2- | tr -d ' '; }
aws configure set aws_access_key_id     "$(valor aws_access_key_id)"     --profile "$perfil"
aws configure set aws_secret_access_key "$(valor aws_secret_access_key)" --profile "$perfil"
aws configure set aws_session_token     "$(valor aws_session_token)"     --profile "$perfil"
aws configure set region us-east-1 --profile "$perfil"
echo "Perfil '$perfil' listo. Cuenta:"
aws sts get-caller-identity --profile "$perfil" --query Account --output text
