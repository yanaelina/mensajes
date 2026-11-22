output "topico_alertas_arn" {
  description = "Tema SNS al que publican las alarmas de la cuenta."
  value       = aws_sns_topic.alertas.arn
}

output "namespace" {
  description = "Namespace de las métricas generadas a partir de los logs."
  value       = local.namespace
}

output "alarma_errores_arn" {
  value = aws_cloudwatch_metric_alarm.errores_aplicacion.arn
}

output "logs_insights_sources" {
  description = "Prefijo SOURCE '...' | ... con todos los log groups de la cuenta (para widgets de logs)."
  value       = local.sources
}

output "topico_eventos_arn" {
  description = "Tema SNS de eventos de la app (vacío si eventos = false)."
  value       = var.eventos ? aws_sns_topic.eventos[0].arn : ""
}
