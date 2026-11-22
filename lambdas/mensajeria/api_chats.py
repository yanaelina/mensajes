"""API HTTP de chats (cuenta 2). API Gateway ya validó el JWT de Cognito.

Rutas:
    GET  /yo                       -> mi perfil
    PUT  /yo                       -> crea/actualiza mi perfil (por si el trigger falló)
    GET  /chats                    -> mis chats
    POST /chats                    -> {"nombre": "...", "emails": ["bob@x.com"]}
                                      (1 a 1 sin nombre: si ya existe, devuelve el mismo chat)
    GET  /chats/{chatId}/mensajes  -> historial (solo participantes)
    GET  /chats/{chatId}/miembros  -> participantes con nombre y leidoHasta
    POST /chats/{chatId}/miembros  -> {"emails": [...]}; agrega personas a un chat con nombre
    POST /chats/{chatId}/leido     -> {"hasta": <enviadoEn ms>}; avisa a los demás por WebSocket
    DELETE /chats/{chatId}/mensajes/{messageId}?enviadoEn=<ms> -> borra un mensaje propio para todos
    DELETE /chats/{chatId}?para=mi|todos -> elimina el chat para mí (1 a 1) / salgo (grupo), o para todos
"""
import json
import os
from urllib.parse import quote

import boto3

from cliente_datos import ErrorDatos, llamar
from registro import aviso, contexto, correlacion, error, info, instrumentado

sqs = boto3.client("sqs")
sns = boto3.client("sns")
COLA = os.environ["COLA_ENTREGA_URL"]
# Tema SNS de eventos de la app (→ Telegram). Vacío = no se notifica.
TOPICO_EVENTOS = os.environ.get("TOPICO_EVENTOS_ARN", "")


def respuesta(codigo, cuerpo):
    return {"statusCode": codigo, "headers": {"content-type": "application/json"}, "body": json.dumps(cuerpo)}


def _ids_por_email(emails):
    """Convierte correos en userId. Lanza LookupError con el correo que no existe."""
    ids = []
    for email in emails:
        try:
            ids.append(llamar("GET", f"/usuarios?email={quote(email)}")["userId"])
        except ErrorDatos as e:
            if e.codigo == 404:
                raise LookupError(email) from e
            raise
    return ids


def _limpiar_emails(lista):
    vistos = []
    for e in lista or []:
        e = str(e).strip().lower()
        if e and e not in vistos:
            vistos.append(e)
    return vistos


def _avisar(evento):
    """Encola un aviso; la Lambda "entregar" lo reparte por WebSocket a los participantes."""
    sqs.send_message(QueueUrl=COLA, MessageBody=json.dumps(evento), MessageAttributes={
        "correlacion": {"DataType": "String", "StringValue": correlacion() or "-"}})


def _marcar_entregado(chat_id, yo, lista):
    """Al descargar el historial, lo de los demás ya llegó a mi dispositivo (✓✓ gris).

    Cubre a quien estaba desconectado cuando se envió el mensaje. Si falla no
    afecta la respuesta: solo queda un WARN.
    """
    ajenos = [m["enviadoEn"] for m in lista if m.get("remitenteId") != yo and m.get("enviadoEn")]
    if not ajenos:
        return
    try:
        r = llamar("POST", f"/chats/{chat_id}/entregado", {"userId": yo, "hasta": int(max(ajenos))})
        if r.get("cambio"):
            _avisar({"tipo": "entregado", "chatId": chat_id, "userId": yo, "entregadoHasta": r["entregadoHasta"]})
    except Exception as e:  # noqa: BLE001
        aviso("marcar_entregado_fallido", chat_id=chat_id, error=str(e))


def _notificar_chat_creado(chat, yo, participantes):
    """Publica "chat_creado" en el tema SNS de eventos; la Lambda de Telegram lo reenvía.

    Es solo un aviso: si falla, el chat ya está creado y la respuesta no cambia.
    """
    if not TOPICO_EVENTOS:
        return
    try:
        try:
            perfil = llamar("GET", f"/usuarios/{yo}") or {}
        except ErrorDatos:
            perfil = {}
        evento = {
            "evento": "chat_creado",
            "esGrupo": bool(chat.get("esGrupo")),
            "directo": bool(chat.get("directo")),
            "nombre": chat.get("nombre") or "",
            "participantes": participantes,
            "creador": perfil.get("nombre") or perfil.get("email") or "un usuario",
            "creadoEn": chat.get("creadoEn"),
        }
        sns.publish(
            TopicArn=TOPICO_EVENTOS,
            Subject="Nuevo grupo" if evento["esGrupo"] else "Nuevo chat",
            Message=json.dumps(evento, ensure_ascii=False, default=str),
            MessageAttributes={"evento": {"DataType": "String", "StringValue": "chat_creado"}},
        )
        info("notificacion_chat_publicada", es_grupo=evento["esGrupo"], participantes=participantes)
    except Exception as e:  # noqa: BLE001 - el aviso nunca debe romper la creación del chat
        aviso("notificacion_chat_fallida", error=str(e), tipo_error=type(e).__name__)


@instrumentado
def handler(event, _context):
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    yo = claims["sub"]
    contexto(user_id=yo, chat_id=(event.get("pathParameters") or {}).get("chatId"))
    ruta = event["routeKey"]
    p = event.get("pathParameters") or {}
    q = event.get("queryStringParameters") or {}
    cuerpo = json.loads(event.get("body") or "{}")

    try:
        if ruta == "GET /yo":
            return respuesta(200, llamar("GET", f"/usuarios/{yo}"))

        if ruta == "PUT /yo":
            email = cuerpo.get("email") or claims.get("email")
            if not email:
                return respuesta(400, {"error": "falta email"})
            return respuesta(200, llamar("POST", "/usuarios", {"userId": yo, "email": email, "nombre": cuerpo.get("nombre")}))

        if ruta == "GET /chats":
            return respuesta(200, llamar("GET", f"/usuarios/{yo}/chats"))

        if ruta == "POST /chats":
            emails = [e for e in _limpiar_emails(cuerpo.get("emails")) if e != claims.get("email")]
            if len(emails) > 1 and not (cuerpo.get("nombre") or "").strip():
                return respuesta(400, {"error": "Los grupos necesitan un nombre"})
            ids = _ids_por_email(emails)
            chat = llamar("POST", "/chats", {"nombre": cuerpo.get("nombre"), "creadorId": yo, "participantes": ids})
            if chat.get("existente"):
                return respuesta(200, chat)
            _notificar_chat_creado(chat, yo, len(set(ids) | {yo}))
            return respuesta(201, chat)

        if ruta == "POST /chats/{chatId}/miembros":
            emails = _limpiar_emails(cuerpo.get("emails"))
            if not emails:
                return respuesta(400, {"error": "Añade al menos un correo"})
            ids = _ids_por_email(emails)
            # La API de datos comprueba que pertenezco al chat y que el chat tiene nombre.
            r = llamar("POST", f"/chats/{p['chatId']}/participantes", {"solicitanteId": yo, "participantes": ids})
            _avisar({"tipo": "miembrosAgregados", "chatId": p["chatId"], "agregados": r["agregados"], "por": yo})
            return respuesta(200, r)

        if ruta == "DELETE /chats/{chatId}/mensajes/{messageId}":
            enviado = q.get("enviadoEn", "")
            if not enviado.isdigit():
                return respuesta(400, {"error": "falta enviadoEn"})
            # La API de datos solo lo borra si yo soy el autor.
            r = llamar("DELETE", f"/chats/{p['chatId']}/mensajes/{quote(p['messageId'])}"
                                 f"?enviadoEn={enviado}&remitenteId={quote(yo)}")
            if r.get("cambio"):
                _avisar({"tipo": "mensajeBorrado", "chatId": p["chatId"], "messageId": p["messageId"]})
            return respuesta(200, r)

        if ruta == "DELETE /chats/{chatId}":
            para = q.get("para", "mi")
            if para not in ("mi", "todos"):
                return respuesta(400, {"error": "para debe ser mi o todos"})
            r = llamar("DELETE", f"/chats/{p['chatId']}?solicitanteId={quote(yo)}&para={para}", timeout=27)
            tipo = {"eliminado": "chatEliminado", "oculto": "chatOculto", "salio": "miembroSalio"}[r["accion"]]
            _avisar({"tipo": tipo, "chatId": p["chatId"], "userId": yo, "para": r["para"]})
            return respuesta(200, {k: v for k, v in r.items() if k != "para"})

        if ruta == "GET /chats/{chatId}/mensajes":
            if yo not in llamar("GET", f"/chats/{p['chatId']}/participantes"):
                return respuesta(403, {"error": "no perteneces a este chat"})
            lista = llamar("GET", f"/chats/{p['chatId']}/mensajes?userId={quote(yo)}")
            _marcar_entregado(p["chatId"], yo, lista)
            return respuesta(200, lista)

        if ruta == "GET /chats/{chatId}/miembros":
            miembros = llamar("GET", f"/chats/{p['chatId']}/miembros")
            if not any(m["userId"] == yo for m in miembros):
                return respuesta(403, {"error": "no perteneces a este chat"})
            return respuesta(200, miembros)

        if ruta == "POST /chats/{chatId}/leido":
            hasta = cuerpo.get("hasta")
            if not isinstance(hasta, (int, float)) or hasta <= 0:
                return respuesta(400, {"error": "falta hasta (enviadoEn del último mensaje leído)"})
            # Si no pertenezco al chat, la condición de DynamoDB falla y no cambia nada.
            r = llamar("POST", f"/chats/{p['chatId']}/leido", {"userId": yo, "hasta": int(hasta)})
            if r.get("cambio"):
                # La Lambda "entregar" reparte el aviso a los demás participantes.
                _avisar({"tipo": "leido", "chatId": p["chatId"], "userId": yo, "leidoHasta": r["leidoHasta"]})
            return respuesta(200, r)

    except LookupError as e:
        return respuesta(404, {"error": f"No existe el usuario {e.args[0]}"})
    except ErrorDatos as e:
        if e.codigo >= 500:
            error("error_api_datos", e, status_datos=e.codigo)
            return respuesta(502, {"error": "Error interno, inténtalo de nuevo"})
        return respuesta(e.codigo, {"error": e.mensaje})

    return respuesta(404, {"error": "ruta no encontrada"})
