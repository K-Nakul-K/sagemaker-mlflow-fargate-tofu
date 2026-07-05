variable "region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used to prefix and name resources."
  type        = string
  default     = "mlflow"
}

variable "db_name" {
  description = "Name of the MLflow backend database."
  type        = string
  default     = "mlflowdb"
}

variable "db_username" {
  description = "Master username for the MLflow backend database."
  type        = string
  default     = "master"
}

variable "db_port" {
  description = "Port for the MLflow backend database."
  type        = number
  default     = 3306
}

variable "container_port" {
  description = "Port the MLflow server listens on inside the container."
  type        = number
  default     = 5000
}

variable "container_cli" {
  description = "Container CLI used to build and push the image (e.g. docker or podman)."
  type        = string
  default     = "docker"
}

variable "notebook_instance_type" {
  description = "Instance type for the SageMaker notebook instance."
  type        = string
  default     = "ml.t3.medium"
}

variable "notebook_volume_size" {
  description = "EBS volume size (GB) for the SageMaker notebook instance."
  type        = number
  default     = 5
}