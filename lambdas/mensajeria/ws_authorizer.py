"""Autorizador de la API WebSocket (cuenta 2).

El navegador no puede mandar headers al abrir un WebSocket, así que el
access token de Cognito llega como ?token=... en la URL.

1. Revisamos los claims (issuer, client_id, tipo y expiración) para asegurar
   que el token es de NUESTRO User Pool de la cuenta 1.
2. Llamamos a Cognito GetUser: si el token es falso, expiró o fue revocado,
   Cognito lo rechaza. GetUser se autentica solo con el token, por eso
   funciona desde otra cuenta sin permisos IAM.
"""
import base64
import json
import os
import time

import boto3

from registro import aviso, contexto, info, instrumentado

ISSUER = os.environ["COGNITO_ISSUER"]
CLIENT_ID = os.environ["COGNITO_CLIENT_ID"]
REGION = ISSUER.split(".")[1]  # https://cognito-idp.<region>.amazonaws.com/<pool>

cognito = boto3.client("cognito-idp", region_name=REGION)


def _claims(token):
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def _politica(efecto, recurso, user_id="anonimo", contexto=None):
    return {
        "principalId": user_id,
        "policyDocument": {
            "Version": "2012-10-17",
            "Statement": [{"Action": "execute-api:Invoke", "Effect": efecto, "Resource": recurso}],
        },
        "context": contexto or {},
    }


@instrumentado
def handler(event, _context):
    recurso = event["methodArn"]
    token = (event.get("queryStringParameters") or {}).get("token", "")
    try:
        c = _claims(token)
        if c.get("iss") != ISSUER or c.get("client_id") != CLIENT_ID:
            raise ValueError("token de otro User Pool o cliente")
        if c.get("token_use") != "access" or c.get("exp", 0) < time.time():
            raise ValueError("token no es de acceso o expiró")
        usuario = cognito.get_user(AccessToken=token)
    except Exception as e:  # noqa: BLE001 - cualquier error = acceso denegado
        aviso("conexion_rechazada", motivo=str(e), tipo_error=type(e).__name__)
        return _politica("Deny", recurso)

    attrs = {a["Name"]: a["Value"] for a in usuario["UserAttributes"]}
    contexto(user_id=attrs["sub"])
    info("conexion_autorizada")
    return _politica("Allow", recurso, attrs["sub"], {"userId": attrs["sub"], "email": attrs.get("email", "")})
