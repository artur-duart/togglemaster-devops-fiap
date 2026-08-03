terraform {
  backend "s3" {
    bucket       = "togglemaster-tfstate-376903139600"
    key          = "fase3/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
