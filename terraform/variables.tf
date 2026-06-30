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
  description = "VCN CIDR for the benchmark lab. The default subnet plan assumes this is at least a /16."
  type        = string
  default     = "10.77.0.0/16"
}

variable "benchmark_shapes" {
  description = "Shape matrix to deploy. Each shape gets its own fw client/target and XDP client/target pair."
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
}

variable "image_operating_system" {
  description = "OCI image operating system name."
  type        = string
  default     = "Canonical Ubuntu"
}

variable "image_operating_system_version" {
  description = "OCI image operating system version."
  type        = string
  default     = "24.04"
}

variable "assign_public_ip" {
  description = "Assign public IPs to all instances so Ansible can SSH directly. For a private-only lab, replace this with a bastion/VPN pattern."
  type        = bool
  default     = true
}
