# ===========================================================================
# CUENTA 1: IDENTIDAD
# Cognito User Pool para registro e inicio de sesión. Al confirmarse un
# usuario, un trigger guarda su perfil en la cuenta 3 (datos).
# ===========================================================================

data "aws_iam_role" "lab" {
  name = var.lab_role_name
}

data "aws_region" "actual" {}

# --------------------------------------------------------------- Lambdas ---

data "archive_file" "identidad" {
  type        = "zip"
  source_dir  = var.lambdas_dir
  output_path = "${path.root}/build/identidad.zip"
}

locals {
  triggers = {
    pre-signup        = "pre_signup.handler"
    post-confirmation = "post_confirmation.handler"
  }
}

resource "aws_cloudwatch_log_group" "trigger" {
  for_each          = local.triggers
  name              = "/aws/lambda/${var.prefijo}-${each.key}"
  retention_in_days = 7
}

resource "aws_lambda_function" "trigger" {
  for_each         = local.triggers
  function_name    = "${var.prefijo}-${each.key}"
  role             = data.aws_iam_role.lab.arn
  runtime          = "python3.12"
  handler          = each.value
  filename         = data.archive_file.identidad.output_path
  source_code_hash = data.archive_file.identidad.output_base64sha256
  timeout          = 5

  environment {
    variables = {
      AUTO_CONFIRMAR = tostring(var.auto_confirmar_usuarios)
      DATOS_API_URL  = var.datos_api_url
      TOKEN_INTERNO  = var.token_interno
    }
  }

  depends_on = [aws_cloudwatch_log_group.trigger]
}

resource "aws_lambda_permission" "cognito" {
  for_each      = local.triggers
  statement_id  = "PermitirCognito"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger[each.key].function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.this.arn
}

# --------------------------------------------------------------- Cognito ---

resource "aws_cognito_user_pool" "this" {
  name = "${var.prefijo}-usuarios"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = false
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    mutable             = true
    required            = false

    string_attribute_constraints {
      min_length = 1
      max_length = 100
    }
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  lambda_config {
    pre_sign_up       = aws_lambda_function.trigger["pre-signup"].arn
    post_confirmation = aws_lambda_function.trigger["post-confirmation"].arn
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.prefijo}-web"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 7
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
}
