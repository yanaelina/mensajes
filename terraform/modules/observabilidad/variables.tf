variable "prefijo" {
  type = string
}

variable "clave" {
  description = "Identificador corto de la cuenta: identidad | mensajeria | datos."
  type        = string
}

variable "nombre_cuenta" {
  description = "Nombre legible que aparece en los avisos de Telegram (p. ej. \"Cuenta 2 · Mensajería\")."
  type        = string
}

variable "lab_role_name" {
  type = string
}

variable "lambdas_dir" {
  description = "Carpeta con el código de la Lambda que reenvía a Telegram."
  type        = string
}

variable "log_groups" {
  description = "Log groups de las Lambdas de la cuenta (logs JSON de lambdas/*/registro.py)."
  type        = list(string)
}

variable "telegram_bot_token" {
  type      = string
  sensitive = true
}

variable "telegram_chat_id" {
  type = string
}

variable "email_alertas" {
  description = "Correo opcional suscrito también al tema SNS (hay que confirmar la suscripción)."
  type        = string
  default     = ""
}

variable "eventos" {
  description = "Crea también el tema SNS <prefijo>-eventos (avisos de actividad de la app, p. ej. chat creado) suscrito a la misma Lambda de Telegram."
  type        = bool
  default     = false
}
