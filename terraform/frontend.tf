# ---------------------------------------------------------------------------
# Frontend en S3 (cuenta 2), privado. Se abre con una URL pre-firmada que
# genera scripts/generar_url.sh. Como la URL firma solo index.html, la
# configuración va incrustada en el HTML en vez de en un config.js aparte.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "frontend" {
  provider      = aws.mensajeria
  bucket        = "${var.prefijo}-frontend-${data.aws_caller_identity.mensajeria.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  provider                = aws.mensajeria
  bucket                  = aws_s3_bucket.frontend.id
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
  bucket        = aws_s3_bucket.frontend.id
  key           = "index.html"
  content       = local.index_html
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache"
  etag          = md5(local.index_html)
}
