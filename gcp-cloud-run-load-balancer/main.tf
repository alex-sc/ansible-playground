variable "gcp_project" {
  type = string
  default = "alex-sc-test"
}

variable "dns_zone" {
  type = string
  default = "gcp.alex-sc.com"
}

variable "dns_domain" {
  type = string
  default = "cloudrun.gcp.alex-sc.com"
}

variable "docker_image_url" {
  type = string
  default = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "gcp_region" {
  type = string
  default = "us-central1"
}

variable "base_name" {
  type = string
  default = "gcp-docker"
}

# Init provider
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

# Init provider
provider "google-beta" {
  project = var.gcp_project
  region  = var.gcp_region
}

# DNS Zone (imported)
resource "google_dns_managed_zone" "default" {
  name        = replace(var.dns_zone, ".", "-")
  dns_name    = "${var.dns_zone}."
}

import {
  id = "projects/alex-sc-test/managedZones/gcp-alex-sc-com"
  to = google_dns_managed_zone.default
}

# DNS record
resource "google_dns_record_set" "default" {
  managed_zone = google_dns_managed_zone.default.name

  name    = "${var.dns_domain}."
  type    = "A"
  rrdatas = [google_compute_global_address.default.address]
  ttl     = 300
}

# Cloud run
resource "google_cloud_run_v2_service" "default" {
  name     = "${var.base_name}-cloud-run"
  location = var.gcp_region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello"
    }
  }
}

# Grant public access to cloud run
resource "google_cloud_run_service_iam_member" "member" {
  location = var.gcp_region
  project  = var.gcp_project
  service  = google_cloud_run_v2_service.default.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Network endpoint group (NEG)
resource "google_compute_region_network_endpoint_group" "cloudrun_neg" {
  provider              = google-beta
  name                  = "${var.base_name}-neg"
  network_endpoint_type = "SERVERLESS"
  region                = var.gcp_region
  cloud_run {
    service = google_cloud_run_v2_service.default.name
  }
}

# Backend service for NEG
resource "google_compute_backend_service" "default" {
  name      = "${var.base_name}-backend"

  protocol  = "HTTP"
  port_name = "http"
  timeout_sec = 30

  backend {
    group = google_compute_region_network_endpoint_group.cloudrun_neg.id
  }
}

# Reserve IP address for load balancer
resource "google_compute_global_address" "default" {
  name = "${var.base_name}-ip"
}

# Create url map
resource "google_compute_url_map" "default" {
  name = "${var.base_name}-lb"

  default_service = google_compute_backend_service.default.id

  host_rule {
    hosts        = [var.dns_domain]
    path_matcher = "allpaths"
  }

  path_matcher {
    name            = "allpaths"
    default_service = google_compute_backend_service.default.id

    path_rule {
      paths   = ["/*"]
      service = google_compute_backend_service.default.id
    }
  }
}

# Create SSL certificate
# It may take a while (5-10 and more) minutes to (re)created the certificate
# Additionally, give it some time for TLS setup - you might get TLS errors until it stabilizes
# Visit the "Classic Certificates" list here
# https://console.cloud.google.com/security/ccm/list/certificates
resource "google_compute_managed_ssl_certificate" "default" {
  name = "${var.base_name}-certificate"

  managed {
    domains = [var.dns_domain]
  }
}

# Create HTTPS proxy
resource "google_compute_target_https_proxy" "default" {
  name             = "${var.base_name}-proxy"
  url_map          = google_compute_url_map.default.id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.default.id
  ]
  # TODO: adjust ssl_policy? The default one supports TLS 1.0 and 1.1, which could be disabled
  # https://console.cloud.google.com/net-services/ssl-policies/list
}

# Create forwarding rule
resource "google_compute_global_forwarding_rule" "default" {
  name                  = "${var.base_name}-lb-forwarding-rule"
  port_range            = "443"
  target                = google_compute_target_https_proxy.default.id
  ip_address            = google_compute_global_address.default.id
}

# HTTP to HTTPs redirect
resource "google_compute_url_map" "https_redirect" {
  name            = "${var.base_name}-https-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "https_redirect" {
  name    = "${var.base_name}-http-proxy"
  url_map = google_compute_url_map.https_redirect.id
}

resource "google_compute_global_forwarding_rule" "https_redirect" {
  name       = "${var.base_name}-lb-http"

  target     = google_compute_target_http_proxy.https_redirect.id
  port_range = "80"
  ip_address = google_compute_global_address.default.address
}
