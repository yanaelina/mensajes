"""$connect: registra la conexión WebSocket del usuario en la cuenta 3."""
from cliente_datos import llamar


def handler(event, _context):
    ctx = event["requestContext"]
    llamar("POST", "/conexiones", {
        "connectionId": ctx["connectionId"],
        "userId": ctx["authorizer"]["userId"],
    })
    return {"statusCode": 200}
