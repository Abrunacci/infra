# Every provider reads its credentials from the environment, never from a file:
#   DIGITALOCEAN_TOKEN    -> custom-scoped DigitalOcean token
#   CLOUDFLARE_API_TOKEN  -> DNS, SSL and Certificates, Email Routing Rules and Zone Settings (Edit), on the
#                            domain's zone only, and Email Routing Addresses and Turnstile (Edit) on the
#                            account only
#   TAILSCALE_OAUTH_CLIENT_ID, TAILSCALE_OAUTH_CLIENT_SECRET
#                         -> OAuth client with Policy File and Auth Keys (write), tags tag:prod and tag:ci
provider "digitalocean" {}

provider "cloudflare" {}

provider "tailscale" {}
