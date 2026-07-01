output "image_ids" {
  value = local.image_ids
}

output "image_names" {
  value = local.image_names
}

output "benchmark_shapes" {
  value = var.benchmark_shapes
}

output "lab_vcn_cidrs" {
  value = { for k, v in local.labs : k => v.vcn_cidr }
}

output "subnet_cidrs" {
  value = { for k, v in local.labs : k => v.subnet_cidr }
}

output "benchmark_labs" {
  value = {
    for k, v in local.labs : k => {
      shape       = v.shape
      test_mode   = v.test_mode
      vcn_cidr    = v.vcn_cidr
      subnet_cidr = v.subnet_cidr
    }
  }
}

output "instance_private_ips" {
  value = { for k, v in data.oci_core_vnic.nodes : k => v.private_ip_address }
}

output "instance_public_ips" {
  value = { for k, v in data.oci_core_vnic.nodes : k => v.public_ip_address }
}

output "ansible_inventory" {
  value = local_file.ansible_inventory.filename
}
