"""GET /monitoreo (API HTTP, cuenta 2, requiere sesión de Cognito).

Junta en una respuesta las métricas de las tres cuentas para el panel de
monitoreo del frontend:
  - cuenta 2: las lee de su propio CloudWatch;
  - cuentas 1 y 3: las pide por HTTPS con el token interno (cada cuenta solo
    puede leer su CloudWatch; en Learner Lab no hay roles entre cuentas).
Las tres consultas van en paralelo.
"""
import json
import os
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse

from metricas import alarmas, consultar, metrica
from registro import aviso, instrumentado

PREFIJO = os.environ["PREFIJO"]
REGION = os.environ["AWS_REGION"]
TOKEN = os.environ["TOKEN_INTERNO"]
HTTP = {"ApiId": os.environ["HTTP_API_ID"]}
WS = {"ApiId": urlparse(os.environ["WS_ENDPOINT"]).hostname.split(".")[0], "Stage": "prod"}
COLA = os.environ["COLA_ENTREGA_URL"].rstrip("/").split("/")[-1]
ENTREGAR = {"FunctionName": f"{PREFIJO}-entregar"}

METRICAS = [
    metrica("http_peticiones", "Peticiones API HTTP", "AWS/ApiGateway", "Count", HTTP,
            ayuda="Lista de chats, historial, crear chats, leído…"),
    metrica("http_latencia", "Latencia p95 API HTTP", "AWS/ApiGateway", "Latency", HTTP,
            stat="p95", resumen="max", unidad="ms"),
    metrica("http_5xx", "Errores 5xx API HTTP", "AWS/ApiGateway", "5xx", HTTP),
    metrica("ws_conexiones", "Conexiones WebSocket nuevas", "AWS/ApiGateway", "ConnectCount", WS),
    metrica("ws_mensajes", "Mensajes por WebSocket", "AWS/ApiGateway", "MessageCount", WS,
            ayuda="Mensajes enviados y recibidos en tiempo real"),
    metrica("lambda_inv", "Invocaciones Lambda", "AWS/Lambda", "Invocations",
            ayuda="Suma de las 8 Lambdas de la cuenta"),
    metrica("lambda_conc", "Instancias Lambda simultáneas (pico)", "AWS/Lambda", "ConcurrentExecutions",
            stat="Maximum", resumen="max", ayuda="Lambda escala horizontalmente: más carga = más copias"),
    metrica("lambda_err", "Errores Lambda", "AWS/Lambda", "Errors"),
    metrica("lambda_throttles", "Lambdas limitadas (throttles)", "AWS/Lambda", "Throttles",
            ayuda="Se alcanzó el límite de concurrencia de la cuenta"),
    metrica("entregar_dur", "Duración p95 de entregar", "AWS/Lambda", "Duration", ENTREGAR,
            stat="p95", resumen="max", unidad="ms"),
    metrica("sqs_enviados", "Mensajes encolados (SQS)", "AWS/SQS", "NumberOfMessagesSent", {"QueueName": COLA}),
    metrica("sqs_visibles", "En espera en la cola (pico)", "AWS/SQS", "ApproximateNumberOfMessagesVisible",
            {"QueueName": COLA}, stat="Maximum", resumen="max",
            ayuda="Si sube, la cola está absorbiendo un pico de carga"),
    metrica("sqs_edad", "Antigüedad del más viejo (pico)", "AWS/SQS", "ApproximateAgeOfOldestMessage",
            {"QueueName": COLA}, stat="Maximum", resumen="max", unidad="s"),
    metrica("dlq", "Mensajes en la DLQ", "AWS/SQS", "ApproximateNumberOfMessagesVisible",
            {"QueueName": f"{COLA}-dlq"}, stat="Maximum", resumen="ultimo",
            ayuda="Entregas que fallaron 3 veces. Debe ser 0"),
    metrica("app_errores", "Errores en logs", f"{PREFIJO}/Aplicacion", "ErroresAplicacion",
            ayuda="Líneas con nivel ERROR (incluye errores controlados y reintentos)"),
    metrica("lat_datos", "Latencia p95 hacia la cuenta 3", f"{PREFIJO}/Aplicacion", "LatenciaCuentaDatos",
            stat="p95", resumen="max", unidad="ms", ayuda="Medida desde los logs de las Lambdas de la cuenta 2"),
]

CUENTAS = [
    ("identidad", "Cuenta 1 · Identidad", "Cognito + triggers Lambda"),
    ("mensajeria", "Cuenta 2 · Mensajería", "API Gateway HTTP y WebSocket, Lambda, SQS"),
    ("datos", "Cuenta 3 · Datos", "API de datos, Lambda, DynamoDB"),
]


def _remota(url):
    req = urllib.request.Request(url, headers={"x-token-interno": TOKEN})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def _local():
    datos = consultar(METRICAS)
    datos["alarmas"] = alarmas(f"{PREFIJO}-")
    return datos


@instrumentado
def handler(_event, _context):
    fuentes = {
        "identidad": lambda: _remota(os.environ["IDENTIDAD_MONITOREO_URL"]),
        "mensajeria": _local,
        "datos": lambda: _remota(os.environ["DATOS_API_URL"].rstrip("/") + "/monitoreo"),
    }
    with ThreadPoolExecutor(max_workers=3) as hilos:
        futuros = {k: hilos.submit(f) for k, f in fuentes.items()}

    cuentas = []
    for clave, titulo, servicios in CUENTAS:
        cuenta = {"id": clave, "titulo": titulo, "servicios": servicios,
                  "dashboard": f"https://{REGION}.console.aws.amazon.com/cloudwatch/home?region={REGION}"
                               f"#dashboards/dashboard/{PREFIJO}-{clave}"}
        try:
            cuenta.update(futuros[clave].result())
        except Exception as e:  # noqa: BLE001 - una cuenta caída no tumba el panel
            aviso("cuenta_sin_metricas", cuenta=clave, error=str(e), tipo_error=type(e).__name__)
            cuenta["error"] = "No se pudieron leer las métricas de esta cuenta"
        cuentas.append(cuenta)

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": json.dumps({"generado": int(time.time() * 1000), "cuentas": cuentas}),
    }
