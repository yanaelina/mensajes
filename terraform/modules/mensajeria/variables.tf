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
