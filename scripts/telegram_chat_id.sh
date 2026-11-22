#!/usr/bin/env bash
# Muestra el chat_id de las conversaciones recientes con tu bot de Telegram.
#   1. Crea el bot con @BotFather (/newbot) y copia el token.
#   2. Escríbele cualquier cosa al bot (o agrégalo a un grupo y escribe en el grupo).
#   3. bash scripts/telegram_chat_id.sh <token>
set -euo pipefail
TOKEN="${1:?Uso: $0 <token_del_bot>}"
curl -fsS "https://api.telegram.org/bot${TOKEN}/getUpdates" | python3 -c '
import json, sys
r = json.load(sys.stdin)
chats = {}
for u in r.get("result", []):
    m = u.get("message") or u.get("channel_post") or u.get("my_chat_member") or {}
    c = m.get("chat")
    if c:
        chats[c["id"]] = c.get("title") or " ".join(filter(None, [c.get("first_name"), c.get("last_name")])) or c.get("username", "")
if not chats:
    sys.exit("No hay mensajes. Escríbele algo al bot y vuelve a ejecutar el script.")
for i, n in chats.items():
    print(f"telegram_chat_id = \"{i}\"   # {n}")
'
