"""API de datos (cuenta 3).

Es la única puerta a DynamoDB. Las cuentas 1 y 2 la llaman por HTTPS
enviando el header `x-token-interno`.
"""
import hmac
import json
import os
import time
import uuid
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

_ddb = boto3.resource("dynamodb")
USUARIOS = _ddb.Table(os.environ["TABLA_USUARIOS"])
CHATS = _ddb.Table(os.environ["TABLA_CHATS"])
PARTICIPANTES = _ddb.Table(os.environ["TABLA_PARTICIPANTES"])
MENSAJES = _ddb.Table(os.environ["TABLA_MENSAJES"])
CONEXIONES = _ddb.Table(os.environ["TABLA_CONEXIONES"])
TOKEN = os.environ["TOKEN_INTERNO"]

MAX_PARTICIPANTES = 100
TTL_CONEXION = 24 * 3600


def _json(valor):
    if isinstance(valor, Decimal):
        return int(valor) if valor % 1 == 0 else float(valor)
    raise TypeError(f"No serializable: {type(valor)}")


def respuesta(codigo, cuerpo):
    return {
        "statusCode": codigo,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(cuerpo, default=_json),
    }


def ahora_ms():
    return int(time.time() * 1000)


# ------------------------------------------------------------- usuarios ---

def crear_usuario(p, q, b):
    if not b.get("userId") or not b.get("email"):
        raise ValueError("userId y email son obligatorios")
    item = {
        "userId": b["userId"],
        "email": b["email"].lower(),
        "nombre": b.get("nombre") or b["email"].split("@")[0],
        "creadoEn": ahora_ms(),
    }
    # Idempotente: si ya existe no se pisa la fecha de creación.
    USUARIOS.update_item(
        Key={"userId": item["userId"]},
        UpdateExpression="SET email = :e, nombre = :n, creadoEn = if_not_exists(creadoEn, :c)",
        ExpressionAttributeValues={":e": item["email"], ":n": item["nombre"], ":c": item["creadoEn"]},
    )
    return respuesta(201, item)


def buscar_usuario_por_email(p, q, b):
    email = (q.get("email") or "").lower()
    if not email:
        raise ValueError("Falta ?email=")
    res = USUARIOS.query(IndexName="por_email", KeyConditionExpression=Key("email").eq(email))
    if not res["Items"]:
        return respuesta(404, {"error": "usuario no encontrado"})
    return respuesta(200, res["Items"][0])


def obtener_usuario(p, q, b):
    item = USUARIOS.get_item(Key={"userId": p["userId"]}).get("Item")
    return respuesta(200, item) if item else respuesta(404, {"error": "usuario no encontrado"})


def chats_de_usuario(p, q, b):
    res = PARTICIPANTES.query(IndexName="por_usuario", KeyConditionExpression=Key("userId").eq(p["userId"]))
    chats = [{"chatId": i["chatId"], "nombre": i.get("nombreChat", "")} for i in res["Items"]]
    return respuesta(200, chats)


def conexiones_de_usuario(p, q, b):
    res = CONEXIONES.query(IndexName="por_usuario", KeyConditionExpression=Key("userId").eq(p["userId"]))
    return respuesta(200, [i["connectionId"] for i in res["Items"]])


# ---------------------------------------------------------------- chats ---

def crear_chat(p, q, b):
    creador = b.get("creadorId")
    participantes = set(b.get("participantes") or [])
    if not creador:
        raise ValueError("creadorId es obligatorio")
    participantes.add(creador)
    if len(participantes) < 2:
        raise ValueError("Un chat necesita al menos 2 participantes")
    if len(participantes) > MAX_PARTICIPANTES:
        raise ValueError(f"Máximo {MAX_PARTICIPANTES} participantes")

    chat = {
        "chatId": str(uuid.uuid4()),
        "nombre": b.get("nombre") or "Chat",
        "creadorId": creador,
        "creadoEn": ahora_ms(),
    }
    CHATS.put_item(Item=chat)
    with PARTICIPANTES.batch_writer() as lote:
        for uid in participantes:
            lote.put_item(Item={"chatId": chat["chatId"], "userId": uid, "nombreChat": chat["nombre"]})
    chat["participantes"] = sorted(participantes)
    return respuesta(201, chat)


def participantes_de_chat(p, q, b):
    res = PARTICIPANTES.query(KeyConditionExpression=Key("chatId").eq(p["chatId"]))
    return respuesta(200, [i["userId"] for i in res["Items"]])


def guardar_mensaje(p, q, b):
    texto = (b.get("texto") or "").strip()
    if not b.get("remitenteId") or not texto:
        raise ValueError("remitenteId y texto son obligatorios")
    ts = ahora_ms()
    mensaje = {
        "chatId": p["chatId"],
        "messageId": str(uuid.uuid4()),
        "remitenteId": b["remitenteId"],
        "texto": texto[:4000],
        "enviadoEn": ts,
    }
    mensaje["sk"] = f"{ts:013d}#{mensaje['messageId']}"
    MENSAJES.put_item(Item=mensaje)
    return respuesta(201, mensaje)


def listar_mensajes(p, q, b):
    limite = min(int(q.get("limite", 50)), 200)
    res = MENSAJES.query(
        KeyConditionExpression=Key("chatId").eq(p["chatId"]),
        ScanIndexForward=False,  # los más nuevos primero
        Limit=limite,
    )
    return respuesta(200, list(reversed(res["Items"])))


# ----------------------------------------------------------- conexiones ---

def crear_conexion(p, q, b):
    if not b.get("connectionId") or not b.get("userId"):
        raise ValueError("connectionId y userId son obligatorios")
    CONEXIONES.put_item(Item={
        "connectionId": b["connectionId"],
        "userId": b["userId"],
        "conectadoEn": ahora_ms(),
        "expira": int(time.time()) + TTL_CONEXION,
    })
    return respuesta(201, {"ok": True})


def borrar_conexion(p, q, b):
    CONEXIONES.delete_item(Key={"connectionId": p["connectionId"]})
    return respuesta(200, {"ok": True})


RUTAS = {
    "POST /usuarios": crear_usuario,
    "GET /usuarios": buscar_usuario_por_email,
    "GET /usuarios/{userId}": obtener_usuario,
    "GET /usuarios/{userId}/chats": chats_de_usuario,
    "GET /usuarios/{userId}/conexiones": conexiones_de_usuario,
    "POST /chats": crear_chat,
    "GET /chats/{chatId}/participantes": participantes_de_chat,
    "POST /chats/{chatId}/mensajes": guardar_mensaje,
    "GET /chats/{chatId}/mensajes": listar_mensajes,
    "POST /conexiones": crear_conexion,
    "DELETE /conexiones/{connectionId}": borrar_conexion,
}


def handler(event, _context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if not hmac.compare_digest(headers.get("x-token-interno", ""), TOKEN):
        return respuesta(401, {"error": "no autorizado"})

    funcion = RUTAS.get(event.get("routeKey"))
    if funcion is None:
        return respuesta(404, {"error": "ruta no encontrada"})

    try:
        cuerpo = json.loads(event.get("body") or "{}")
        return funcion(event.get("pathParameters") or {}, event.get("queryStringParameters") or {}, cuerpo)
    except (ValueError, json.JSONDecodeError) as e:
        return respuesta(400, {"error": str(e)})
