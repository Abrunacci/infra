# The rulesets created by hand before this configuration existed. The first
# apply adopts them (and changes what the plan shows) instead of creating a
# second ruleset next to each one. Once applied, these blocks do nothing and
# can be removed.
import {
  to = github_repository_ruleset.main["infra"]
  id = "infra:23998423"
}

import {
  to = github_repository_ruleset.main["abrunacci.dev"]
  id = "abrunacci.dev:23977822"
}

import {
  to = github_repository_ruleset.main["cuanto-cuesta"]
  id = "cuanto-cuesta:23974326"
}

import {
  to = github_repository_ruleset.main["data-pipeline"]
  id = "data-pipeline:24344080"
}

import {
  to = github_repository_ruleset.main["databricks-lab"]
  id = "databricks-lab:24467906"
}

import {
  to = github_repository_ruleset.main["shopify-lab"]
  id = "shopify-lab:23998425"
}

import {
  to = github_repository_ruleset.main["berry_med"]
  id = "berry_med:22931242"
}
