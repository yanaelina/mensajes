"""API HTTP de chats (cuenta 2). API Gateway ya validó el JWT de Cognito.

Rutas:
    GET  /yo                       -> mi perfil
    PUT  /yo                       -> crea/actualiza mi perfil (por si el trigger falló)
    GET  /chats                    -> mis chats
    POST /chats                    -> {"nombre": "...", "emails": ["bob@x.com"]}
    GET  /chats/{chatId}/mensajes  -> historial (solo participantes)
"""
import json
from urllib.parse import quote

from cliente_datos import ErrorDatos, llamar


def respuesta(codigo, cuerpo):
    return {"statusCode": codigo, "headers": {"content-type": "application/json"}, "body": json.dumps(cuerpo)}


def handler(event, _context):
    claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    yo = claims["sub"]
    ruta = event["routeKey"]
    p = event.get("pathParameters") or {}
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
            ids = []
            for email in cuerpo.get("emails", []):
                try:
                    ids.append(llamar("GET", f"/usuarios?email={quote(email.strip().lower())}")["userId"])
                except ErrorDatos as e:
                    if e.codigo == 404:
                        return respuesta(404, {"error": f"No existe el usuario {email}"})
                    raise
            chat = llamar("POST", "/chats", {"nombre": cuerpo.get("nombre"), "creadorId": yo, "participantes": ids})
            return respuesta(201, chat)

        if ruta == "GET /chats/{chatId}/mensajes":
            if yo not in llamar("GET", f"/chats/{p['chatId']}/participantes"):
                return respuesta(403, {"error": "no perteneces a este chat"})
            return respuesta(200, llamar("GET", f"/chats/{p['chatId']}/mensajes"))

    except ErrorDatos as e:
        return respuesta(e.codigo if e.codigo < 500 else 502, {"error": str(e)})

    return respuesta(404, {"error": "ruta no encontrada"})
