# Both providers read their token from the environment, never from a file:
#   DIGITALOCEAN_TOKEN    -> custom-scoped DigitalOcean token
#   CLOUDFLARE_API_TOKEN  -> DNS, SSL and Certificates, Email Routing Rules and Zone Settings (Edit), on the
#                            domain's zone only, and Email Routing Addresses (Edit) on the account only
provider "digitalocean" {}

provider "cloudflare" {}
