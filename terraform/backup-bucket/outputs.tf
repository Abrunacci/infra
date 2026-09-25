output "bucket_name" {
  description = "Bucket the server's backup job writes to."
  value       = cloudflare_r2_bucket.backups.name
}
