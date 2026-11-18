"""Consumidor de la cola SQS de entrega.

Por cada mensaje busca a los participantes del chat y sus conexiones
WebSocket abiertas, y les empuja el mensaje. Si una conexión ya no existe
(GoneException) la borra. Los usuarios offline verán el mensaje al pedir el
historial (GET /chats/{chatId}/mensajes).
"""
import json
import os

import boto3

from cliente_datos import llamar

ws = boto3.client("apigatewaymanagementapi", endpoint_url=os.environ["WS_ENDPOINT"])


def _entregar(mensaje):
    datos = json.dumps({"tipo": "nuevoMensaje", "mensaje": mensaje}).encode()
    for user_id in llamar("GET", f"/chats/{mensaje['chatId']}/participantes"):
        for connection_id in llamar("GET", f"/usuarios/{user_id}/conexiones"):
            try:
                ws.post_to_connection(ConnectionId=connection_id, Data=datos)
            except ws.exceptions.GoneException:
                llamar("DELETE", f"/conexiones/{connection_id}")


def handler(event, _context):
    fallidos = []
    for record in event["Records"]:
        try:
            _entregar(json.loads(record["body"]))
        except Exception as e:  # noqa: BLE001 - se reintenta solo este mensaje
            print(f"Error entregando {record['messageId']}: {e}")
            fallidos.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": fallidos}
