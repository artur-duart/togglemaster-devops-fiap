terraform {
  backend "s3" {
    bucket       = "togglemaster-tfstate-376903139600"
    key          = "persistent/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
