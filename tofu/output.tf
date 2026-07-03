output "load_balancer_dns" {
  description = "Public DNS name of the MLflow network load balancer."
  value       = aws_lb.mlflow.dns_name
}

output "mlflow_url" {
  description = "URL to access the MLflow tracking server."
  value       = "http://${aws_lb.mlflow.dns_name}"
}

output "artifact_bucket" {
  description = "S3 bucket used to store MLflow artifacts."
  value       = aws_s3_bucket.my_bucket.bucket
}

output "rds_endpoint" {
  description = "Endpoint address of the MLflow backend RDS instance."
  value       = aws_db_instance.mysql.address
}
