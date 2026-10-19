# The resources that became one per domain or per hostname (projects.yml,
# domains) when a second domain became possible, from their old addresses to
# the new ones: the state keeps every one of them, so nothing is recreated.
# Once applied they do nothing, and can go in any later PR.

moved {
  from = cloudflare_dns_record.a["server"]
  to   = cloudflare_dns_record.a["server.abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.a["status"]
  to   = cloudflare_dns_record.a["status.abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.a["@"]
  to   = cloudflare_dns_record.a["abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.a["www"]
  to   = cloudflare_dns_record.a["www.abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.a["cuanto-cuesta"]
  to   = cloudflare_dns_record.a["cuanto-cuesta.abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.a["epb"]
  to   = cloudflare_dns_record.a["epb.abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.aaaa["server"]
  to   = cloudflare_dns_record.aaaa["server.abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.aaaa["status"]
  to   = cloudflare_dns_record.aaaa["status.abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.aaaa["@"]
  to   = cloudflare_dns_record.aaaa["abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.aaaa["www"]
  to   = cloudflare_dns_record.aaaa["www.abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.aaaa["cuanto-cuesta"]
  to   = cloudflare_dns_record.aaaa["cuanto-cuesta.abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.aaaa["epb"]
  to   = cloudflare_dns_record.aaaa["epb.abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.caa["letsencrypt"]
  to   = cloudflare_dns_record.caa["abrunacci.dev/letsencrypt"]
}

moved {
  from = cloudflare_dns_record.caa["zerossl"]
  to   = cloudflare_dns_record.caa["abrunacci.dev/zerossl"]
}

moved {
  from = cloudflare_dns_record.caa["nowildcard"]
  to   = cloudflare_dns_record.caa["abrunacci.dev/nowildcard"]
}

moved {
  from = cloudflare_universal_ssl_setting.this
  to   = cloudflare_universal_ssl_setting.this["abrunacci.dev"]
}

moved {
  from = cloudflare_zone_dnssec.this
  to   = cloudflare_zone_dnssec.this["abrunacci.dev"]
}

moved {
  from = cloudflare_email_routing_dns.this
  to   = cloudflare_email_routing_dns.this["abrunacci.dev"]
}

moved {
  from = cloudflare_email_routing_rule.forward["hello"]
  to   = cloudflare_email_routing_rule.forward["hello@abrunacci.dev"]
}

moved {
  from = cloudflare_email_routing_rule.forward["postmaster"]
  to   = cloudflare_email_routing_rule.forward["postmaster@abrunacci.dev"]
}

moved {
  from = cloudflare_email_routing_rule.forward["abuse"]
  to   = cloudflare_email_routing_rule.forward["abuse@abrunacci.dev"]
}

moved {
  from = cloudflare_email_routing_catch_all.this
  to   = cloudflare_email_routing_catch_all.this["abrunacci.dev"]
}

moved {
  from = cloudflare_dns_record.dmarc
  to   = cloudflare_dns_record.dmarc["abrunacci.dev"]
}
