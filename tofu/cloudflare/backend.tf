# State lives in an Oracle Object Storage bucket, reached through its S3-compatible API.
# Everything that identifies the tenancy (bucket, namespace, region) is in ../backend.hcl, which
# is not committed: tofu init -backend-config=../backend.hcl  (see ../backend.hcl.example).
# The access key pair comes from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in the shell.
terraform {
  backend "s3" {
    key = "cloudflare/terraform.tfstate"

    # Oracle's endpoint is S3-compatible, not AWS: switch off the AWS-only checks.
    use_path_style              = true
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
