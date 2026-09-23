# State lives in a Cloudflare R2 bucket through R2's S3-compatible API.
# Nothing identifying goes here; it comes from the environment:
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  -> R2 API token scoped to this bucket
#   AWS_ENDPOINT_URL_S3                        -> https://<account_id>.r2.cloudflarestorage.com
terraform {
  backend "s3" {
    bucket       = "infra-tfstate"
    key          = "infra/terraform.tfstate"
    region       = "auto"
    use_lockfile = true

    # R2 is not AWS: skip the AWS-only checks.
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
