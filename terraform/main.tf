# ---------------------------------------------------------------------------
# Plataforma de mensajería repartida en 3 cuentas de AWS Academy Learner Lab
#
#   Cuenta 1 (identidad)  : Cognito User Pool + triggers de registro
#   Cuenta 2 (mensajería) : API HTTP (REST), API WebSocket, Lambdas, SQS
#   Cuenta 3 (datos)      : DynamoDB + "API de datos" privada por token
#
# Las cuentas se conectan por HTTPS:
#   - La cuenta 2 valida los tokens JWT que emite Cognito (cuenta 1).
#   - Las cuentas 1 y 2 leen/escriben en la cuenta 3 a través de su API de
#     datos, autenticándose con un token interno compartido.
# (En Learner Lab no se pueden crear roles IAM ni hacer assume-role entre
#  cuentas, por eso la conexión es por API y no por IAM.)
# ---------------------------------------------------------------------------

# Token secreto que comparten las cuentas 1 y 2 para hablar con la cuenta 3.
resource "random_password" "token_interno" {
  length  = 48
  special = false
}

data "aws_caller_identity" "identidad" {
  provider = aws.identidad
}

data "aws_caller_identity" "mensajeria" {
  provider = aws.mensajeria
}

data "aws_caller_identity" "datos" {
  provider = aws.datos
}

# Evita desplegar por error todo en la misma cuenta.
check "tres_cuentas_distintas" {
  assert {
    condition = length(distinct([
      data.aws_caller_identity.identidad.account_id,
      data.aws_caller_identity.mensajeria.account_id,
      data.aws_caller_identity.datos.account_id,
    ])) == 3
    error_message = "Los tres perfiles apuntan a cuentas repetidas. Revisa ~/.aws/credentials."
  }
}

# --- Cuenta 3: datos -------------------------------------------------------
module "datos" {
  source = "./modules/datos"
  providers = {
    aws = aws.datos
  }

  prefijo       = var.prefijo
  lab_role_name = var.lab_role_name
  token_interno = random_password.token_interno.result
  lambdas_dir   = "${path.root}/../lambdas/datos"
}

# --- Cuenta 1: identidad ---------------------------------------------------
module "identidad" {
  source = "./modules/identidad"
  providers = {
    aws = aws.identidad
  }

  prefijo                 = var.prefijo
  lab_role_name           = var.lab_role_name
  auto_confirmar_usuarios = var.auto_confirmar_usuarios
  datos_api_url           = module.datos.api_url
  token_interno           = random_password.token_interno.result
  lambdas_dir             = "${path.root}/../lambdas/identidad"
}

# --- Cuenta 2: mensajería --------------------------------------------------
module "mensajeria" {
  source = "./modules/mensajeria"
  providers = {
    aws = aws.mensajeria
  }

  prefijo           = var.prefijo
  lab_role_name     = var.lab_role_name
  cognito_issuer    = module.identidad.issuer
  cognito_client_id = module.identidad.client_id
  datos_api_url     = module.datos.api_url
  token_interno     = random_password.token_interno.result
  lambdas_dir       = "${path.root}/../lambdas/mensajeria"
}
