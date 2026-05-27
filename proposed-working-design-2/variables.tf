variable "resource_group_name" {
  type    = string
  default = "rg-clientm-lab"
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "name_prefix" {
  type    = string
  default = "clientm-lab"
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
  description = "Trust subnet — Internal LB frontend + NVA trust NICs"
  type        = string
  default     = "10.0.2.0/24"
}

variable "subnet_dmz_cidr" {
  description = "DMZ subnet — NVA DMZ NICs + webserver"
  type        = string
  default     = "10.0.3.0/24"
}

variable "subnet_firewall_cidr" {
  description = "Azure Firewall subnet (subnet name is forced to AzureFirewallSubnet; must be /26 or larger)"
  type        = string
  default     = "10.0.4.0/26"
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
  description = "Your public IP /32 — allowed to SSH to NVA management IPs"
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

# Internal LB frontend (App GW points here as its backend pool member)
variable "internal_lb_frontend_ip" {
  type    = string
  default = "10.0.2.4"
}

# NVA static IPs
variable "nva1_trust_ip" {
  type    = string
  default = "10.0.2.10"
}

variable "nva2_trust_ip" {
  type    = string
  default = "10.0.2.11"
}

variable "nva1_dmz_ip" {
  type    = string
  default = "10.0.3.20"
}

variable "nva2_dmz_ip" {
  type    = string
  default = "10.0.3.21"
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
    "Basic" is cheaper (~$0.395/hr) but additionally requires a separate
    management public IP + management ip_configuration, which this lab does
    not wire up — switch with care. See README cost section.
  EOT
  type        = string
  default     = "Standard"
}

variable "egress_allowed_fqdns" {
  description = "FQDNs the webserver is allowed to reach outbound (Azure Firewall application rule allow-list)."
  type        = list(string)
  default = [
    "*.ubuntu.com",    # apt
    "*.canonical.com", # apt / snap
    "azure.archive.ubuntu.com",
    "security.ubuntu.com",
    "api.ipify.org", # lab egress test: echoes the SNAT (firewall) IP
  ]
}
