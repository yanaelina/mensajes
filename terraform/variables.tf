variable "prefijo" {
  description = "Prefijo para nombrar todos los recursos."
  type        = string
  default     = "mensajeria"
}

variable "region" {
  description = "Región de AWS (Learner Lab permite us-east-1 o us-west-2)."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = contains(["us-east-1", "us-west-2"], var.region)
    error_message = "Learner Lab solo permite us-east-1 o us-west-2."
  }
}

variable "perfil_identidad" {
  description = "Perfil de AWS CLI de la cuenta 1 (Cognito)."
  type        = string
  default     = "cuenta-identidad"
}

variable "perfil_mensajeria" {
  description = "Perfil de AWS CLI de la cuenta 2 (APIs, Lambdas, SQS)."
  type        = string
  default     = "cuenta-mensajeria"
}

variable "perfil_datos" {
  description = "Perfil de AWS CLI de la cuenta 3 (DynamoDB)."
  type        = string
  default     = "cuenta-datos"
}

variable "lab_role_name" {
  description = "Rol que Learner Lab ya trae creado en cada cuenta. No se pueden crear roles propios."
  type        = string
  default     = "LabRole"
}

variable "auto_confirmar_usuarios" {
  description = "Si es true, Cognito confirma a los usuarios sin código por email (útil en el laboratorio)."
  type        = bool
  default     = true
}

# --- Alertas por Telegram (ver README, sección 4.5) ---
variable "telegram_bot_token" {
  description = "Token del bot de Telegram (lo da @BotFather). Vacío = las alertas solo quedan en los logs."
  type        = string
  default     = ""
  sensitive   = true
}

variable "telegram_chat_id" {
  description = "Chat (persona o grupo) que recibe las alertas. Se obtiene con scripts/telegram_chat_id.sh."
  type        = string
  default     = ""
}

variable "email_alertas" {
  description = "Correo opcional suscrito a los temas SNS de las 3 cuentas (llegan 3 correos de confirmación)."
  type        = string
  default     = ""
}

variable "notificar_chats" {
  description = "Si es true, cada chat o grupo nuevo manda un aviso a Telegram (tema SNS mensajeria-eventos)."
  type        = bool
  default     = true
}
