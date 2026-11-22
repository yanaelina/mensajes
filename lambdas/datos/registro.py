"""Logs estructurados para CloudWatch Logs: una línea JSON por evento.

Hay una copia idéntica en lambdas/identidad, lambdas/mensajeria, lambdas/datos
y lambdas/alertas (cada cuenta empaqueta su propia carpeta).

CloudWatch Logs Insights detecta los campos JSON solos, así que se puede filtrar
directamente:  filter nivel = "ERROR"  |  filter correlacion = "..."  |  stats avg(duracion_ms) by ruta

Campos comunes de cada línea:
    nivel        DEBUG | INFO | WARN | ERROR
    evento       qué pasó (p. ej. "mensaje_enviado", "invocacion_completada")
    funcion      nombre de la Lambda
    request_id   id de la invocación (el mismo que aparece en START/END/REPORT)
    correlacion  id que viaja entre cuentas (header x-correlacion y atributo SQS)
                 para seguir una misma operación de la cuenta 2 a la 3.

Uso:
    from registro import instrumentado, info, aviso, error, contexto

    @instrumentado
    def handler(event, context):
        contexto(user_id="...")          # se añade a todas las líneas siguientes
        info("mensaje_enviado", chat_id="...")
"""
import functools
import json
import os
import time
import traceback

FUNCION = os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "local")
NIVELES = {"DEBUG": 10, "INFO": 20, "WARN": 30, "ERROR": 40}
MINIMO = NIVELES.get(os.environ.get("NIVEL_LOG", "INFO").upper(), 20)

_ctx = {}


def log(nivel, evento, **campos):
    if NIVELES[nivel] < MINIMO:
        return
    linea = {"nivel": nivel, "evento": evento, "funcion": FUNCION, **_ctx, **campos}
    print(json.dumps(linea, default=str, ensure_ascii=False), flush=True)


def debug(evento, **campos):
    log("DEBUG", evento, **campos)


def info(evento, **campos):
    log("INFO", evento, **campos)


def aviso(evento, **campos):
    log("WARN", evento, **campos)


def error(evento, exc=None, **campos):
    if exc is not None:
        campos.update(error=str(exc), tipo_error=type(exc).__name__,
                      traza=traceback.format_exception(exc)[-6:])
    log("ERROR", evento, **campos)


def contexto(**campos):
    """Añade campos a todas las líneas de esta invocación."""
    _ctx.update({k: v for k, v in campos.items() if v is not None})


def correlacion():
    return _ctx.get("correlacion")


def _campos_del_evento(event):
    """Extrae del evento lo útil para los logs (nunca tokens ni cuerpos)."""
    if not isinstance(event, dict):
        return {}
    rc = event.get("requestContext") or {}
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    campos = {
        "ruta": event.get("routeKey") or rc.get("routeKey"),
        "trigger": event.get("triggerSource"),
        "conexion": rc.get("connectionId"),
        "correlacion": headers.get("x-correlacion"),
    }
    if "Records" in event:
        campos["registros"] = len(event["Records"])
    return campos


def instrumentado(fn):
    """Decorador del handler: registra inicio de contexto, duración, código de
    respuesta y cualquier excepción no controlada (con traza)."""
    @functools.wraps(fn)
    def envoltura(event, context):
        _ctx.clear()
        request_id = getattr(context, "aws_request_id", None)
        contexto(request_id=request_id, **_campos_del_evento(event))
        _ctx.setdefault("correlacion", request_id)
        inicio = time.perf_counter()
        try:
            resultado = fn(event, context)
        except Exception as e:
            error("invocacion_fallida", e, duracion_ms=round((time.perf_counter() - inicio) * 1000, 1))
            raise
        campos = {"duracion_ms": round((time.perf_counter() - inicio) * 1000, 1)}
        nivel = "INFO"
        if isinstance(resultado, dict) and isinstance(resultado.get("statusCode"), int):
            campos["status"] = resultado["statusCode"]
            nivel = "ERROR" if campos["status"] >= 500 else "WARN" if campos["status"] >= 400 else "INFO"
        log(nivel, "invocacion_completada", **campos)
        return resultado
    return envoltura
