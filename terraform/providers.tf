# Both providers read their token from the environment, never from a file:
#   DIGITALOCEAN_TOKEN    -> custom-scoped DigitalOcean token
#   CLOUDFLARE_API_TOKEN  -> Zone:DNS:Edit on the domain's zone only
provider "digitalocean" {}

provider "cloudflare" {}
