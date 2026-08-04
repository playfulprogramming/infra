provider "fastly" {
  api_key = var.fastly_api_key
}

provider "porkbun" {
  api_key        = var.porkbun_api_key
  secret_api_key = var.porkbun_secret_key
}

module "playful-web" {
  source  = "./modules/playful-web"
  domain  = var.playful_web_domain
  host    = var.playful_web_host
  noindex = var.env != "prod"

  subdomain_redirects = {
    www = {
      location     = "https://${var.playful_web_domain}"
      preserve_url = true
      status       = 301
    }
    discord = {
      location     = "https://discord.com/invite/FMcvc6T"
      preserve_url = false
      status       = 302
    }
    donate = {
      location     = "https://opencollective.com/playfulprogramming"
      preserve_url = false
      status       = 302
    }
  }
}

module "pfp-red" {
  count  = var.env == "prod" ? 1 : 0
  source = "./modules/redirect-domain"

  domain       = "pfp.red"
  backend_host = var.playful_web_host

  redirects = {
    "/" = {
      location       = "https://playfulprogramming.com/"
      preserve_query = true
      status         = 307
    }
    "/bootcamp" = {
      location       = "https://playfulprogramming.com/events/sacramento-bootcamp"
      preserve_query = true
      status         = 307
    }
    "/bootcamp/" = {
      location       = "https://playfulprogramming.com/events/sacramento-bootcamp"
      preserve_query = true
      status         = 307
    }
    "/book-club" = {
      location       = "https://playfulprogramming.com/events/book-club"
      preserve_query = true
      status         = 307
    }
    "/book-club/" = {
      location       = "https://playfulprogramming.com/events/book-club"
      preserve_query = true
      status         = 307
    }
  }
}
