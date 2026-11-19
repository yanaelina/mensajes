# ===========================================================================
# CUENTA 2: MENSAJERÍA
#   - API HTTP (REST): crear/listar chats e historial. Autorizador JWT de
#     Cognito (cuenta 1).
#   - API WebSocket: conexión en tiempo real y envío de mensajes. Autorizador
#     Lambda que valida el token de Cognito.
#   - SQS: cola de entrega. Desacopla "guardar" de "repartir" el mensaje.
#   - Toda la persistencia va a la cuenta 3 por su API de datos.
# ===========================================================================

data "aws_iam_role" "lab" {
  name = var.lab_role_name
}

data "aws_region" "actual" {}

data "aws_caller_identity" "actual" {}

locals {
  ws_stage = "prod"

  funciones = {
    ws-authorizer = { handler = "ws_authorizer.handler", timeout = 5 }
    ws-connect    = { handler = "ws_connect.handler", timeout = 10 }
    ws-disconnect = { handler = "ws_disconnect.handler", timeout = 10 }
    ws-enviar     = { handler = "ws_enviar.handler", timeout = 10 }
    entregar      = { handler = "entregar.handler", timeout = 30 }
    api-chats     = { handler = "api_chats.handler", timeout = 10 }
    web           = { handler = "web.handler", timeout = 10 }
  }
}

# --------------------------------------------------------------- Lambdas ---

data "archive_file" "mensajeria" {
  type        = "zip"
  source_dir  = var.lambdas_dir
  output_path = "${path.root}/build/mensajeria.zip"
}

resource "aws_cloudwatch_log_group" "fn" {
  for_each          = local.funciones
  name              = "/aws/lambda/${var.prefijo}-${each.key}"
  retention_in_days = 7
}

resource "aws_lambda_function" "fn" {
  for_each         = local.funciones
  function_name    = "${var.prefijo}-${each.key}"
  role             = data.aws_iam_role.lab.arn
  runtime          = "python3.12"
  handler          = each.value.handler
  filename         = data.archive_file.mensajeria.output_path
  source_code_hash = data.archive_file.mensajeria.output_base64sha256
  timeout          = each.value.timeout
  memory_size      = 256

  environment {
    variables = {
      DATOS_API_URL     = var.datos_api_url
      TOKEN_INTERNO     = var.token_interno
      COGNITO_ISSUER    = var.cognito_issuer
      COGNITO_CLIENT_ID = var.cognito_client_id
      COLA_ENTREGA_URL  = aws_sqs_queue.entrega.url
      # Bucket privado del frontend (lo crea frontend.tf en la raíz con este mismo nombre)
      FRONTEND_BUCKET = "${var.prefijo}-frontend-${data.aws_caller_identity.actual.account_id}"
      # Endpoint de administración de conexiones (para responder por WebSocket)
      WS_ENDPOINT = "https://${aws_apigatewayv2_api.ws.id}.execute-api.${data.aws_region.actual.name}.amazonaws.com/${local.ws_stage}"
    }
  }

  depends_on = [aws_cloudwatch_log_group.fn]
}

# ------------------------------------------------------------------- SQS ---

resource "aws_sqs_queue" "entrega_dlq" {
  name                      = "${var.prefijo}-entrega-dlq"
  message_retention_seconds = 1209600 # 14 días
}

resource "aws_sqs_queue" "entrega" {
  name                       = "${var.prefijo}-entrega"
  visibility_timeout_seconds = 60 # > timeout de la Lambda "entregar"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.entrega_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_lambda_event_source_mapping" "entrega" {
  event_source_arn        = aws_sqs_queue.entrega.arn
  function_name           = aws_lambda_function.fn["entregar"].arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
}

# --------------------------------------------------------- API WebSocket ---

resource "aws_apigatewayv2_api" "ws" {
  name                       = "${var.prefijo}-ws"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

resource "aws_apigatewayv2_authorizer" "ws" {
  api_id           = aws_apigatewayv2_api.ws.id
  name             = "cognito-token"
  authorizer_type  = "REQUEST"
  authorizer_uri   = aws_lambda_function.fn["ws-authorizer"].invoke_arn
  identity_sources = ["route.request.querystring.token"]
}

locals {
  # ruta WebSocket => función Lambda
  rutas_ws = {
    "$connect"    = "ws-connect"
    "$disconnect" = "ws-disconnect"
    enviarMensaje = "ws-enviar"
  }
}

resource "aws_apigatewayv2_integration" "ws" {
  for_each           = local.rutas_ws
  api_id             = aws_apigatewayv2_api.ws.id
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
  integration_uri    = aws_lambda_function.fn[each.value].invoke_arn
}

resource "aws_apigatewayv2_route" "ws" {
  for_each  = local.rutas_ws
  api_id    = aws_apigatewayv2_api.ws.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.ws[each.key].id}"

  # Solo $connect lleva autorizador; la conexión ya autenticada sirve para el resto.
  authorization_type = each.key == "$connect" ? "CUSTOM" : "NONE"
  authorizer_id      = each.key == "$connect" ? aws_apigatewayv2_authorizer.ws.id : null
}

resource "aws_apigatewayv2_stage" "ws" {
  api_id      = aws_apigatewayv2_api.ws.id
  name        = local.ws_stage
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
  }
}

resource "aws_lambda_permission" "ws" {
  for_each      = toset(["ws-authorizer", "ws-connect", "ws-disconnect", "ws-enviar"])
  statement_id  = "PermitirApiWebSocket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.value].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ws.execution_arn}/*"
}

# ---------------------------------------------------- API HTTP (REST) ------

resource "aws_apigatewayv2_api" "http" {
  name          = "${var.prefijo}-http"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PUT", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3600
  }
}

# Valida el JWT de Cognito (cuenta 1) sin necesidad de permisos IAM entre
# cuentas: API Gateway descarga las llaves públicas (JWKS) del issuer.
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.http.id
  name             = "cognito-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = var.cognito_issuer
    audience = [var.cognito_client_id]
  }
}

resource "aws_apigatewayv2_integration" "chats" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.fn["api-chats"].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "http" {
  for_each = toset([
    "GET /yo",
    "PUT /yo",
    "GET /chats",
    "POST /chats",
    "GET /chats/{chatId}/mensajes",
    "GET /chats/{chatId}/miembros",
    "POST /chats/{chatId}/leido",
  ])
  api_id             = aws_apigatewayv2_api.http.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.chats.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# Ruta pública (sin autorizador) que sirve el frontend: link fijo para cualquiera.
resource "aws_apigatewayv2_integration" "web" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.fn["web"].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "web" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.web.id}"
}

resource "aws_lambda_permission" "web" {
  statement_id  = "PermitirApiHttpWeb"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["web"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "http" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "http" {
  statement_id  = "PermitirApiHttp"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["api-chats"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}
