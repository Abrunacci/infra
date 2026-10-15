# GITHUB_TOKEN is the fine-grained token in README.md ("Credentials"): it can
# only administer the repositories in main.tf. It is kept out of every file,
# ../.env included, and typed in only for runs of this configuration.
provider "github" {
  owner = "Abrunacci"
}
