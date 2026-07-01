variable "tenancy_ocid" {
  description = "OCI tenancy OCID."
  type        = string
}

variable "user_ocid" {
  description = "OCI user OCID used by the Terraform API key."
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint for the OCI API key."
  type        = string
}

variable "private_key_path" {
  description = "Path to the OCI API private key PEM."
  type        = string
}

variable "region" {
  description = "OCI region, for example us-ashburn-1."
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment OCID where test infrastructure will be created."
  type        = string
}

variable "availability_domain" {
  description = "Optional AD name. Leave empty to use the first AD in the compartment."
  type        = string
  default     = ""
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key installed on the instances."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key used by Ansible. This is only written into inventory.ini."
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH to the benchmark instances. Set this to your public IP /32."
  type        = string
  default     = "0.0.0.0/0"
}

variable "vcn_cidr" {
  description = "Private address pool divided into one /20 VCN and one /24 subnet per shape/mode lab. Keep the default /16 unless you also revise the CIDR plan."
  type        = string
  default     = "10.77.0.0/16"

  validation {
    condition     = can(cidrhost(var.vcn_cidr, 0)) && !strcontains(var.vcn_cidr, ":") && can(regex("/16$", var.vcn_cidr))
    error_message = "vcn_cidr must be an IPv4 /16 so it can supply sixteen /20 lab VCNs with /24 subnets; for example, 10.77.0.0/16."
  }
}

variable "benchmark_shapes" {
  description = "Shape matrix to deploy. Each shape gets four isolated mode labs, each with its own client, target, VCN, and subnet."
  type = map(object({
    shape         = string
    ocpus         = number
    memory_in_gbs = number
  }))

  default = {
    e6 = {
      shape         = "VM.Standard.E6.Flex"
      ocpus         = 10
      memory_in_gbs = 80
    }
    e6_ax = {
      shape         = "VM.Standard.E6.Ax.Flex"
      ocpus         = 10
      memory_in_gbs = 80
    }
  }

  validation {
    condition = alltrue([
      for _, cfg in var.benchmark_shapes : cfg.ocpus == 10 && cfg.memory_in_gbs == 80
    ])
    error_message = "This benchmark profile is locked to 10 OCPUs and 80 GB RAM per instance. Change the validation if you intentionally want other sizes."
  }

  validation {
    condition     = length(var.benchmark_shapes) <= 4
    error_message = "The isolated /16 network plan supports at most four shapes (four mode-specific VCNs per shape)."
  }
}

variable "oracle_linux_major_version" {
  description = "Oracle Linux major platform-image family. The newest compatible point/build image in this family is selected per shape."
  type        = string
  default     = "10"

  validation {
    condition     = can(regex("^[0-9]+$", var.oracle_linux_major_version))
    error_message = "oracle_linux_major_version must be a numeric major release such as 10."
  }
}

variable "assign_public_ip" {
  description = "Assign public IPs to all instances so Ansible can SSH directly. For a private-only lab, replace this with a bastion/VPN pattern."
  type        = bool
  default     = true
}
