terraform {
  required_providers {
    fastly = {
      source  = "fastly/fastly"
      version = ">=1.0.0"
    }
    porkbun = {
      source  = "marcfrederick/porkbun"
      version = ">=1.3.1"
    }
  }
}
