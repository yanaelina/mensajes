variable "prefijo" {
  type = string
}

variable "lab_role_name" {
  type = string
}

variable "cognito_issuer" {
  description = "Issuer del User Pool de la cuenta 1."
  type        = string
}

variable "cognito_client_id" {
  type = string
}

variable "datos_api_url" {
  description = "URL de la API de datos (cuenta 3)."
  type        = string
}

variable "token_interno" {
  type      = string
  sensitive = true
}

variable "lambdas_dir" {
  type = string
}

variable "identidad_monitoreo_url" {
  description = "Endpoint GET /monitoreo de la cuenta 1 (métricas de Cognito)."
  type        = string
}

variable "topico_alertas_arn" {
  description = "Tema SNS de alertas de esta cuenta (módulo observabilidad). Las alarmas publican ahí."
  type        = string
}

variable "topico_eventos_arn" {
  description = "Tema SNS de eventos de la app (chat creado → Telegram). Vacío = sin avisos."
  type        = string
  default     = ""
}
