output "region" {
  value = var.aws_region
}

output "vpc_id" {
  value = module.networking.vpc_id
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "donation_db_dr_endpoint" {
  description = "Endpoint do RDS donation-db DR (read replica ate promocao)."
  value       = aws_db_instance.donation_replica.endpoint
}

output "donation_db_dr_address" {
  value = aws_db_instance.donation_replica.address
}

output "sqs_queue_url" {
  value = module.messaging_dr.queue_url
}

output "sqs_dlq_url" {
  value = module.messaging_dr.dlq_url
}
