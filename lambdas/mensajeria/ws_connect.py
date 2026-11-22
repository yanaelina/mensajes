"""$connect: registra la conexión WebSocket del usuario en la cuenta 3."""
from cliente_datos import llamar
from registro import contexto, info, instrumentado


@instrumentado
def handler(event, _context):
    ctx = event["requestContext"]
    contexto(user_id=ctx["authorizer"]["userId"])
    llamar("POST", "/conexiones", {
        "connectionId": ctx["connectionId"],
        "userId": ctx["authorizer"]["userId"],
    })
    info("conexion_abierta")
    return {"statusCode": 200}
