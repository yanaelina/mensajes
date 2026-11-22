output "user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "client_id" {
  value = aws_cognito_user_pool_client.web.id
}

# La cuenta 2 usa este issuer para validar los JWT.
output "issuer" {
  value = "https://cognito-idp.${data.aws_region.actual.name}.amazonaws.com/${aws_cognito_user_pool.this.id}"
}

output "monitoreo_url" {
  description = "Endpoint de métricas de la cuenta 1 (lo usa la Lambda monitoreo de la cuenta 2)."
  value       = "${aws_apigatewayv2_api.monitoreo.api_endpoint}/monitoreo"
}

output "log_groups" {
  value = concat([for g in aws_cloudwatch_log_group.trigger : g.name], [aws_cloudwatch_log_group.monitoreo.name])
}
