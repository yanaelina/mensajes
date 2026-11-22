"""Trigger Post Confirmation (cuenta 1).

Cuando Cognito confirma a un usuario, guardamos su perfil en DynamoDB de la
cuenta 3 llamando a su API de datos.
"""
from cliente_datos import llamar
from registro import contexto, info, instrumentado


@instrumentado
def handler(event, _context):
    attrs = event["request"]["userAttributes"]
    contexto(user_id=attrs["sub"])
    llamar("POST", "/usuarios", {
        "userId": attrs["sub"],
        "email": attrs["email"],
        "nombre": attrs.get("name"),
    })
    info("usuario_registrado")
    return event
