"""Ruta pública GET / de la API HTTP (cuenta 2).

Devuelve el frontend (index.html) leyéndolo del bucket S3 privado. Así hay un
link fijo y público sin abrir el bucket y sin CloudFront (Learner Lab no
permite crear OAC/OAI).
"""
import os

import boto3

from registro import instrumentado

s3 = boto3.client("s3")
BUCKET = os.environ["FRONTEND_BUCKET"]


@instrumentado
def handler(_event, _context):
    html = s3.get_object(Bucket=BUCKET, Key="index.html")["Body"].read().decode()
    return {
        "statusCode": 200,
        "headers": {"content-type": "text/html; charset=utf-8", "cache-control": "no-cache"},
        "body": html,
    }
