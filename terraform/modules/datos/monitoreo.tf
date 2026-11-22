# ===========================================================================
# CUENTA 3: OBSERVABILIDAD
#   Dashboard y alarmas de la API de datos, su Lambda y DynamoDB.
#   La ruta GET /monitoreo de la API de datos expone estas métricas a la app.
# ===========================================================================

data "aws_region" "actual" {}

locals {
  region = data.aws_region.actual.name
  tablas_ddb = {
    usuarios      = aws_dynamodb_table.usuarios.name
    chats         = aws_dynamodb_table.chats.name
    participantes = aws_dynamodb_table.participantes.name
    mensajes      = aws_dynamodb_table.mensajes.name
    conexiones    = aws_dynamodb_table.conexiones.name
  }
  fn_datos = aws_lambda_function.datos_api.function_name
  api_id   = aws_apigatewayv2_api.datos.id
}

# -------------------------------------------------------------- Alarmas ---

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.prefijo}-datos-api-5xx"
  alarm_description   = "La API de datos devolvió errores 5xx (las cuentas 1 y 2 no pueden leer/escribir)."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = local.api_id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.topico_alertas_arn]
  ok_actions          = [var.topico_alertas_arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_errores" {
  alarm_name          = "${var.prefijo}-datos-lambda-errores"
  alarm_description   = "La Lambda de la API de datos lanzó errores."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = local.fn_datos }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.topico_alertas_arn]
  ok_actions          = [var.topico_alertas_arn]
}

resource "aws_cloudwatch_metric_alarm" "latencia" {
  alarm_name          = "${var.prefijo}-datos-api-lenta"
  alarm_description   = "La latencia p95 de la API de datos superó 1 s durante 10 minutos."
  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  dimensions          = { ApiId = local.api_id }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.topico_alertas_arn]
  ok_actions          = [var.topico_alertas_arn]
}

# Suma de throttles de lectura y escritura de las 5 tablas (metric math).
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  alarm_name          = "${var.prefijo}-datos-dynamodb-limitado"
  alarm_description   = "DynamoDB está limitando peticiones en alguna tabla."
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.topico_alertas_arn]
  ok_actions          = [var.topico_alertas_arn]

  metric_query {
    id          = "total"
    expression  = "SUM(METRICS())"
    label       = "Throttles DynamoDB"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = { for par in setproduct(keys(local.tablas_ddb), ["ReadThrottleEvents", "WriteThrottleEvents"]) : "${par[0]}_${par[1]}" => par }
    content {
      id = lower(replace(metric_query.key, "ThrottleEvents", ""))
      metric {
        namespace   = "AWS/DynamoDB"
        metric_name = metric_query.value[1]
        dimensions  = { TableName = local.tablas_ddb[metric_query.value[0]] }
        stat        = "Sum"
        period      = 300
      }
    }
  }
}

# ------------------------------------------------------------ Dashboard ---

resource "aws_cloudwatch_dashboard" "datos" {
  dashboard_name = "${var.prefijo}-datos"
  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 2
        properties = { markdown = "## Cuenta 3 · Datos\nÚnica cuenta que toca DynamoDB. Todas las lecturas y escrituras de las cuentas 1 y 2 pasan por la API de datos → Lambda → DynamoDB (on-demand)." }
      },
      {
        type = "metric", x = 0, y = 2, width = 8, height = 6
        properties = {
          title = "API de datos: peticiones y errores", region = local.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", local.api_id, { label = "Peticiones" }],
            ["AWS/ApiGateway", "4xx", "ApiId", local.api_id, { label = "4xx" }],
            ["AWS/ApiGateway", "5xx", "ApiId", local.api_id, { label = "5xx" }],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 2, width = 8, height = 6
        properties = {
          title = "API de datos: latencia (ms)", region = local.region, period = 300, view = "timeSeries"
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", local.api_id, { stat = "p50", label = "p50" }],
            ["AWS/ApiGateway", "Latency", "ApiId", local.api_id, { stat = "p95", label = "p95" }],
            ["AWS/ApiGateway", "IntegrationLatency", "ApiId", local.api_id, { stat = "p95", label = "p95 Lambda" }],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 2, width = 8, height = 6
        properties = {
          title = "Lambda datos-api: instancias simultáneas", region = local.region, period = 60, view = "timeSeries"
          metrics = [
            ["AWS/Lambda", "ConcurrentExecutions", "FunctionName", local.fn_datos, { stat = "Maximum", label = "Pico de instancias" }],
            ["AWS/Lambda", "Throttles", "FunctionName", local.fn_datos, { stat = "Sum", label = "Throttles" }],
            ["AWS/Lambda", "Errors", "FunctionName", local.fn_datos, { stat = "Sum", label = "Errores" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 12, height = 6
        properties = {
          title   = "DynamoDB: unidades de escritura consumidas por tabla", region = local.region, stat = "Sum", period = 300, view = "timeSeries", stacked = true
          metrics = [for k, t in local.tablas_ddb : ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", t, { label = k }]]
        }
      },
      {
        type = "metric", x = 12, y = 8, width = 12, height = 6
        properties = {
          title   = "DynamoDB: unidades de lectura consumidas por tabla", region = local.region, stat = "Sum", period = 300, view = "timeSeries", stacked = true
          metrics = [for k, t in local.tablas_ddb : ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", t, { label = k }]]
        }
      },
      {
        type = "metric", x = 0, y = 14, width = 12, height = 6
        properties = {
          title   = "DynamoDB: latencia por operación en mensajes (ms)", region = local.region, stat = "Average", period = 300, view = "timeSeries"
          metrics = [for op in ["PutItem", "Query", "UpdateItem"] : ["AWS/DynamoDB", "SuccessfulRequestLatency", "TableName", local.tablas_ddb.mensajes, "Operation", op, { label = op }]]
        }
      },
      {
        type = "metric", x = 12, y = 14, width = 12, height = 6
        properties = {
          title = "Duración de la Lambda datos-api (ms)", region = local.region, period = 300, view = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", local.fn_datos, { stat = "p50", label = "p50" }],
            ["AWS/Lambda", "Duration", "FunctionName", local.fn_datos, { stat = "p95", label = "p95" }],
          ]
        }
      },
      {
        type = "alarm", x = 0, y = 20, width = 24, height = 3
        properties = {
          title = "Alarmas"
          alarms = [
            aws_cloudwatch_metric_alarm.api_5xx.arn,
            aws_cloudwatch_metric_alarm.lambda_errores.arn,
            aws_cloudwatch_metric_alarm.latencia.arn,
            aws_cloudwatch_metric_alarm.dynamodb_throttles.arn,
          ]
        }
      },
      {
        type = "log", x = 0, y = 23, width = 24, height = 6
        properties = {
          title  = "Últimos errores en los logs (JSON, nivel = ERROR)"
          region = local.region
          view   = "table"
          query  = "SOURCE '/aws/lambda/${local.fn_datos}' | fields @timestamp, funcion, evento, error, ruta, correlacion | filter nivel = \"ERROR\" or @message like /Task timed out/ | sort @timestamp desc | limit 20"
        }
      },
      {
        type = "metric", x = 0, y = 29, width = 24, height = 6
        properties = {
          title = "Logs de aplicación: errores, avisos y timeouts", region = local.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [
            ["${var.prefijo}/Aplicacion", "ErroresAplicacion", { label = "Errores (nivel ERROR)" }],
            ["${var.prefijo}/Aplicacion", "AvisosAplicacion", { label = "Avisos (nivel WARN)" }],
            ["${var.prefijo}/Aplicacion", "TimeoutsLambda", { label = "Timeouts de Lambda" }],
          ]
        }
      },
    ]
  })
}
