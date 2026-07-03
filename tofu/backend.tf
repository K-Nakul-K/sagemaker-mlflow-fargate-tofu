terraform {
  backend "s3" {
    bucket       = "opentofu-backend-123456789012-us-east-1-an" ## replace with your own bucket name
    key          = "mlops/state/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
