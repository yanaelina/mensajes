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
