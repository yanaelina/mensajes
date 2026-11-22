# ===========================================================================
# OBSERVABILIDAD COMÚN (se instancia una vez por cuenta)
#
#   Alarmas de CloudWatch ─► SNS <prefijo>-alertas ─► λ alertas-telegram ─► Telegram
#                                                 └─► (opcional) correo
#
#   - Logs: las Lambdas escriben una línea JSON por evento (lambdas/*/registro.py).
#     Aquí se crean filtros de métricas sobre esos logs y consultas guardadas
#     de Logs Insights.
#   - Alarma "errores-aplicacion": cualquier línea con nivel = ERROR (incluye
#     errores controlados que no cuentan en la métrica Errors de Lambda, como
#     una entrega fallida que se reintenta o un 502 de la API de chats).
#
# En Learner Lab no hay roles entre cuentas, así que cada cuenta tiene su propio
# tema y su propia Lambda; las tres usan el mismo bot y chat de Telegram.
# ===========================================================================

data "aws_iam_role" "lab" {
  name = var.lab_role_name
}

locals {
  fn_telegram = "${var.prefijo}-alertas-telegram"
  namespace   = "${var.prefijo}/Aplicacion"
  # Todos los log groups de la cuenta, incluido el de la Lambda de Telegram.
  log_groups = concat(var.log_groups, [aws_cloudwatch_log_group.telegram.name])
  sources    = join(" | ", [for g in local.log_groups : "SOURCE '${g}'"])
}

# ------------------------------------------------------------------- SNS ---

resource "aws_sns_topic" "alertas" {
  name = "${var.prefijo}-alertas"
}

resource "aws_sns_topic_subscription" "telegram" {
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.telegram.arn
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.email_alertas == "" ? 0 : 1
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "email"
  endpoint  = var.email_alertas
}

# Avisos de actividad de la app (no son alarmas): p. ej. "chat_creado" desde api-chats.
# Tema aparte para que el correo opcional de alertas no reciba un aviso por cada chat.
resource "aws_sns_topic" "eventos" {
  count = var.eventos ? 1 : 0
  name  = "${var.prefijo}-eventos"
}

resource "aws_sns_topic_subscription" "eventos_telegram" {
  count     = var.eventos ? 1 : 0
  topic_arn = aws_sns_topic.eventos[0].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.telegram.arn
}

resource "aws_lambda_permission" "sns_eventos" {
  count         = var.eventos ? 1 : 0
  statement_id  = "PermitirSNSEventos"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.telegram.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.eventos[0].arn
}

# --------------------------------------------------- Lambda → Telegram ---

data "archive_file" "alertas" {
  type        = "zip"
  source_dir  = var.lambdas_dir
  output_path = "${path.root}/build/alertas-${var.clave}.zip"
}

resource "aws_cloudwatch_log_group" "telegram" {
  name              = "/aws/lambda/${local.fn_telegram}"
  retention_in_days = 7
}

resource "aws_lambda_function" "telegram" {
  function_name    = local.fn_telegram
  role             = data.aws_iam_role.lab.arn
  runtime          = "python3.12"
  handler          = "telegram.handler"
  filename         = data.archive_file.alertas.output_path
  source_code_hash = data.archive_file.alertas.output_base64sha256
  timeout          = 15

  environment {
    variables = {
      TELEGRAM_BOT_TOKEN = var.telegram_bot_token
      TELEGRAM_CHAT_ID   = var.telegram_chat_id
      CUENTA             = var.nombre_cuenta
    }
  }

  depends_on = [aws_cloudwatch_log_group.telegram]
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "PermitirSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.telegram.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alertas.arn
}

# --------------------------------------- Métricas a partir de los logs ---

# Una línea con "nivel": "ERROR" en cualquier Lambda de la cuenta = 1 error.
resource "aws_cloudwatch_log_metric_filter" "errores" {
  for_each       = toset(var.log_groups)
  name           = "errores-aplicacion"
  log_group_name = each.value
  pattern        = "{ $.nivel = \"ERROR\" }"

  metric_transformation {
    name      = "ErroresAplicacion"
    namespace = local.namespace
    value     = "1"
    unit      = "Count"
  }
}

# Avisos (4xx, conexiones rechazadas, llamadas fallidas a la cuenta 3...).
resource "aws_cloudwatch_log_metric_filter" "avisos" {
  for_each       = toset(var.log_groups)
  name           = "avisos-aplicacion"
  log_group_name = each.value
  pattern        = "{ $.nivel = \"WARN\" }"

  metric_transformation {
    name      = "AvisosAplicacion"
    namespace = local.namespace
    value     = "1"
    unit      = "Count"
  }
}

# Timeouts de Lambda: los escribe el runtime (no es JSON), por eso va aparte.
resource "aws_cloudwatch_log_metric_filter" "timeouts" {
  for_each       = toset(var.log_groups)
  name           = "timeouts-lambda"
  log_group_name = each.value
  pattern        = "\"Task timed out\""

  metric_transformation {
    name      = "TimeoutsLambda"
    namespace = local.namespace
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "errores_aplicacion" {
  alarm_name          = "${var.prefijo}-${var.clave}-errores-aplicacion"
  alarm_description   = "Se registraron errores en los logs de las Lambdas (nivel = ERROR o timeouts)."
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alertas.arn]
  ok_actions          = [aws_sns_topic.alertas.arn]

  metric_query {
    id          = "total"
    expression  = "FILL(e, 0) + FILL(t, 0)"
    label       = "Errores en logs"
    return_data = true
  }

  metric_query {
    id = "e"
    metric {
      namespace   = local.namespace
      metric_name = "ErroresAplicacion"
      stat        = "Sum"
      period      = 300
    }
  }

  metric_query {
    id = "t"
    metric {
      namespace   = local.namespace
      metric_name = "TimeoutsLambda"
      stat        = "Sum"
      period      = 300
    }
  }

  depends_on = [aws_cloudwatch_log_metric_filter.errores, aws_cloudwatch_log_metric_filter.timeouts]
}

# Si la propia Lambda de Telegram falla, se avisa por correo (si hay) y en el panel.
# No publica en el tema para no entrar en un bucle de avisos fallidos.
resource "aws_cloudwatch_metric_alarm" "telegram_falla" {
  alarm_name          = "${var.prefijo}-${var.clave}-telegram-falla"
  alarm_description   = "No se pudieron enviar avisos a Telegram (token o chat_id incorrectos, o Telegram caído)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.telegram.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

# ------------------------------------ Consultas guardadas (Logs Insights) ---
# CloudWatch → Logs Insights → "Consultas guardadas" → carpeta <prefijo>-<cuenta>.

locals {
  consultas = {
    "1 Errores recientes"                  = <<-EOT
      fields @timestamp, funcion, evento, error, tipo_error, ruta, correlacion
      | filter nivel = "ERROR" or @message like /Task timed out/
      | sort @timestamp desc
      | limit 100
    EOT
    "2 Avisos recientes"                   = <<-EOT
      fields @timestamp, funcion, evento, status, motivo, error, ruta
      | filter nivel = "WARN"
      | sort @timestamp desc
      | limit 100
    EOT
    "3 Duracion por ruta"                  = <<-EOT
      filter evento = "invocacion_completada"
      | stats count(*) as invocaciones, avg(duracion_ms) as promedio_ms, pct(duracion_ms, 95) as p95_ms, max(duracion_ms) as max_ms by funcion, ruta
      | sort p95_ms desc
    EOT
    "4 Codigos de respuesta"               = <<-EOT
      filter evento = "invocacion_completada" and ispresent(status)
      | stats count(*) as total by ruta, status
      | sort total desc
    EOT
    "5 Seguir una operacion (correlacion)" = <<-EOT
      fields @timestamp, funcion, nivel, evento, destino, status, duracion_ms
      | filter correlacion = "PEGA-AQUI-EL-ID"
      | sort @timestamp asc
    EOT
    "6 Arranques en frio y memoria"        = <<-EOT
      filter @type = "REPORT"
      | stats count(*) as invocaciones, sum(ispresent(@initDuration)) as arranques_en_frio, avg(@initDuration) as init_ms, max(@maxMemoryUsed / 1000 / 1000) as memoria_max_mb by @log
    EOT
  }
}

resource "aws_cloudwatch_query_definition" "consultas" {
  for_each        = local.consultas
  name            = "${var.prefijo}-${var.clave}/${each.key}"
  log_group_names = local.log_groups
  query_string    = each.value
}
