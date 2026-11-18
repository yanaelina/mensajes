"""Ruta WebSocket `enviarMensaje`.

Mensaje esperado del cliente:
    {"action": "enviarMensaje", "chatId": "...", "texto": "Hola"}

1. Verifica que el remitente pertenece al chat.
2. Guarda el mensaje en la cuenta 3 (DynamoDB).
3. Lo pone en la cola SQS para que la Lambda `entregar` lo reparta.
"""
import json
import os

import boto3

from cliente_datos import llamar

sqs = boto3.client("sqs")
ws = boto3.client("apigatewaymanagementapi", endpoint_url=os.environ["WS_ENDPOINT"])
COLA = os.environ["COLA_ENTREGA_URL"]


def _avisar(connection_id, datos):
    ws.post_to_connection(ConnectionId=connection_id, Data=json.dumps(datos).encode())


def handler(event, _context):
    ctx = event["requestContext"]
    user_id = ctx["authorizer"]["userId"]
    cuerpo = json.loads(event.get("body") or "{}")
    chat_id = cuerpo.get("chatId")
    texto = (cuerpo.get("texto") or "").strip()

    if not chat_id or not texto:
        _avisar(ctx["connectionId"], {"tipo": "error", "error": "chatId y texto son obligatorios"})
        return {"statusCode": 400}

    if user_id not in llamar("GET", f"/chats/{chat_id}/participantes"):
        _avisar(ctx["connectionId"], {"tipo": "error", "error": "no perteneces a este chat"})
        return {"statusCode": 403}

    mensaje = llamar("POST", f"/chats/{chat_id}/mensajes", {"remitenteId": user_id, "texto": texto})
    sqs.send_message(QueueUrl=COLA, MessageBody=json.dumps(mensaje))
    return {"statusCode": 200}
