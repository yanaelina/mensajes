# ===========================================================================
# CUENTA 1: OBSERVABILIDAD
#   - Dashboard y alarmas de CloudWatch de Cognito y sus triggers.
#   - API "GET /monitoreo" (protegida con el token interno) para que la
#     cuenta 2 muestre estas métricas en el panel de la app.
# ===========================================================================

locals {
  pool_dims = ["UserPool", aws_cognito_user_pool.this.id, "UserPoolClient", aws_cognito_user_pool_client.web.id]
  region    = data.aws_region.actual.name
}

# ------------------------------------------------------- Lambda + API -----

resource "aws_cloudwatch_log_group" "monitoreo" {
  name              = "/aws/lambda/${var.prefijo}-monitoreo-identidad"
  retention_in_days = 7
}

resource "aws_lambda_function" "monitoreo" {
  function_name    = "${var.prefijo}-monitoreo-identidad"
  role             = data.aws_iam_role.lab.arn
  runtime          = "python3.12"
  handler          = "monitoreo.handler"
  filename         = data.archive_file.identidad.output_path
  source_code_hash = data.archive_file.identidad.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      TOKEN_INTERNO = var.token_interno
      PREFIJO       = var.prefijo
      USER_POOL_ID  = aws_cognito_user_pool.this.id
      CLIENT_ID     = aws_cognito_user_pool_client.web.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.monitoreo]
}

resource "aws_apigatewayv2_api" "monitoreo" {
  name          = "${var.prefijo}-monitoreo-identidad"
  protocol_type = "HTTP"
  description   = "Métricas de la cuenta 1 para el panel de monitoreo (token interno)."
}

resource "aws_apigatewayv2_integration" "monitoreo" {
  api_id                 = aws_apigatewayv2_api.monitoreo.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.monitoreo.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "monitoreo" {
  api_id    = aws_apigatewayv2_api.monitoreo.id
  route_key = "GET /monitoreo"
  target    = "integrations/${aws_apigatewayv2_integration.monitoreo.id}"
}

resource "aws_apigatewayv2_stage" "monitoreo" {
  api_id      = aws_apigatewayv2_api.monitoreo.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5
  }
}

resource "aws_lambda_permission" "monitoreo" {
  statement_id  = "PermitirApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.monitoreo.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.monitoreo.execution_arn}/*/*"
}

# -------------------------------------------------------------- Alarmas ---

resource "aws_cloudwatch_metric_alarm" "trigger_errores" {
  alarm_name          = "${var.prefijo}-identidad-triggers-errores"
  alarm_description   = "Falló un trigger de Cognito (p. ej. no se pudo crear el perfil en la cuenta 3)."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.trigger["post-confirmation"].function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.topico_alertas_arn]
  ok_actions          = [var.topico_alertas_arn]
}

resource "aws_cloudwatch_metric_alarm" "cognito_throttles" {
  alarm_name          = "${var.prefijo}-identidad-cognito-limitado"
  alarm_description   = "Cognito está rechazando inicios de sesión por superar su cuota."
  namespace           = "AWS/Cognito"
  metric_name         = "SignInThrottles"
  dimensions          = { UserPool = aws_cognito_user_pool.this.id, UserPoolClient = aws_cognito_user_pool_client.web.id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.topico_alertas_arn]
  ok_actions          = [var.topico_alertas_arn]
}

# ------------------------------------------------ Métricas desde logs ---

resource "aws_cloudwatch_log_metric_filter" "usuarios_registrados" {
  name           = "usuarios-registrados"
  log_group_name = aws_cloudwatch_log_group.trigger["post-confirmation"].name
  pattern        = "{ $.evento = \"usuario_registrado\" }"
  metric_transformation {
    name      = "UsuariosRegistrados"
    namespace = "${var.prefijo}/Aplicacion"
    value     = "1"
    unit      = "Count"
  }
}

# ------------------------------------------------------------ Dashboard ---

resource "aws_cloudwatch_dashboard" "identidad" {
  dashboard_name = "${var.prefijo}-identidad"
  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 2
        properties = { markdown = "## Cuenta 1 · Identidad\nCognito gestiona registro e inicio de sesión y escala solo (servicio administrado). Los triggers Lambda confirman usuarios y crean su perfil en la cuenta 3." }
      },
      {
        type = "metric", x = 0, y = 2, width = 12, height = 6
        properties = {
          title = "Cognito: registros, inicios de sesión y renovaciones", region = local.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [
            concat(["AWS/Cognito", "SignUpSuccesses"], local.pool_dims, [{ label = "Registros" }]),
            concat(["AWS/Cognito", "SignInSuccesses"], local.pool_dims, [{ label = "Inicios de sesión" }]),
            concat(["AWS/Cognito", "TokenRefreshSuccesses"], local.pool_dims, [{ label = "Renovaciones de token" }]),
          ]
        }
      },
      {
        type = "metric", x = 12, y = 2, width = 12, height = 6
        properties = {
          title = "Cognito: peticiones limitadas (throttles)", region = local.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [
            concat(["AWS/Cognito", "SignUpThrottles"], local.pool_dims, [{ label = "Registro" }]),
            concat(["AWS/Cognito", "SignInThrottles"], local.pool_dims, [{ label = "Inicio de sesión" }]),
          ]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 12, height = 6
        properties = {
          title = "Triggers Lambda: invocaciones y errores", region = local.region, stat = "Sum", period = 300, view = "timeSeries"
          # concat (no flatten): flatten aplana todos los niveles y CloudWatch necesita lista de listas
          metrics = concat(
            [for k, f in aws_lambda_function.trigger : ["AWS/Lambda", "Invocations", "FunctionName", f.function_name, { label = "${k} invocaciones" }]],
            [for k, f in aws_lambda_function.trigger : ["AWS/Lambda", "Errors", "FunctionName", f.function_name, { label = "${k} errores" }]],
          )
        }
      },
      {
        type = "metric", x = 12, y = 8, width = 12, height = 6
        properties = {
          title   = "Triggers Lambda: duración p95 (ms)", region = local.region, stat = "p95", period = 300, view = "timeSeries"
          metrics = [for k, f in aws_lambda_function.trigger : ["AWS/Lambda", "Duration", "FunctionName", f.function_name, { label = k }]]
        }
      },
      {
        type = "alarm", x = 0, y = 14, width = 24, height = 3
        properties = {
          title  = "Alarmas"
          alarms = [aws_cloudwatch_metric_alarm.trigger_errores.arn, aws_cloudwatch_metric_alarm.cognito_throttles.arn]
        }
      },
      {
        type = "log", x = 0, y = 17, width = 24, height = 6
        properties = {
          title  = "Últimos errores en los logs (JSON, nivel = ERROR)"
          region = local.region
          view   = "table"
          query  = "SOURCE '/aws/lambda/${var.prefijo}-pre-signup' | SOURCE '/aws/lambda/${var.prefijo}-post-confirmation' | SOURCE '/aws/lambda/${var.prefijo}-monitoreo-identidad' | fields @timestamp, funcion, evento, error, ruta, correlacion | filter nivel = \"ERROR\" or @message like /Task timed out/ | sort @timestamp desc | limit 20"
        }
      },
      {
        type = "metric", x = 0, y = 23, width = 12, height = 6
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
        type = "metric", x = 12, y = 23, width = 12, height = 6
        properties = {
          title   = "Perfiles creados en la cuenta 3 (desde logs)", region = local.region, stat = "Sum", period = 300, view = "timeSeries"
          metrics = [["${var.prefijo}/Aplicacion", "UsuariosRegistrados", { label = "Usuarios registrados" }]]
        }
      },
    ]
  })
}
