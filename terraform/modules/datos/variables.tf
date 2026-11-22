variable "prefijo" {
  type = string
}

variable "lab_role_name" {
  type = string
}

variable "token_interno" {
  type      = string
  sensitive = true
}

variable "lambdas_dir" {
  description = "Carpeta con el código de la Lambda de datos."
  type        = string
}

variable "topico_alertas_arn" {
  description = "Tema SNS de alertas de esta cuenta (módulo observabilidad). Las alarmas publican ahí."
  type        = string
}
