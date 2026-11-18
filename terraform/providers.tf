# Un provider por cuenta de AWS Academy Learner Lab.
# Cada perfil sale de ~/.aws/credentials (ver README, paso 2).
# Learner Lab solo permite us-east-1 y us-west-2.

locals {
  etiquetas = {
    Proyecto  = var.prefijo
    ManagedBy = "terraform"
  }
}

provider "aws" {
  alias   = "identidad"
  region  = var.region
  profile = var.perfil_identidad

  default_tags {
    tags = merge(local.etiquetas, { Cuenta = "1-identidad" })
  }
}

provider "aws" {
  alias   = "mensajeria"
  region  = var.region
  profile = var.perfil_mensajeria

  default_tags {
    tags = merge(local.etiquetas, { Cuenta = "2-mensajeria" })
  }
}

provider "aws" {
  alias   = "datos"
  region  = var.region
  profile = var.perfil_datos

  default_tags {
    tags = merge(local.etiquetas, { Cuenta = "3-datos" })
  }
}
