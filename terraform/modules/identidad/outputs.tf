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
