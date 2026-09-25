variable "cloudflare_account_id" {
  description = "Cloudflare account ID. R2 buckets belong to the account. The same value as in ../.env."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_account_id))
    error_message = "cloudflare_account_id must be a 32-character hex string."
  }
}
