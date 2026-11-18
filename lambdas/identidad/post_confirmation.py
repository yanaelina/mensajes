"""Trigger Post Confirmation (cuenta 1).

Cuando Cognito confirma a un usuario, guardamos su perfil en DynamoDB de la
cuenta 3 llamando a su API de datos.
"""
from cliente_datos import llamar


def handler(event, _context):
    attrs = event["request"]["userAttributes"]
    llamar("POST", "/usuarios", {
        "userId": attrs["sub"],
        "email": attrs["email"],
        "nombre": attrs.get("name"),
    })
    print(f"Usuario {attrs['sub']} guardado en la cuenta de datos")
    return event
