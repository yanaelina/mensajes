output "cuentas" {
  description = "ID de cada cuenta usada."
  value = {
    identidad  = data.aws_caller_identity.identidad.account_id
    mensajeria = data.aws_caller_identity.mensajeria.account_id
    datos      = data.aws_caller_identity.datos.account_id
  }
}

output "cognito_user_pool_id" {
  value = module.identidad.user_pool_id
}

output "cognito_client_id" {
  value = module.identidad.client_id
}

output "api_http_url" {
  description = "API REST de chats (cuenta 2), protegida con Cognito."
  value       = module.mensajeria.http_api_url
}

output "api_websocket_url" {
  description = "API WebSocket de mensajes en tiempo real (cuenta 2)."
  value       = module.mensajeria.websocket_url
}

output "api_datos_url" {
  description = "API interna de datos (cuenta 3). Solo responde con el token interno."
  value       = module.datos.api_url
}

output "tablas_dynamodb" {
  value = module.datos.tablas
}

# Lo usa scripts/generar_config.sh para crear frontend/config.js
output "config_frontend" {
  value = local.config_frontend
}

output "frontend_bucket" {
  description = "Bucket privado (cuenta 2) con el index.html. La URL la genera scripts/generar_url.sh."
  value       = terraform_data.frontend_bucket.output.bucket
}

output "frontend_url" {
  description = "Link fijo del frontend (API HTTP, ruta GET /). Cualquiera puede abrirlo."
  value       = "${module.mensajeria.http_api_url}/"
}
