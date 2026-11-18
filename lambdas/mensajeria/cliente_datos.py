"""Cliente HTTP para la API de datos de la cuenta 3."""
import json
import os
import urllib.error
import urllib.request

URL = os.environ["DATOS_API_URL"].rstrip("/")
TOKEN = os.environ["TOKEN_INTERNO"]


class ErrorDatos(Exception):
    def __init__(self, codigo, detalle):
        super().__init__(f"API de datos respondió {codigo}: {detalle}")
        self.codigo = codigo


def llamar(metodo, ruta, cuerpo=None):
    data = json.dumps(cuerpo).encode() if cuerpo is not None else None
    req = urllib.request.Request(
        URL + ruta,
        data=data,
        method=metodo,
        headers={"content-type": "application/json", "x-token-interno": TOKEN},
    )
    try:
        with urllib.request.urlopen(req, timeout=4) as r:
            contenido = r.read()
            return json.loads(contenido) if contenido else None
    except urllib.error.HTTPError as e:
        raise ErrorDatos(e.code, e.read().decode()) from e
