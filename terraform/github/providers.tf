# GITHUB_TOKEN is the fine-grained token in README.md ("Credentials"): it can
# only administer the repositories in main.tf. It comes from this
# configuration's own .env, never from ../.env, which every run loads.
provider "github" {
  owner = "Abrunacci"
}
