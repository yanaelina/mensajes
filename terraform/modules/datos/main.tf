# ===========================================================================
# CUENTA 3: DATOS
# Guarda toda la información de la plataforma en DynamoDB y la expone a las
# otras cuentas mediante una API HTTP interna protegida por token.
# ===========================================================================

data "aws_iam_role" "lab" {
  name = var.lab_role_name
}

# ---------------------------------------------------------------- Tablas ---

# Perfil de cada usuario registrado en Cognito.
resource "aws_dynamodb_table" "usuarios" {
  name         = "${var.prefijo}-usuarios"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"

  attribute {
    name = "userId"
    type = "S"
  }

  attribute {
    name = "email"
    type = "S"
  }

  global_secondary_index {
    name            = "por_email"
    hash_key        = "email"
    projection_type = "ALL"
  }
}

# Datos generales de cada conversación (1 a 1 o grupo).
resource "aws_dynamodb_table" "chats" {
  name         = "${var.prefijo}-chats"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "chatId"

  attribute {
    name = "chatId"
    type = "S"
  }
}

# Quién está en cada chat. El GSI permite listar los chats de un usuario.
resource "aws_dynamodb_table" "participantes" {
  name         = "${var.prefijo}-participantes"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "chatId"
  range_key    = "userId"

  attribute {
    name = "chatId"
    type = "S"
  }

  attribute {
    name = "userId"
    type = "S"
  }

  global_secondary_index {
    name            = "por_usuario"
    hash_key        = "userId"
    range_key       = "chatId"
    projection_type = "ALL"
  }
}

# Mensajes ordenados por tiempo dentro de cada chat (sk = timestamp#id).
resource "aws_dynamodb_table" "mensajes" {
  name         = "${var.prefijo}-mensajes"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "chatId"
  range_key    = "sk"

  attribute {
    name = "chatId"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }
}

# Conexiones WebSocket abiertas. Se borran solas con TTL a las 24 h.
resource "aws_dynamodb_table" "conexiones" {
  name         = "${var.prefijo}-conexiones"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "connectionId"

  attribute {
    name = "connectionId"
    type = "S"
  }

  attribute {
    name = "userId"
    type = "S"
  }

  global_secondary_index {
    name            = "por_usuario"
    hash_key        = "userId"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expira"
    enabled        = true
  }
}

# ---------------------------------------------------------- Lambda datos ---

data "archive_file" "datos" {
  type        = "zip"
  source_dir  = var.lambdas_dir
  output_path = "${path.root}/build/datos.zip"
}

resource "aws_cloudwatch_log_group" "datos_api" {
  name              = "/aws/lambda/${var.prefijo}-datos-api"
  retention_in_days = 7
}

resource "aws_lambda_function" "datos_api" {
  function_name    = "${var.prefijo}-datos-api"
  role             = data.aws_iam_role.lab.arn
  runtime          = "python3.12"
  handler          = "datos_api.handler"
  filename         = data.archive_file.datos.output_path
  source_code_hash = data.archive_file.datos.output_base64sha256
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      TOKEN_INTERNO       = var.token_interno
      TABLA_USUARIOS      = aws_dynamodb_table.usuarios.name
      TABLA_CHATS         = aws_dynamodb_table.chats.name
      TABLA_PARTICIPANTES = aws_dynamodb_table.participantes.name
      TABLA_MENSAJES      = aws_dynamodb_table.mensajes.name
      TABLA_CONEXIONES    = aws_dynamodb_table.conexiones.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.datos_api]
}

# ------------------------------------------------------ API HTTP interna ---

resource "aws_apigatewayv2_api" "datos" {
  name          = "${var.prefijo}-datos-api"
  protocol_type = "HTTP"
  description   = "API interna de datos. Solo la usan las cuentas 1 y 2."
}

resource "aws_apigatewayv2_integration" "datos" {
  api_id                 = aws_apigatewayv2_api.datos.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.datos_api.invoke_arn
  payload_format_version = "2.0"
}

locals {
  rutas_datos = toset([
    "POST /usuarios",
    "GET /usuarios",
    "GET /usuarios/{userId}",
    "GET /usuarios/{userId}/chats",
    "GET /usuarios/{userId}/conexiones",
    "POST /chats",
    "GET /chats/{chatId}/participantes",
    "POST /chats/{chatId}/mensajes",
    "GET /chats/{chatId}/mensajes",
    "POST /conexiones",
    "DELETE /conexiones/{connectionId}",
  ])
}

resource "aws_apigatewayv2_route" "datos" {
  for_each  = local.rutas_datos
  api_id    = aws_apigatewayv2_api.datos.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.datos.id}"
}

resource "aws_apigatewayv2_stage" "datos" {
  api_id      = aws_apigatewayv2_api.datos.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 200
    throttling_rate_limit  = 100
  }
}

resource "aws_lambda_permission" "datos_api" {
  statement_id  = "PermitirApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.datos_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.datos.execution_arn}/*/*"
}
