# ---------------------------------------------------------------------------
# Frontend en S3 (cuenta 2), privado. Se abre con una URL pre-firmada que
# genera scripts/generar_url.sh. Como la URL firma solo index.html, la
# configuración va incrustada en el HTML en vez de en un config.js aparte.
# ---------------------------------------------------------------------------

# El bucket se crea con la AWS CLI y no con "aws_s3_bucket": ese recurso lee la
# configuración de Object Lock tras crearlo, y la SCP de AWS Academy lo prohíbe
# (s3:GetBucketObjectLockConfiguration => AccessDenied).
resource "terraform_data" "frontend_bucket" {
  input = {
    bucket = "${var.prefijo}-frontend-${data.aws_caller_identity.mensajeria.account_id}"
    perfil = var.perfil_mensajeria
    region = var.region
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws s3api head-bucket --bucket "${self.input.bucket}" --profile "${self.input.perfil}" --region "${self.input.region}" 2>/dev/null \
        || aws s3api create-bucket --bucket "${self.input.bucket}" --profile "${self.input.perfil}" --region "${self.input.region}"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "aws s3 rb \"s3://${self.input.bucket}\" --force --profile \"${self.input.perfil}\" --region \"${self.input.region}\""
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  provider                = aws.mensajeria
  bucket                  = terraform_data.frontend_bucket.output.bucket
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  config_frontend = {
    region   = var.region
    clientId = module.identidad.client_id
    apiUrl   = module.mensajeria.http_api_url
    wsUrl    = module.mensajeria.websocket_url
  }

  index_html = replace(
    file("${path.root}/../frontend/index.html"),
    "<script src=\"config.js\"></script>",
    "<script>window.CONFIG = ${jsonencode(local.config_frontend)};</script>"
  )
}

resource "aws_s3_object" "index" {
  provider      = aws.mensajeria
  bucket        = aws_s3_bucket_public_access_block.frontend.bucket
  key           = "index.html"
  content       = local.index_html
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache"
  etag          = md5(local.index_html)
}
