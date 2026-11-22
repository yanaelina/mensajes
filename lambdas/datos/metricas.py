"""Lectura de métricas y alarmas de CloudWatch de ESTA cuenta (panel de monitoreo).

Hay una copia idéntica en lambdas/identidad, lambdas/mensajeria y lambdas/datos:
cada cuenta solo puede leer su propio CloudWatch (en Learner Lab no hay roles
entre cuentas), así que cada una expone sus métricas y la cuenta 2 las junta.
"""
import datetime as dt

import boto3

cw = boto3.client("cloudwatch")

PERIODO = 300   # cubetas de 5 minutos
CUBETAS = 12    # 12 x 5 min = la última hora


def metrica(id_, etiqueta, ns, nombre, dims=None, stat="Sum", resumen="suma", unidad="", ayuda=""):
    """Describe una métrica. resumen: cómo se reduce la serie a un número
    ("suma" = total de la hora, "max" = pico, "prom" = promedio, "ultimo" = valor actual)."""
    return {"id": id_, "etiqueta": etiqueta, "ns": ns, "nombre": nombre, "dims": dims or {},
            "stat": stat, "resumen": resumen, "unidad": unidad, "ayuda": ayuda}


def consultar(metricas):
    ahora = dt.datetime.now(dt.timezone.utc).replace(second=0, microsecond=0)
    # Se alinea a múltiplos de 5 min e incluye la cubeta en curso.
    fin = ahora - dt.timedelta(minutes=ahora.minute % 5) + dt.timedelta(seconds=PERIODO)
    inicio = fin - dt.timedelta(seconds=PERIODO * CUBETAS)

    consultas = [{
        "Id": f"m{i}",
        "MetricStat": {
            "Metric": {
                "Namespace": m["ns"], "MetricName": m["nombre"],
                "Dimensions": [{"Name": k, "Value": v} for k, v in m["dims"].items()],
            },
            "Period": PERIODO, "Stat": m["stat"],
        },
    } for i, m in enumerate(metricas)]

    puntos, token = {}, None
    while True:
        kw = {"MetricDataQueries": consultas, "StartTime": inicio, "EndTime": fin, "ScanBy": "TimestampAscending"}
        if token:
            kw["NextToken"] = token
        r = cw.get_metric_data(**kw)
        for res in r["MetricDataResults"]:
            d = puntos.setdefault(res["Id"], {})
            for t, v in zip(res["Timestamps"], res["Values"]):
                d[int(t.timestamp())] = v
        token = r.get("NextToken")
        if not token:
            break

    cubetas = [int(inicio.timestamp()) + PERIODO * k for k in range(CUBETAS)]
    salida = []
    for i, m in enumerate(metricas):
        d = puntos.get(f"m{i}", {})
        # En contadores (Sum) "sin datos" significa 0; en latencias significa "no hubo peticiones".
        vacio = 0 if m["stat"] == "Sum" else None
        serie = [d.get(c, vacio) for c in cubetas]
        hay = [v for v in serie if v is not None]
        if m["resumen"] == "suma":
            valor = sum(hay)
        elif m["resumen"] == "max":
            valor = max(hay) if hay else None
        elif m["resumen"] == "prom":
            valor = sum(hay) / len(hay) if hay else None
        else:  # "ultimo"
            valor = hay[-1] if hay else None
        salida.append({
            "id": m["id"], "etiqueta": m["etiqueta"], "unidad": m["unidad"], "ayuda": m["ayuda"],
            "resumen": m["resumen"], "valor": valor, "serie": serie,
        })
    return {"inicio": cubetas[0] * 1000, "periodo": PERIODO * 1000, "metricas": salida}


def alarmas(prefijo):
    r = cw.describe_alarms(AlarmNamePrefix=prefijo, AlarmTypes=["MetricAlarm"])
    return [{
        "nombre": a["AlarmName"].removeprefix(prefijo),
        "descripcion": a.get("AlarmDescription", ""),
        "estado": a["StateValue"],  # OK | ALARM | INSUFFICIENT_DATA
    } for a in r["MetricAlarms"]]
