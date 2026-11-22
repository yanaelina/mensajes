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
from boto3.dynamodb.conditions import Attr, Key

import metricas
from registro import aviso, instrumentado

_ddb = boto3.resource("dynamodb")
USUARIOS = _ddb.Table(os.environ["TABLA_USUARIOS"])
CHATS = _ddb.Table(os.environ["TABLA_CHATS"])
PARTICIPANTES = _ddb.Table(os.environ["TABLA_PARTICIPANTES"])
MENSAJES = _ddb.Table(os.environ["TABLA_MENSAJES"])
CONEXIONES = _ddb.Table(os.environ["TABLA_CONEXIONES"])
TOKEN = os.environ["TOKEN_INTERNO"]

MAX_PARTICIPANTES = 100
TTL_CONEXION = 24 * 3600
# Espacio de nombres para el chatId determinista de los chats 1 a 1 sin nombre.
NS_DIRECTO = uuid.UUID("6f1c2a4e-8b3d-4c5a-9e7f-1a2b3c4d5e6f")


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
    chats = [{
        "chatId": i["chatId"],
        "creadorId": i.get("creadorId", ""),
        "nombre": i.get("nombreChat", ""),
        "esGrupo": i.get("esGrupo", True),
        # Chat 1 a 1 sin nombre (no admite más personas). Filas antiguas: se deduce de esGrupo.
        "directo": i.get("directo", not i.get("esGrupo", True)),
        "leidoHasta": i.get("leidoHasta", 0),
    } for i in res["Items"] if not i.get("oculto")]  # "eliminado para mí" en un 1 a 1
    return respuesta(200, chats)


def conexiones_de_usuario(p, q, b):
    res = CONEXIONES.query(IndexName="por_usuario", KeyConditionExpression=Key("userId").eq(p["userId"]))
    return respuesta(200, [i["connectionId"] for i in res["Items"]])


# ---------------------------------------------------------------- chats ---

def _usuarios(ids):
    """Devuelve {userId: item} de la tabla de usuarios (BatchGetItem en lotes de 100)."""
    ids, encontrados = list(ids), {}
    for i in range(0, len(ids), 100):
        pedido = {USUARIOS.name: {"Keys": [{"userId": u} for u in ids[i:i + 100]]}}
        while pedido:
            res = _ddb.batch_get_item(RequestItems=pedido)
            for item in res["Responses"].get(USUARIOS.name, []):
                encontrados[item["userId"]] = item
            pedido = res.get("UnprocessedKeys") or None
    return encontrados


def crear_chat(p, q, b):
    creador = b.get("creadorId")
    participantes = set(b.get("participantes") or [])
    nombre = (b.get("nombre") or "").strip()
    if not creador:
        raise ValueError("creadorId es obligatorio")
    participantes.add(creador)
    if len(participantes) < 2:
        raise ValueError("Un chat necesita al menos 2 participantes")
    if len(participantes) > MAX_PARTICIPANTES:
        raise ValueError(f"Máximo {MAX_PARTICIPANTES} participantes")
    es_grupo = len(participantes) > 2
    if es_grupo and not nombre:
        raise ValueError("Los grupos necesitan un nombre")
    directo = not es_grupo and not nombre

    # Chat 1 a 1 sin nombre: cada participante ve el nombre de la otra persona.
    nombre_para = {uid: nombre for uid in participantes}
    if directo:
        perfiles = _usuarios(participantes)
        for uid in participantes:
            otro = next(o for o in participantes if o != uid)
            perfil = perfiles.get(otro, {})
            nombre_para[uid] = perfil.get("nombre") or perfil.get("email", "Chat")

    # Solo puede haber UN chat 1 a 1 sin nombre por pareja: su chatId se deriva de
    # los dos userId (ordenados) y la escritura condicional evita duplicados,
    # incluso si los dos usuarios lo crean al mismo tiempo.
    chat_id = str(uuid.uuid5(NS_DIRECTO, "|".join(sorted(participantes)))) if directo else str(uuid.uuid4())
    chat = {
        "chatId": chat_id,
        "nombre": nombre,
        "esGrupo": es_grupo,
        "directo": directo,
        "creadorId": creador,
        "creadoEn": ahora_ms(),
    }
    try:
        CHATS.put_item(Item=chat, ConditionExpression="attribute_not_exists(chatId)")
    except _ddb.meta.client.exceptions.ConditionalCheckFailedException:
        # Ya existía el chat entre estas dos personas: se devuelve ese. Si quien lo pide lo
        # había eliminado para sí, vuelve a aparecerle (su historial borrado sigue borrado).
        for uid in participantes:
            expr = ("SET nombreChat = if_not_exists(nombreChat, :n), esGrupo = :f, directo = :t, "
                    "creadorId = if_not_exists(creadorId, :c), leidoHasta = if_not_exists(leidoHasta, :z)")
            PARTICIPANTES.update_item(
                Key={"chatId": chat_id, "userId": uid},
                UpdateExpression=expr + (" REMOVE oculto" if uid == creador else ""),
                ExpressionAttributeValues={":n": nombre_para[uid], ":f": False, ":t": True, ":c": creador, ":z": 0},
            )
        return respuesta(200, {
            "chatId": chat_id, "nombre": nombre_para[creador], "esGrupo": False, "directo": True,
            "participantes": sorted(participantes), "existente": True,
        })

    with PARTICIPANTES.batch_writer() as lote:
        for uid in participantes:
            lote.put_item(Item={
                "chatId": chat_id, "userId": uid, "nombreChat": nombre_para[uid],
                "esGrupo": es_grupo, "directo": directo, "creadorId": creador, "leidoHasta": 0,
            })
    chat["participantes"] = sorted(participantes)
    chat["nombre"] = nombre_para[creador]  # lo que ve quien lo creó
    return respuesta(201, chat)


def agregar_participantes(p, q, b):
    """Agrega personas a un chat con nombre. Si era 1 a 1 con nombre, pasa a ser grupo."""
    solicitante = b.get("solicitanteId")
    nuevos = set(b.get("participantes") or [])
    if not solicitante or not nuevos:
        raise ValueError("solicitanteId y participantes son obligatorios")

    chat = CHATS.get_item(Key={"chatId": p["chatId"]}).get("Item")
    if not chat:
        return respuesta(404, {"error": "chat no encontrado"})
    actuales = {i["userId"]: i for i in PARTICIPANTES.query(
        KeyConditionExpression=Key("chatId").eq(p["chatId"]))["Items"]}
    if solicitante not in actuales:
        return respuesta(403, {"error": "no perteneces a este chat"})
    if not (chat.get("nombre") or "").strip():
        raise ValueError("No se pueden agregar personas a un chat 1 a 1 sin nombre. Crea un grupo.")

    nuevos -= set(actuales)
    if not nuevos:
        raise ValueError("Esas personas ya están en el chat")
    if len(actuales) + len(nuevos) > MAX_PARTICIPANTES:
        raise ValueError(f"Máximo {MAX_PARTICIPANTES} participantes")

    with PARTICIPANTES.batch_writer() as lote:
        for uid in nuevos:
            lote.put_item(Item={
                "chatId": p["chatId"], "userId": uid, "nombreChat": chat["nombre"],
                "esGrupo": True, "directo": False, "creadorId": chat.get("creadorId", ""), "leidoHasta": 0,
            })

    if not chat.get("esGrupo"):
        CHATS.update_item(Key={"chatId": p["chatId"]}, UpdateExpression="SET esGrupo = :t",
                          ExpressionAttributeValues={":t": True})
        for uid in actuales:
            PARTICIPANTES.update_item(Key={"chatId": p["chatId"], "userId": uid},
                                      UpdateExpression="SET esGrupo = :t, directo = :f",
                                      ExpressionAttributeValues={":t": True, ":f": False})

    return respuesta(200, {
        "chatId": p["chatId"], "agregados": sorted(nuevos), "participantes": sorted(set(actuales) | nuevos),
    })


def _eliminar_todo(chat_id, filas):
    """Borra el chat completo. Primero las filas de participantes (desaparece de las listas),
    luego los mensajes y al final el chat (así un 1 a 1 sin nombre se puede volver a crear)."""
    with PARTICIPANTES.batch_writer() as lote:
        for uid in filas:
            lote.delete_item(Key={"chatId": chat_id, "userId": uid})
    pedido = {"KeyConditionExpression": Key("chatId").eq(chat_id), "ProjectionExpression": "sk"}
    with MENSAJES.batch_writer() as lote:
        while True:
            res = MENSAJES.query(**pedido)
            for m in res["Items"]:
                lote.delete_item(Key={"chatId": chat_id, "sk": m["sk"]})
            if "LastEvaluatedKey" not in res:
                break
            pedido["ExclusiveStartKey"] = res["LastEvaluatedKey"]
    CHATS.delete_item(Key={"chatId": chat_id})


def borrar_chat(p, q, b):
    """?solicitanteId=...&para=mi|todos

    para=mi:    1 a 1 -> se oculta para mí y borra mi historial (reaparece si me escriben).
                grupo -> salgo del grupo (si era el último, se borra todo).
    para=todos: borra chat, participantes y mensajes. En grupos solo el creador.
    Devuelve "para": a quién hay que avisar por WebSocket.
    """
    yo, para = q.get("solicitanteId"), q.get("para")
    if not yo or para not in ("mi", "todos"):
        raise ValueError("solicitanteId y para=mi|todos son obligatorios")
    chat_id = p["chatId"]
    chat = CHATS.get_item(Key={"chatId": chat_id}).get("Item")
    filas = {i["userId"]: i for i in PARTICIPANTES.query(KeyConditionExpression=Key("chatId").eq(chat_id))["Items"]}
    if not chat or yo not in filas:
        return respuesta(404, {"error": "chat no encontrado"})
    es_grupo = bool(chat.get("esGrupo"))
    todos = sorted(filas)

    if para == "todos":
        if es_grupo and chat.get("creadorId") != yo:
            return respuesta(403, {"error": "Solo quien creó el grupo puede eliminarlo para todos"})
        _eliminar_todo(chat_id, filas)
        return respuesta(200, {"accion": "eliminado", "chatId": chat_id, "para": todos})

    if not es_grupo:
        PARTICIPANTES.update_item(
            Key={"chatId": chat_id, "userId": yo},
            UpdateExpression="SET oculto = :t, borradoHasta = :ahora",
            ExpressionAttributeValues={":t": True, ":ahora": ahora_ms()},
        )
        return respuesta(200, {"accion": "oculto", "chatId": chat_id, "para": [yo]})

    if len(filas) == 1:  # era el último miembro del grupo
        _eliminar_todo(chat_id, filas)
        return respuesta(200, {"accion": "eliminado", "chatId": chat_id, "para": todos})
    PARTICIPANTES.delete_item(Key={"chatId": chat_id, "userId": yo})
    return respuesta(200, {"accion": "salio", "chatId": chat_id, "userId": yo, "para": todos})


def participantes_de_chat(p, q, b):
    res = PARTICIPANTES.query(KeyConditionExpression=Key("chatId").eq(p["chatId"]))
    return respuesta(200, [i["userId"] for i in res["Items"]])


def miembros_de_chat(p, q, b):
    """Participantes con su nombre y hasta qué mensaje leyeron (ms)."""
    res = PARTICIPANTES.query(KeyConditionExpression=Key("chatId").eq(p["chatId"]))
    perfiles = _usuarios(i["userId"] for i in res["Items"])
    return respuesta(200, [{
        "userId": i["userId"],
        "nombre": perfiles.get(i["userId"], {}).get("nombre") or "Usuario",
        "email": perfiles.get(i["userId"], {}).get("email", ""),
        "leidoHasta": i.get("leidoHasta", 0),
        "entregadoHasta": i.get("entregadoHasta", 0),
    } for i in res["Items"]])


def _avanzar(campo, p, b):
    """Avanza `campo` (leidoHasta / entregadoHasta) de un participante; nunca retrocede."""
    if not b.get("userId") or not b.get("hasta"):
        raise ValueError("userId y hasta son obligatorios")
    hasta = int(b["hasta"])
    try:
        PARTICIPANTES.update_item(
            Key={"chatId": p["chatId"], "userId": b["userId"]},
            UpdateExpression=f"SET {campo} = :h",
            ConditionExpression=f"attribute_exists(userId) AND (attribute_not_exists({campo}) OR {campo} < :h)",
            ExpressionAttributeValues={":h": hasta},
        )
    except _ddb.meta.client.exceptions.ConditionalCheckFailedException:
        return respuesta(200, {"cambio": False})
    return respuesta(200, {"cambio": True, campo: hasta})


def marcar_leido(p, q, b):
    return _avanzar("leidoHasta", p, b)


def marcar_entregado(p, q, b):
    """El mensaje llegó a algún dispositivo del usuario (✓✓ gris)."""
    return _avanzar("entregadoHasta", p, b)


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
    # Un mensaje nuevo hace reaparecer el chat a quien lo había eliminado para sí.
    ocultos = PARTICIPANTES.query(
        KeyConditionExpression=Key("chatId").eq(p["chatId"]),
        FilterExpression=Attr("oculto").exists(), ProjectionExpression="userId",
    )["Items"]
    for i in ocultos:
        PARTICIPANTES.update_item(Key={"chatId": p["chatId"], "userId": i["userId"]}, UpdateExpression="REMOVE oculto")
    return respuesta(201, mensaje)


def listar_mensajes(p, q, b):
    limite = min(int(q.get("limite", 50)), 200)
    condicion = Key("chatId").eq(p["chatId"])
    # Si ?userId= eliminó el chat para sí, solo ve los mensajes posteriores.
    if q.get("userId"):
        fila = PARTICIPANTES.get_item(Key={"chatId": p["chatId"], "userId": q["userId"]}).get("Item") or {}
        if fila.get("borradoHasta"):
            # "~" va después de "#", así se saltan todos los sk con ese mismo timestamp o anteriores.
            condicion = condicion & Key("sk").gt(f"{int(fila['borradoHasta']):013d}~")
    res = MENSAJES.query(
        KeyConditionExpression=condicion,
        ScanIndexForward=False,  # los más nuevos primero
        Limit=limite,
    )
    return respuesta(200, list(reversed(res["Items"])))


def borrar_mensaje(p, q, b):
    """Borrado para todos: deja el mensaje como "eliminado" (sin texto). Solo su autor puede."""
    remitente, enviado = q.get("remitenteId"), q.get("enviadoEn")
    if not remitente or not str(enviado or "").isdigit():
        raise ValueError("remitenteId y enviadoEn son obligatorios")
    clave = {"chatId": p["chatId"], "sk": f"{int(enviado):013d}#{p['messageId']}"}
    try:
        MENSAJES.update_item(
            Key=clave,
            UpdateExpression="SET borrado = :t, borradoEn = :ahora REMOVE texto",
            ConditionExpression="attribute_exists(sk) AND remitenteId = :r AND attribute_not_exists(borrado)",
            ExpressionAttributeValues={":t": True, ":ahora": ahora_ms(), ":r": remitente},
        )
    except _ddb.meta.client.exceptions.ConditionalCheckFailedException:
        item = MENSAJES.get_item(Key=clave).get("Item")
        if not item:
            return respuesta(404, {"error": "mensaje no encontrado"})
        if item["remitenteId"] != remitente:
            return respuesta(403, {"error": "solo puedes borrar tus propios mensajes"})
        return respuesta(200, {"cambio": False})  # ya estaba borrado
    return respuesta(200, {"cambio": True, "chatId": p["chatId"], "messageId": p["messageId"]})


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


# ----------------------------------------------------------- monitoreo ---

def _sumar(salida, ids, id_, etiqueta, ayuda):
    """Junta varias métricas (p. ej. una por tabla) en una sola serie."""
    partes = [m for m in salida["metricas"] if m["id"] in ids]
    salida["metricas"] = [m for m in salida["metricas"] if m["id"] not in ids]
    serie = [sum(v or 0 for v in col) for col in zip(*(m["serie"] for m in partes))]
    salida["metricas"].append({"id": id_, "etiqueta": etiqueta, "unidad": "", "ayuda": ayuda,
                               "resumen": "suma", "valor": sum(serie), "serie": serie})


def monitoreo(p, q, b):
    api = {"ApiId": os.environ["DATOS_API_ID"]}
    fn = {"FunctionName": os.environ["AWS_LAMBDA_FUNCTION_NAME"]}
    tablas = [t.name for t in (USUARIOS, CHATS, PARTICIPANTES, MENSAJES, CONEXIONES)]
    m = metricas.metrica
    lista = [
        m("api_peticiones", "Peticiones a la API de datos", "AWS/ApiGateway", "Count", api,
          ayuda="Todas las lecturas/escrituras de las cuentas 1 y 2 pasan por aquí"),
        m("api_latencia", "Latencia p95", "AWS/ApiGateway", "Latency", api, stat="p95", resumen="max", unidad="ms"),
        m("api_5xx", "Errores 5xx", "AWS/ApiGateway", "5xx", api),
        m("lambda_conc", "Instancias simultáneas (pico)", "AWS/Lambda", "ConcurrentExecutions", fn,
          stat="Maximum", resumen="max", ayuda="Lambda crea más copias cuando sube la carga"),
        m("lambda_dur", "Duración p95", "AWS/Lambda", "Duration", fn, stat="p95", resumen="max", unidad="ms"),
        m("lambda_err", "Errores de la Lambda", "AWS/Lambda", "Errors", fn),
        m("ddb_latencia", "Latencia de escritura (mensajes)", "AWS/DynamoDB", "SuccessfulRequestLatency",
          {"TableName": MENSAJES.name, "Operation": "PutItem"}, stat="Average", resumen="prom", unidad="ms",
          ayuda="Se mantiene estable aunque crezca la tabla"),
    ]
    for t in tablas:
        lista += [
            m(f"wcu_{t}", "", "AWS/DynamoDB", "ConsumedWriteCapacityUnits", {"TableName": t}),
            m(f"rcu_{t}", "", "AWS/DynamoDB", "ConsumedReadCapacityUnits", {"TableName": t}),
            m(f"thr_w_{t}", "", "AWS/DynamoDB", "WriteThrottleEvents", {"TableName": t}),
            m(f"thr_r_{t}", "", "AWS/DynamoDB", "ReadThrottleEvents", {"TableName": t}),
        ]
    salida = metricas.consultar(lista)
    _sumar(salida, {f"wcu_{t}" for t in tablas}, "ddb_escrituras", "Unidades de escritura DynamoDB",
           "On-demand: DynamoDB ajusta la capacidad solo y cobra por petición")
    _sumar(salida, {f"rcu_{t}" for t in tablas}, "ddb_lecturas", "Unidades de lectura DynamoDB", "")
    _sumar(salida, {f"thr_w_{t}" for t in tablas} | {f"thr_r_{t}" for t in tablas},
           "ddb_throttles", "Peticiones limitadas DynamoDB", "Debe ser 0: indica que se alcanzó un límite")
    salida["alarmas"] = metricas.alarmas(f"{os.environ['PREFIJO']}-")
    return respuesta(200, salida)


RUTAS = {
    "GET /monitoreo": monitoreo,
    "POST /usuarios": crear_usuario,
    "GET /usuarios": buscar_usuario_por_email,
    "GET /usuarios/{userId}": obtener_usuario,
    "GET /usuarios/{userId}/chats": chats_de_usuario,
    "GET /usuarios/{userId}/conexiones": conexiones_de_usuario,
    "POST /chats": crear_chat,
    "DELETE /chats/{chatId}": borrar_chat,
    "GET /chats/{chatId}/participantes": participantes_de_chat,
    "POST /chats/{chatId}/participantes": agregar_participantes,
    "GET /chats/{chatId}/miembros": miembros_de_chat,
    "POST /chats/{chatId}/leido": marcar_leido,
    "POST /chats/{chatId}/entregado": marcar_entregado,
    "POST /chats/{chatId}/mensajes": guardar_mensaje,
    "GET /chats/{chatId}/mensajes": listar_mensajes,
    "DELETE /chats/{chatId}/mensajes/{messageId}": borrar_mensaje,
    "POST /conexiones": crear_conexion,
    "DELETE /conexiones/{connectionId}": borrar_conexion,
}


@instrumentado
def handler(event, _context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if not hmac.compare_digest(headers.get("x-token-interno", ""), TOKEN):
        aviso("token_interno_invalido")
        return respuesta(401, {"error": "no autorizado"})

    funcion = RUTAS.get(event.get("routeKey"))
    if funcion is None:
        return respuesta(404, {"error": "ruta no encontrada"})

    try:
        cuerpo = json.loads(event.get("body") or "{}")
        return funcion(event.get("pathParameters") or {}, event.get("queryStringParameters") or {}, cuerpo)
    except (ValueError, json.JSONDecodeError) as e:
        aviso("peticion_invalida", error=str(e))
        return respuesta(400, {"error": str(e)})
