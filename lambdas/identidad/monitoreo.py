"""Métricas de la cuenta 1 (identidad) para el panel de monitoreo.

La llama la Lambda "monitoreo" de la cuenta 2 con el header x-token-interno.
"""
import hmac
import json
import os

from metricas import alarmas, consultar, metrica
from registro import aviso, instrumentado

TOKEN = os.environ["TOKEN_INTERNO"]
PREFIJO = os.environ["PREFIJO"]
POOL = {"UserPool": os.environ["USER_POOL_ID"], "UserPoolClient": os.environ["CLIENT_ID"]}


TRIGGER = {"FunctionName": f"{PREFIJO}-post-confirmation"}


METRICAS = [
    metrica("registros", "Registros", "AWS/Cognito", "SignUpSuccesses", POOL,
            ayuda="Cuentas creadas (Cognito escala solo, sin servidores)"),
    metrica("inicios", "Inicios de sesión", "AWS/Cognito", "SignInSuccesses", POOL),
    metrica("refrescos", "Renovaciones de token", "AWS/Cognito", "TokenRefreshSuccesses", POOL),
    metrica("throttles", "Peticiones limitadas", "AWS/Cognito", "SignInThrottles", POOL,
            ayuda="Cognito rechaza peticiones si se superan sus cuotas"),
    metrica("trigger_inv", "Invocaciones de triggers", "AWS/Lambda", "Invocations",
            TRIGGER, ayuda="Lambda post-confirmation: crea el perfil en la cuenta 3"),
    metrica("trigger_err", "Errores de triggers", "AWS/Lambda", "Errors", TRIGGER),
]


@instrumentado
def handler(event, _context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if not hmac.compare_digest(headers.get("x-token-interno", ""), TOKEN):
        aviso("token_interno_invalido")
        return {"statusCode": 401, "body": json.dumps({"error": "no autorizado"})}
    cuerpo = consultar(METRICAS)
    cuerpo["alarmas"] = alarmas(f"{PREFIJO}-")
    return {"statusCode": 200, "headers": {"content-type": "application/json"}, "body": json.dumps(cuerpo)}
