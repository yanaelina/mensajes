# ===========================================================================
# CUENTA 2: OBSERVABILIDAD
#   - GET /monitoreo: junta las métricas de las 3 cuentas para el panel de la app.
#   - Dashboard y alarmas de CloudWatch de las APIs, las Lambdas y SQS.
# ===========================================================================

locals {
  region  = data.aws_region.actual.name
  http_id = aws_apigatewayv2_api.http.id
  ws_id   = aws_apigatewayv2_api.ws.id
  cola    = aws_sqs_queue.entrega.name
  dlq     = aws_sqs_queue.entrega_dlq.name
  # Lambdas que hacen el trabajo de mensajería (sin "web" ni "monitoreo").
  fn_negocio = [for k in ["ws-authorizer", "ws-connect", "ws-disconnect", "ws-enviar", "entregar", "api-chats"] : aws_lambda_function.fn[k].function_name]
  logs       = join(" | ", [for f in local.fn_negocio : "SOURCE '/aws/lambda/${f}'"])
}

# ---------------------------------------------------- Ruta /monitoreo -----

resource "aws_apigatewayv2_integration" "monitoreo" {
  api_id                 = local.http_id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.fn["monitoreo"].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "monitoreo" {
  api_id             = local.http_id
  route_key          = "GET /monitoreo"
  target             = "integrations/${aws_apigatewayv2_integration.monitoreo.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_lambda_permission" "monitoreo" {
  statement_id  = "PermitirApiHttpMonitoreo"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["monitoreo"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

# -------------------------------------------------------------- Alarmas ---

locals {
  alarmas = {
    dlq-con-mensajes = {
      descripcion = "Hay entregas que fallaron 3 veces y quedaron en la DLQ."
      ns          = "AWS/SQS", metrica = "ApproximateNumberOfMessagesVisible", dims = { QueueName = local.dlq }
      stat        = "Maximum", periodo = 60, umbral = 0
    }
    cola-atrasada = {
      descripcion = "El mensaje más viejo de la cola de entrega lleva más de 60 s esperando."
      ns          = "AWS/SQS", metrica = "ApproximateAgeOfOldestMessage", dims = { QueueName = local.cola }
      stat        = "Maximum", periodo = 60, umbral = 60
    }
    lambda-errores = {
      descripcion = "Alguna Lambda de la cuenta de mensajería lanzó errores."
      ns          = "AWS/Lambda", metrica = "Errors", dims = {}
      stat        = "Sum", periodo = 300, umbral = 0
    }
    lambda-limitadas = {
      descripcion = "Lambda rechazó invocaciones por el límite de concurrencia (throttles)."
      ns          = "AWS/Lambda", metrica = "Throttles", dims = {}
      stat        = "Sum", periodo = 300, umbral = 0
    }
    api-http-5xx = {
      descripcion = "La API HTTP devolvió errores 5xx."
      ns          = "AWS/ApiGateway", metrica = "5xx", dims = { ApiId = local.http_id }
      stat        = "Sum", periodo = 300, umbral = 0
    }
    websocket-errores = {
      descripcion = "Errores de ejecución en la API WebSocket."
      ns          = "AWS/ApiGateway", metrica = "ExecutionError", dims = { ApiId = local.ws_id, Stage = local.ws_stage }
      stat        = "Sum", periodo = 300, umbral = 0
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "mensajeria" {
  for_each            = local.alarmas
  alarm_name          = "${var.prefijo}-mensajeria-${each.key}"
  alarm_description   = each.value.descripcion
  namespace           = each.value.ns
  metric_name         = each.value.metrica
  dimensions          = each.value.dims
  statistic           = each.value.stat
  period              = each.value.periodo
  evaluation_periods  = 1
  threshold           = each.value.umbral
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.topico_alertas_arn]
  ok_actions          = [var.topico_alertas_arn]
}

# ------------------------------------- Métricas de negocio desde logs ---
# Salen de las líneas JSON que escriben las Lambdas (lambdas/mensajeria/registro.py).

locals {
  ns_app = "${var.prefijo}/Aplicacion"
}

resource "aws_cloudwatch_log_metric_filter" "mensajes_enviados" {
  name           = "mensajes-enviados"
  log_group_name = aws_cloudwatch_log_group.fn["ws-enviar"].name
  pattern        = "{ $.evento = \"mensaje_enviado\" }"
  metric_transformation {
    name      = "MensajesEnviados"
    namespace = local.ns_app
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "entregas" {
  name           = "entregas-websocket"
  log_group_name = aws_cloudwatch_log_group.fn["entregar"].name
  pattern        = "{ $.evento = \"entrega_completada\" }"
  metric_transformation {
    name      = "EntregasWebSocket"
    namespace = local.ns_app
    value     = "$.entregas"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "conexiones_rechazadas" {
  name           = "conexiones-rechazadas"
  log_group_name = aws_cloudwatch_log_group.fn["ws-authorizer"].name
  pattern        = "{ $.evento = \"conexion_rechazada\" }"
  metric_transformation {
    name      = "ConexionesRechazadas"
    namespace = local.ns_app
    value     = "1"
    unit      = "Count"
  }
}

# Latencia de las llamadas a la API de datos (cuenta 3) vista desde la cuenta 2.
resource "aws_cloudwatch_log_metric_filter" "latencia_datos" {
  for_each       = toset(["ws-connect", "ws-disconnect", "ws-enviar", "entregar", "api-chats"])
  name           = "latencia-cuenta-datos"
  log_group_name = aws_cloudwatch_log_group.fn[each.value].name
  pattern        = "{ $.evento = \"llamada_datos\" }"
  metric_transformation {
    name      = "LatenciaCuentaDatos"
    namespace = local.ns_app
    value     = "$.duracion_ms"
    unit      = "Milliseconds"
  }
}

resource "aws_cloudwatch_metric_alarm" "datos_lenta" {
  alarm_name          = "${var.prefijo}-mensajeria-cuenta-datos-lenta"
  alarm_description   = "Las llamadas de la cuenta 2 a la API de datos (cuenta 3) tardan más de 1,5 s (p95) durante 10 min."
  namespace           = local.ns_app
  metric_name         = "LatenciaCuentaDatos"
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1500
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.topico_alertas_arn]
  ok_actions          = [var.topico_alertas_arn]
}

# ------------------------------------------------------------ Dashboard ---

resource "aws_cloudwatch_dashboard" "mensajeria" {
  dashboard_name = "${var.prefijo}-mensajeria"
  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 2
        properties = { markdown = "## Cuenta 2 · Mensajería\nAPI HTTP (chats) y WebSocket (tiempo real) → Lambdas → SQS → Lambda *entregar*. Todo serverless: cada servicio escala horizontalmente según la carga." }
      },
      {
        type = "metric", x = 0, y = 2, width = 8, height = 6
        properties = {
          title = "API HTTP: peticiones y errores", region = local.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", local.http_id, { label = "Peticiones" }],
            ["AWS/ApiGateway", "4xx", "ApiId", local.http_id, { label = "4xx" }],
            ["AWS/ApiGateway", "5xx", "ApiId", local.http_id, { label = "5xx" }],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 2, width = 8, height = 6
        properties = {
          title = "API HTTP: latencia (ms)", region = local.region, period = 300, view = "timeSeries"
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", local.http_id, { stat = "p50", label = "p50" }],
            ["AWS/ApiGateway", "Latency", "ApiId", local.http_id, { stat = "p95", label = "p95" }],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 2, width = 8, height = 6
        properties = {
          title = "WebSocket: conexiones y mensajes", region = local.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [
            ["AWS/ApiGateway", "ConnectCount", "ApiId", local.ws_id, "Stage", local.ws_stage, { label = "Conexiones nuevas" }],
            ["AWS/ApiGateway", "MessageCount", "ApiId", local.ws_id, "Stage", local.ws_stage, { label = "Mensajes" }],
            ["AWS/ApiGateway", "ClientError", "ApiId", local.ws_id, "Stage", local.ws_stage, { label = "Errores de cliente" }],
            ["AWS/ApiGateway", "ExecutionError", "ApiId", local.ws_id, "Stage", local.ws_stage, { label = "Errores de ejecución" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 12, height = 6
        properties = {
          title   = "Lambda: invocaciones por función", region = local.region, stat = "Sum", period = 300, view = "timeSeries", stacked = true
          metrics = [for f in local.fn_negocio : ["AWS/Lambda", "Invocations", "FunctionName", f, { label = trimprefix(f, "${var.prefijo}-") }]]
        }
      },
      {
        type = "metric", x = 12, y = 8, width = 12, height = 6
        properties = {
          title = "Lambda: instancias simultáneas (escalado) y throttles", region = local.region, period = 60, view = "timeSeries"
          metrics = [
            ["AWS/Lambda", "ConcurrentExecutions", { stat = "Maximum", label = "Instancias simultáneas (toda la cuenta)" }],
            ["AWS/Lambda", "Throttles", { stat = "Sum", label = "Throttles" }],
            ["AWS/Lambda", "Errors", { stat = "Sum", label = "Errores" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 14, width = 12, height = 6
        properties = {
          title   = "Lambda: duración p95 por función (ms)", region = local.region, stat = "p95", period = 300, view = "timeSeries"
          metrics = [for f in local.fn_negocio : ["AWS/Lambda", "Duration", "FunctionName", f, { label = trimprefix(f, "${var.prefijo}-") }]]
        }
      },
      {
        type = "metric", x = 12, y = 14, width = 12, height = 6
        properties = {
          title = "SQS entrega: flujo de mensajes", region = local.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", local.cola, { label = "Encolados" }],
            ["AWS/SQS", "NumberOfMessagesDeleted", "QueueName", local.cola, { label = "Entregados (borrados)" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 20, width = 12, height = 6
        properties = {
          title = "SQS entrega: mensajes en espera", region = local.region, stat = "Maximum", period = 60, view = "timeSeries"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", local.cola, { label = "En espera" }],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", local.dlq, { label = "En la DLQ" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 20, width = 12, height = 6
        properties = {
          title   = "SQS entrega: antigüedad del mensaje más viejo (s)", region = local.region, stat = "Maximum", period = 60, view = "timeSeries"
          metrics = [["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", local.cola, { label = "Antigüedad" }]]
        }
      },
      {
        type = "alarm", x = 0, y = 26, width = 24, height = 4
        properties = {
          title  = "Alarmas"
          alarms = concat([for a in aws_cloudwatch_metric_alarm.mensajeria : a.arn], [aws_cloudwatch_metric_alarm.datos_lenta.arn])
        }
      },
      {
        type = "log", x = 0, y = 30, width = 24, height = 6
        properties = {
          title  = "Últimos errores en los logs (JSON, nivel = ERROR)"
          region = local.region
          view   = "table"
          query  = "${local.logs} | fields @timestamp, funcion, evento, error, ruta, correlacion | filter nivel = \"ERROR\" or @message like /Task timed out/ | sort @timestamp desc | limit 20"
        }
      },
      {
        type = "metric", x = 0, y = 36, width = 12, height = 6
        properties = {
          title = "Logs de aplicación: errores, avisos y timeouts", region = local.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [
            ["${var.prefijo}/Aplicacion", "ErroresAplicacion", { label = "Errores (nivel ERROR)" }],
            ["${var.prefijo}/Aplicacion", "AvisosAplicacion", { label = "Avisos (nivel WARN)" }],
            ["${var.prefijo}/Aplicacion", "TimeoutsLambda", { label = "Timeouts de Lambda" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 36, width = 12, height = 6
        properties = {
          title = "Negocio (desde logs): mensajes y entregas", region = local.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [
            [local.ns_app, "MensajesEnviados", { label = "Mensajes enviados" }],
            [local.ns_app, "EntregasWebSocket", { label = "Entregas por WebSocket" }],
            [local.ns_app, "ConexionesRechazadas", { label = "Conexiones rechazadas" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 42, width = 12, height = 6
        properties = {
          title = "Latencia de llamadas a la cuenta 3 (ms, desde logs)", region = local.region, period = 300, view = "timeSeries"
          metrics = [
            [local.ns_app, "LatenciaCuentaDatos", { stat = "p50", label = "p50" }],
            [local.ns_app, "LatenciaCuentaDatos", { stat = "p95", label = "p95" }],
          ]
        }
      },
    ]
  })
}
