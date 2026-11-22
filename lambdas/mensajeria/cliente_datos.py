"""Cliente HTTP para la API de datos de la cuenta 3."""
import json
import os
import time
import urllib.error
import urllib.request

from registro import aviso, correlacion, info

URL = os.environ["DATOS_API_URL"].rstrip("/")
TOKEN = os.environ["TOKEN_INTERNO"]


class ErrorDatos(Exception):
    def __init__(self, codigo, detalle):
        super().__init__(f"API de datos respondió {codigo}: {detalle}")
        self.codigo = codigo
        # Mensaje legible para el usuario ({"error": "..."} de la API de datos).
        try:
            self.mensaje = json.loads(detalle).get("error") or str(detalle)
        except (ValueError, AttributeError):
            self.mensaje = str(detalle)


def llamar(metodo, ruta, cuerpo=None, timeout=4):
    data = json.dumps(cuerpo).encode() if cuerpo is not None else None
    req = urllib.request.Request(
        URL + ruta,
        data=data,
        method=metodo,
        headers={"content-type": "application/json", "x-token-interno": TOKEN,
                 "x-correlacion": correlacion() or ""},
    )
    inicio = time.perf_counter()
    ruta_log = ruta.split("?")[0]  # sin query (puede llevar correos)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            contenido = r.read()
            info("llamada_datos", metodo=metodo, destino=ruta_log, status=r.status,
                 duracion_ms=round((time.perf_counter() - inicio) * 1000, 1))
            return json.loads(contenido) if contenido else None
    except urllib.error.HTTPError as e:
        aviso("llamada_datos", metodo=metodo, destino=ruta_log, status=e.code,
              duracion_ms=round((time.perf_counter() - inicio) * 1000, 1))
        raise ErrorDatos(e.code, e.read().decode()) from e
