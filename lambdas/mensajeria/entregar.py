"""Consumidor de la cola SQS de entrega.

Reparte mensajes nuevos y avisos (lectura, miembros agregados, mensaje borrado).
Por cada mensaje busca a los participantes del chat y sus conexiones
WebSocket abiertas, y les empuja el mensaje. Si una conexión ya no existe
(GoneException) la borra. Los usuarios offline verán el mensaje al pedir el
historial (GET /chats/{chatId}/mensajes).
"""
import json
import os

import boto3

from cliente_datos import llamar
from registro import aviso, contexto, error, info, instrumentado

ws = boto3.client("apigatewaymanagementapi", endpoint_url=os.environ["WS_ENDPOINT"])


def _entregar(mensaje):
    # La cola lleva mensajes nuevos (sin "tipo") y avisos ya armados:
    # {"tipo": "leido" | "miembrosAgregados" | "mensajeBorrado" | "chatEliminado" | ...}.
    # Los avisos de chat eliminado / salida traen "para", porque esos participantes ya no existen.
    para = mensaje.pop("para", None)
    if mensaje.get("tipo"):
        datos = json.dumps(mensaje).encode()
    else:
        datos = json.dumps({"tipo": "nuevoMensaje", "mensaje": mensaje}).encode()
    destinatarios = para if para is not None else llamar("GET", f"/chats/{mensaje['chatId']}/participantes")
    entregas = caducadas = 0
    recibieron = []  # usuarios con al menos una conexión que recibió el mensaje
    for user_id in destinatarios:
        ok = False
        for connection_id in llamar("GET", f"/usuarios/{user_id}/conexiones"):
            if _empujar(connection_id, datos):
                entregas += 1
                ok = True
            else:
                caducadas += 1
        if ok:
            recibieron.append(user_id)
    info("entrega_completada", chat_id=mensaje.get("chatId"), tipo=mensaje.get("tipo") or "nuevoMensaje",
         destinatarios=len(destinatarios), entregas=entregas, conexiones_caducadas=caducadas)
    if not mensaje.get("tipo"):
        _confirmar_entrega(mensaje, [u for u in recibieron if u != mensaje["remitenteId"]])


def _empujar(connection_id, datos):
    """Manda por WebSocket; si la conexión ya no existe la borra y devuelve False."""
    try:
        ws.post_to_connection(ConnectionId=connection_id, Data=datos)
        return True
    except ws.exceptions.GoneException:
        llamar("DELETE", f"/conexiones/{connection_id}")
        return False


def _confirmar_entrega(mensaje, usuarios):
    """✓✓ gris: guarda entregadoHasta de quienes lo recibieron y avisa al remitente.

    Es secundario: si falla, el mensaje ya se entregó, así que solo se registra un
    WARN (lanzar la excepción haría que SQS reintentara y se duplicara la entrega).
    """
    if not usuarios:
        return
    try:
        conexiones = None
        for user_id in usuarios:
            r = llamar("POST", f"/chats/{mensaje['chatId']}/entregado",
                       {"userId": user_id, "hasta": mensaje["enviadoEn"]})
            if not r.get("cambio"):
                continue
            if conexiones is None:
                conexiones = llamar("GET", f"/usuarios/{mensaje['remitenteId']}/conexiones")
            aviso_ws = json.dumps({"tipo": "entregado", "chatId": mensaje["chatId"], "userId": user_id,
                                   "entregadoHasta": r["entregadoHasta"]}).encode()
            for connection_id in conexiones:
                _empujar(connection_id, aviso_ws)
        info("entrega_confirmada", chat_id=mensaje["chatId"], message_id=mensaje.get("messageId"),
             usuarios=len(usuarios))
    except Exception as e:  # noqa: BLE001
        aviso("confirmacion_entrega_fallida", chat_id=mensaje.get("chatId"), error=str(e))


@instrumentado
def handler(event, context):
    fallidos = []
    for record in event["Records"]:
        # La correlación viene de ws_enviar / api_chats como atributo del mensaje SQS.
        attr = (record.get("messageAttributes") or {}).get("correlacion") or {}
        contexto(correlacion=attr.get("stringValue") or context.aws_request_id, sqs_id=record["messageId"])
        try:
            _entregar(json.loads(record["body"]))
        except Exception as e:  # noqa: BLE001 - se reintenta solo este mensaje
            error("entrega_fallida", e, intento=int(record.get("attributes", {}).get("ApproximateReceiveCount", 1)))
            fallidos.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": fallidos}
