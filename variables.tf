variable "resource_group_name" {
  description = "Name of the resource group for all lab resources"
  type        = string
  default     = "rg-clientm-lab"
}

variable "location" {
  description = "Azure region to deploy into"
  type        = string
  default     = "eastus"
}

variable "name_prefix" {
  description = "Prefix used in resource names (e.g. vnet-<prefix>)"
  type        = string
  default     = "clientm-lab"
}

variable "vnet_address_space" {
  description = "Address space for the firewall transit VNet (NVAs + webserver)"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "vnet_appgw_address_space" {
  description = "Address space for the App Gateway VNet (separate from firewall transit VNet)"
  type        = list(string)
  default     = ["10.1.0.0/16"]
}

variable "subnet_external_cidr" {
  description = "CIDR for the external (front LB / NVA external) subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "subnet_internal_cidr" {
  description = "CIDR for the internal (back LB / NVA internal) subnet"
  type        = string
  default     = "10.0.4.0/24"
}

variable "subnet_dmz_cidr" {
  description = "CIDR for the DMZ subnet (NVA DMZ NICs + webserver)"
  type        = string
  default     = "10.0.3.0/24"
}

variable "subnet_appgw_cidr" {
  description = "CIDR for the dedicated Application Gateway subnet (in the App GW VNet)"
  type        = string
  default     = "10.1.1.0/24"
}

variable "admin_username" {
  description = "Admin username for all VMs"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key for VM authentication"
  type        = string
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    environment = "lab"
    project     = "clientm-network-troubleshoot"
    managed_by  = "terraform"
  }
}

variable "vm_size" {
  description = "Azure VM size for NVA and webserver VMs"
  type        = string
  default     = "Standard_B2s"
}

variable "disk_type" {
  description = "OS disk storage account type"
  type        = string
  default     = "Standard_LRS"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to VMs (your public IP /32)"
  type        = string
}

variable "webserver_ip" {
  description = "Static private IP for the webserver in the DMZ subnet (10.0.3.0/24)"
  type        = string
  default     = "10.0.3.100"
}

variable "nva1_external_ip" {
  description = "Static private IP for NVA1 external NIC in snet-external (10.0.2.0/24)"
  type        = string
  default     = "10.0.2.10"
}

variable "nva2_external_ip" {
  description = "Static private IP for NVA2 external NIC in snet-external (10.0.2.0/24)"
  type        = string
  default     = "10.0.2.11"
}

variable "nva1_internal_ip" {
  description = "Static private IP for NVA1 internal NIC in snet-internal (10.0.4.0/24)"
  type        = string
  default     = "10.0.4.10"
}

variable "nva2_internal_ip" {
  description = "Static private IP for NVA2 internal NIC in snet-internal (10.0.4.0/24)"
  type        = string
  default     = "10.0.4.11"
}

variable "nva1_dmz_ip" {
  description = "Static private IP for NVA1 DMZ NIC in snet-dmz (10.0.3.0/24)"
  type        = string
  default     = "10.0.3.20"
}

variable "nva2_dmz_ip" {
  description = "Static private IP for NVA2 DMZ NIC in snet-dmz (10.0.3.0/24)"
  type        = string
  default     = "10.0.3.21"
}

variable "internal_lb_frontend_ip" {
  description = "Static private IP for the back LB internal frontend in snet-internal (10.0.4.0/24)"
  type        = string
  default     = "10.0.4.4"
}

variable "dmz_lb_frontend_ip" {
  description = "Static private IP for the back LB DMZ frontend in snet-dmz (10.0.3.0/24)"
  type        = string
  default     = "10.0.3.10"
}

variable "appgw_private_ip" {
  description = "Static private IP for the App Gateway private frontend in snet-appgateway (10.1.1.0/24)"
  type        = string
  default     = "10.1.1.10"
}

variable "appgw_min_capacity" {
  description = "App Gateway autoscale minimum capacity (0 = cheapest idle cost)"
  type        = number
  default     = 0
}

variable "appgw_max_capacity" {
  description = "App Gateway autoscale maximum capacity"
  type        = number
  default     = 2
}
