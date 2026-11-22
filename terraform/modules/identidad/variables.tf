variable "prefijo" {
  type = string
}

variable "lab_role_name" {
  type = string
}

variable "auto_confirmar_usuarios" {
  type = bool
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

variable "topico_alertas_arn" {
  description = "Tema SNS de alertas de esta cuenta (módulo observabilidad). Las alarmas publican ahí."
  type        = string
}
