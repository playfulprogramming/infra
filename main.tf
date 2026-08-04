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
  }
}
