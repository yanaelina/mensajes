"""Trigger Pre Sign-up (cuenta 1).

En Learner Lab el envío de emails de Cognito es limitado, así que por defecto
confirmamos al usuario automáticamente. Con AUTO_CONFIRMAR=false se usa el
flujo normal con código por email.
"""
import os


def handler(event, _context):
    if os.environ.get("AUTO_CONFIRMAR", "true").lower() == "true":
        event["response"]["autoConfirmUser"] = True
        event["response"]["autoVerifyEmail"] = True
    return event
