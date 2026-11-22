"""$disconnect: borra la conexión WebSocket de la cuenta 3."""
from cliente_datos import llamar
from registro import info, instrumentado


@instrumentado
def handler(event, _context):
    llamar("DELETE", f"/conexiones/{event['requestContext']['connectionId']}")
    info("conexion_cerrada")
    return {"statusCode": 200}
