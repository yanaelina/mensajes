output "api_url" {
  value = aws_apigatewayv2_api.datos.api_endpoint
}

output "tablas" {
  value = {
    usuarios      = aws_dynamodb_table.usuarios.name
    chats         = aws_dynamodb_table.chats.name
    participantes = aws_dynamodb_table.participantes.name
    mensajes      = aws_dynamodb_table.mensajes.name
    conexiones    = aws_dynamodb_table.conexiones.name
  }
}
