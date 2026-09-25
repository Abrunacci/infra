# CLOUDFLARE_API_TOKEN here is the backups admin token (README.md), not the one
# in ../.env: `Account → Workers R2 Storage → Edit` and nothing else. It is
# kept out of every file and typed in only for runs of this configuration.
provider "cloudflare" {}
