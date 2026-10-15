output "ruleset_ids" {
  description = "The ruleset that protects main in each repository, by repository."
  value       = { for repository, ruleset in github_repository_ruleset.main : repository => ruleset.ruleset_id }
}
