variable "domain" {
  type        = string
  description = "The apex domain that serves the redirects"

  validation {
    condition     = var.domain == lower(var.domain) && can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.domain))
    error_message = "Domain must be a lowercase DNS name."
  }
}

variable "backend_host" {
  type        = string
  description = "A safety backend required by Fastly; redirect-domain requests never reach it"
}

variable "redirects" {
  type = map(object({
    location       = string
    preserve_query = optional(bool, true)
    status         = optional(number, 307)
  }))
  description = "Map of exact request paths to redirect responses"

  validation {
    condition     = length(var.redirects) > 0
    error_message = "At least one redirect must be configured."
  }

  validation {
    condition = alltrue([
      for path in keys(var.redirects) :
      startswith(path, "/") && length(regexall("[?#]", path)) == 0
    ])
    error_message = "Redirect paths must start with / and cannot contain a query string or fragment."
  }

  validation {
    condition = alltrue([
      for redirect in values(var.redirects) :
      contains([301, 302, 303, 307, 308], redirect.status)
    ])
    error_message = "Redirect status must be one of 301, 302, 303, 307, or 308."
  }

  validation {
    condition = alltrue([
      for redirect in values(var.redirects) :
      startswith(redirect.location, "https://") && (
        !redirect.preserve_query || length(regexall("[?#]", redirect.location)) == 0
      )
    ])
    error_message = "Redirect locations must use HTTPS and cannot contain a query or fragment when preserve_query is enabled."
  }
}

locals {
  managed_dns_challenge = one([
    for challenge in fastly_tls_subscription.main.managed_dns_challenges :
    challenge if challenge.record_name == "_acme-challenge.${var.domain}"
  ])
  fastly_apex_addresses = sort([
    for record in data.fastly_tls_configuration.default_tls.dns_records :
    record.record_value if record.record_type == "A"
  ])
}

resource "fastly_service_vcl" "redirects" {
  activate = true
  comment  = "Managed by Tofu"
  http3    = true
  name     = "Redirects for ${var.domain}"
  stage    = false

  domain {
    name = var.domain
  }

  # Fastly VCL services require a backend even though every request for the
  # configured domain terminates in vcl_recv without reaching an origin.
  backend {
    address           = var.backend_host
    name              = "Unused safety backend"
    port              = 443
    ssl_cert_hostname = var.backend_host
    ssl_sni_hostname  = var.backend_host
    use_ssl           = true
  }

  snippet {
    name     = "Path redirects (tables)"
    type     = "init"
    priority = 100
    content = join("\n", concat(
      ["table redirect_locations STRING {"],
      [for path, redirect in var.redirects : "  ${jsonencode(path)}: ${jsonencode(redirect.location)},"],
      ["}", "", "table redirect_statuses INTEGER {"],
      [for path, redirect in var.redirects : "  ${jsonencode(path)}: ${redirect.status},"],
      ["}", "", "table redirect_preserve_queries BOOL {"],
      [for path, redirect in var.redirects : "  ${jsonencode(path)}: ${redirect.preserve_query},"],
      ["}"],
    ))
  }

  snippet {
    name     = "Path redirects (recv)"
    type     = "recv"
    priority = 100
    content  = <<-VCL
      if (std.tolower(req.http.host) == ${jsonencode(var.domain)}) {
        if (table.contains(redirect_locations, req.url.path)) {
          error 618 "path-redirect";
        }
        error 619 "redirect-not-found";
      }
    VCL
  }

  snippet {
    name     = "Path redirects (error)"
    type     = "error"
    priority = 100
    content  = <<-VCL
      if (obj.status == 618 && obj.response == "path-redirect") {
        set obj.status = table.lookup_integer(redirect_statuses, req.url.path, 307);
        if (obj.status == 301) {
          set obj.response = "Moved Permanently";
        } else if (obj.status == 302) {
          set obj.response = "Found";
        } else if (obj.status == 303) {
          set obj.response = "See Other";
        } else if (obj.status == 307) {
          set obj.response = "Temporary Redirect";
        } else {
          set obj.response = "Permanent Redirect";
        }
        set obj.http.Location = table.lookup(redirect_locations, req.url.path, "");
        if (table.lookup_bool(redirect_preserve_queries, req.url.path, false) && std.strlen(req.url.qs) > 0) {
          set obj.http.Location = obj.http.Location + "?" + req.url.qs;
        }
        synthetic "";
        return (deliver);
      }

      if (obj.status == 619 && obj.response == "redirect-not-found") {
        set obj.status = 404;
        set obj.response = "Not Found";
        set obj.http.Content-Type = "text/plain; charset=utf-8";
        synthetic "Not Found";
        return (deliver);
      }
    VCL
  }
}

resource "fastly_tls_subscription" "main" {
  depends_on            = [fastly_service_vcl.redirects]
  domains               = [var.domain]
  certificate_authority = "certainly"
}

resource "porkbun_dns_record" "domain_validation" {
  depends_on = [fastly_tls_subscription.main]

  domain    = var.domain
  subdomain = "_acme-challenge"
  type      = local.managed_dns_challenge.record_type
  content   = local.managed_dns_challenge.record_value
  ttl       = 600
  prio      = 10
}

resource "fastly_tls_subscription_validation" "main" {
  subscription_id = fastly_tls_subscription.main.id
  depends_on      = [porkbun_dns_record.domain_validation]
}

data "fastly_tls_configuration" "default_tls" {
  default    = true
  depends_on = [fastly_tls_subscription_validation.main]
}

resource "porkbun_dns_record" "apex" {
  # Fastly publishes exactly four global A records for apex domains. Keeping
  # these instance keys static allows the first plan to succeed even though
  # their values are unavailable until TLS validation completes.
  for_each = { for index in range(4) : tostring(index) => index }

  domain    = var.domain
  subdomain = ""
  type      = "A"
  content   = local.fastly_apex_addresses[each.value]
  ttl       = 600

  lifecycle {
    precondition {
      condition     = length(local.fastly_apex_addresses) == 4
      error_message = "Fastly's default TLS configuration must provide exactly four apex A records."
    }
  }
}
