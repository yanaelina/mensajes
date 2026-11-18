"""$disconnect: borra la conexión WebSocket de la cuenta 3."""
from cliente_datos import llamar


def handler(event, _context):
    llamar("DELETE", f"/conexiones/{event['requestContext']['connectionId']}")
    return {"statusCode": 200}
