variable "resource_group_name" {
  type    = string
  default = "rg-clientm-lab-d6"
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "name_prefix" {
  type    = string
  default = "clientm-lab-d6"
}

variable "vnet_address_space" {
  type    = list(string)
  default = ["10.0.0.0/16"]
}

variable "subnet_appgw_cidr" {
  description = "Dedicated App Gateway subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "subnet_trust_cidr" {
  description = "Trust zone — NVA trust NIC (App Gateway backend)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "subnet_dmz_cidr" {
  description = "DMZ zone — NVA dmz NIC + webserver"
  type        = string
  default     = "10.0.3.0/24"
}

variable "subnet_untrust_cidr" {
  description = "Untrust zone — NVA untrust NIC (carries the management PIP; NVA's own outbound)"
  type        = string
  default     = "10.0.4.0/24"
}

variable "subnet_firewall_cidr" {
  description = "Azure Firewall subnet (forced name AzureFirewallSubnet; min /26)"
  type        = string
  default     = "10.0.5.0/26"
}

variable "subnet_test_cidr" {
  description = "In-VNet test client subnet — exercises the App Gateway PRIVATE frontend"
  type        = string
  default     = "10.0.6.0/24"
}

variable "appgw_private_ip" {
  description = "App Gateway PRIMARY private frontend IP (static, in snet-appgateway). This is design-6's intended front door."
  type        = string
  default     = "10.0.1.10"
}

variable "appgw_private_only" {
  description = <<-EOT
    true  = truly private-ONLY App Gateway (no public frontend at all).
            REQUIRES the subscription feature
            Microsoft.Network/EnableApplicationGatewayNetworkIsolation to be
            registered, or the apply fails with
            ApplicationGatewayFeatureCannotBeEnabledForSelectedSku on WAF_v2.
    false = private frontend is the primary front door, with a public frontend
            retained as a lab-reachability fallback. Deploys today on WAF_v2
            with no feature flag. This is the default.
  EOT
  type        = bool
  default     = false
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key for VM authentication"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "Your public IP /32 — locks SSH to the NVA's untrust management IP"
  type        = string
}

variable "tags" {
  type = map(string)
  default = {
    environment = "lab"
    project     = "clientm-network-troubleshoot"
    managed_by  = "terraform"
  }
}

variable "vm_size" {
  type    = string
  default = "Standard_B2s"
}

variable "disk_type" {
  type    = string
  default = "Standard_LRS"
}

variable "nva_trust_ip" {
  description = "NVA trust NIC static IP — App Gateway backend target"
  type        = string
  default     = "10.0.2.10"
}

variable "nva_dmz_ip" {
  description = "NVA dmz NIC static IP — webserver-facing"
  type        = string
  default     = "10.0.3.10"
}

variable "nva_untrust_ip" {
  description = "NVA untrust NIC static IP — carries the management PIP"
  type        = string
  default     = "10.0.4.10"
}

variable "webserver_ip" {
  type    = string
  default = "10.0.3.100"
}

variable "appgw_min_capacity" {
  type    = number
  default = 0
}

variable "appgw_max_capacity" {
  type    = number
  default = 2
}

# --- Azure Firewall (egress) ---

variable "firewall_sku_tier" {
  description = <<-EOT
    Azure Firewall tier: "Standard" (default, ~$912/mo) or "Premium".
    Basic is cheaper but additionally requires a separate management IP
    configuration that this design does not wire up.
  EOT
  type        = string
  default     = "Standard"
}

variable "egress_allowed_fqdns" {
  description = "FQDNs the webserver is allowed to reach outbound through Azure Firewall."
  type        = list(string)
  default = [
    "*.ubuntu.com",
    "*.canonical.com",
    "azure.archive.ubuntu.com",
    "security.ubuntu.com",
    "api.ipify.org", # used by validate-flows.sh to assert the SNAT IP
  ]
}
