output "bucket_names" {
  description = "Each server's backups bucket, by server: the one its backup job writes to."
  value       = { for name, server in local.backup_buckets : server => cloudflare_r2_bucket.backups[name].name }
}
