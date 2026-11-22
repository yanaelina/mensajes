output "http_api_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}

output "websocket_url" {
  value = "${aws_apigatewayv2_api.ws.api_endpoint}/${aws_apigatewayv2_stage.ws.name}"
}

output "cola_entrega_url" {
  value = aws_sqs_queue.entrega.url
}

output "log_groups" {
  value = [for g in aws_cloudwatch_log_group.fn : g.name]
}
