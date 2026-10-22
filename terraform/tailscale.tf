# Tailscale: the only way to the production Droplet's SSH (production.tf).
# Three kinds of devices in the tailnet:
#   tag:prod  the production Droplet, joined by cloud-init with the key below
#   tag:ci    the machine that runs EPB Stock's promotions (joined by hand,
#             with a key added when promotions start)
#   you       your own devices, signed in with your account
# The first server is not in the tailnet: it keeps its public SSH.
#
# This policy replaces the tailnet's whole policy file: a change made in the
# admin panel is undone by the next apply. Its tests run before Tailscale
# accepts it, so a policy that would open more than this is refused.

resource "tailscale_acl" "this" {
  # The first apply replaces the policy the tailnet already has (the
  # tagOwners added by hand so the OAuth client could be given the tags).
  overwrite_existing_content = true

  acl = jsonencode({
    tagOwners = {
      "tag:prod" = ["autogroup:admin"]
      "tag:ci"   = ["autogroup:admin"]
    }
    # Nothing else is allowed: with grants, every other connection is
    # refused. The Droplet answers, but never starts a connection.
    grants = [
      {
        src = ["autogroup:member"]
        dst = ["tag:prod"]
        ip  = ["tcp:22"]
      },
      {
        src = ["tag:ci"]
        dst = ["tag:prod"]
        ip  = ["tcp:22"]
      },
    ]
    tests = [
      {
        src    = "tag:ci"
        accept = ["tag:prod:22"]
        deny   = ["tag:prod:80", "tag:prod:443", "tag:prod:5432"]
      },
      {
        src  = "tag:prod"
        deny = ["tag:ci:22"]
      },
    ]
  })
}

# The production Droplet's first boot (production.tf, user_data): one use,
# expires in an hour, and the device it adds is tag:prod. It stays in the
# state, used and expired; Terraform does not create it again.
resource "tailscale_tailnet_key" "production" {
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 3600
  tags          = ["tag:prod"]

  # The tags must be in the policy before a key can carry them.
  depends_on = [tailscale_acl.this]
}
