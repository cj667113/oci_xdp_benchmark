output "image_ids" {
  value = local.image_ids
}

output "image_names" {
  value = local.image_names
}

output "benchmark_shapes" {
  value = var.benchmark_shapes
}

output "subnet_cidrs" {
  value = { for k, v in local.subnets : k => v.cidr_block }
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
