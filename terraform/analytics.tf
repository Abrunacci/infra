# Cloudflare Web Analytics for EPB Stock's landing (epb-landing in
# projects.yml): visits counted by a script on the page, with no cookies, so
# the page needs no consent banner. The records are not proxied, so Cloudflare
# cannot inject the script itself (auto_install): the landing's build loads it
# with the site token (EPB_Stock's repository variable LANDING_CF_BEACON_TOKEN).
resource "cloudflare_web_analytics_site" "epb_landing" {
  account_id   = var.cloudflare_account_id
  host         = "epbstock.com.ar"
  auto_install = false
}
