"""Suscriptor del tema SNS de alertas: reenvía cada notificación a Telegram.

Hay un tema SNS y una copia de esta Lambda en CADA cuenta (en Learner Lab no
hay roles entre cuentas). Las alarmas de CloudWatch publican en el tema al pasar
a ALARM y al volver a OK; esta Lambda formatea el aviso y llama a la Bot API:

    CloudWatch Alarm ─► SNS <prefijo>-alertas ─► λ alertas-telegram ─► api.telegram.org
    λ api-chats      ─► SNS <prefijo>-eventos ─┘   (solo cuenta 2: "chat_creado")

Si Telegram falla se lanza la excepción: Lambda reintenta la invocación
asíncrona de SNS (2 reintentos).
"""
import html
import json
import os
import urllib.parse
import urllib.request
from datetime import datetime, timezone

from registro import aviso, contexto, info, instrumentado

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")
CUENTA = os.environ.get("CUENTA", "")

ICONOS = {"ALARM": "🔴", "OK": "✅", "INSUFFICIENT_DATA": "⚪"}
LIMITE = 4000  # Telegram admite 4096 caracteres por mensaje


def _texto_alarma(a):
    nombre = a.get("AlarmName", "?")
    nuevo = a.get("NewStateValue", "?")
    region = (a.get("AlarmArn") or "").split(":")[3] if a.get("AlarmArn") else os.environ.get("AWS_REGION", "")
    enlace = (f"https://{region}.console.aws.amazon.com/cloudwatch/home?region={region}"
              f"#alarmsV2:alarm/{urllib.parse.quote(nombre, safe='')}")
    try:
        hora = datetime.strptime(a["StateChangeTime"][:19], "%Y-%m-%dT%H:%M:%S").strftime("%d/%m/%Y %H:%M:%S UTC")
    except (KeyError, ValueError):
        hora = a.get("StateChangeTime", "")
    titulo = "ALARMA" if nuevo == "ALARM" else "RESUELTA" if nuevo == "OK" else nuevo
    lineas = [
        f"{ICONOS.get(nuevo, '🔔')} <b>{titulo}</b> · {html.escape(CUENTA)}",
        f"<b>{html.escape(nombre)}</b>",
    ]
    if a.get("AlarmDescription"):
        lineas.append(html.escape(a["AlarmDescription"]))
    lineas += [
        "",
        f"Estado: {html.escape(a.get('OldStateValue', '?'))} → <b>{html.escape(nuevo)}</b>",
        f"Motivo: <i>{html.escape(a.get('NewStateReason', ''))}</i>",
        f"🕒 {html.escape(hora)}",
        f'<a href="{html.escape(enlace)}">Ver en CloudWatch</a>',
    ]
    return "\n".join(lineas), nombre, nuevo


def _hora_ms(ms):
    try:
        return datetime.fromtimestamp(int(ms) / 1000, tz=timezone.utc).strftime("%d/%m/%Y %H:%M:%S UTC")
    except (TypeError, ValueError):
        return ""


def _texto_chat_creado(e):
    if e.get("esGrupo"):
        titulo = "👥 <b>Nuevo grupo</b>"
    elif e.get("directo"):
        titulo = "💬 <b>Nuevo chat 1 a 1</b>"
    else:
        titulo = "💬 <b>Nuevo chat</b>"
    lineas = [f"{titulo} · {html.escape(CUENTA)}"]
    if e.get("nombre"):
        lineas.append(f"«{html.escape(e['nombre'])}»")
    lineas += [
        "",
        f"Creado por: {html.escape(str(e.get('creador', '')))}",
        f"Participantes: {html.escape(str(e.get('participantes', '?')))}",
    ]
    hora = _hora_ms(e.get("creadoEn"))
    if hora:
        lineas.append(f"🕒 {hora}")
    return "\n".join(lineas)


def _texto(sns):
    """Devuelve (texto, alarma, estado) a partir del registro SNS."""
    try:
        cuerpo = json.loads(sns["Message"])
    except (ValueError, TypeError):
        cuerpo = None
    if isinstance(cuerpo, dict) and "AlarmName" in cuerpo:
        # INSUFFICIENT_DATA → OK no es una recuperación: pasa al crear la alarma
        # (terraform apply) o cuando vuelve a haber datos. No se avisa.
        if cuerpo.get("OldStateValue") == "INSUFFICIENT_DATA" and cuerpo.get("NewStateValue") == "OK":
            return None, cuerpo.get("AlarmName"), "OK"
        return _texto_alarma(cuerpo)
    if isinstance(cuerpo, dict) and cuerpo.get("evento") == "chat_creado":
        return _texto_chat_creado(cuerpo), None, "chat_creado"
    # Mensaje libre (p. ej. `aws sns publish` de prueba).
    asunto = sns.get("Subject") or "Notificación"
    return f"🔔 <b>{html.escape(asunto)}</b> · {html.escape(CUENTA)}\n{html.escape(sns.get('Message', ''))}", None, None


def _enviar(texto):
    datos = urllib.parse.urlencode({
        "chat_id": CHAT_ID,
        "text": texto[:LIMITE],
        "parse_mode": "HTML",
        "disable_web_page_preview": "true",
    }).encode()
    req = urllib.request.Request(f"https://api.telegram.org/bot{TOKEN}/sendMessage", data=datos)
    with urllib.request.urlopen(req, timeout=8) as r:
        respuesta = json.loads(r.read())
    if not respuesta.get("ok"):
        raise RuntimeError(f"Telegram respondió: {respuesta.get('description')}")


@instrumentado
def handler(event, _context):
    for record in event.get("Records", []):
        sns = record["Sns"]
        contexto(sns_id=sns.get("MessageId"))
        texto, alarma, estado = _texto(sns)
        if texto is None:
            info("notificacion_omitida", alarma=alarma, motivo="INSUFFICIENT_DATA → OK")
            continue
        if not TOKEN or not CHAT_ID:
            aviso("telegram_sin_configurar", alarma=alarma, estado=estado,
                  ayuda="Define telegram_bot_token y telegram_chat_id en terraform.tfvars")
            continue
        _enviar(texto)
        info("notificacion_enviada", alarma=alarma, estado=estado)
