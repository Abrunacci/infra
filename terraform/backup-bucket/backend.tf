# Its own state, next to the main one in the same R2 bucket, under another
# key. The same S3 credentials as the main configuration, from ../.env:
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  -> R2 API token scoped to infra-tfstate
#   AWS_ENDPOINT_URL_S3                        -> https://<account_id>.r2.cloudflarestorage.com
terraform {
  backend "s3" {
    bucket       = "infra-tfstate"
    key          = "infra/backups.tfstate"
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
