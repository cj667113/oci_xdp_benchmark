data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

data "oci_core_images" "ubuntu" {
  for_each                 = var.benchmark_shapes
  compartment_id           = var.compartment_ocid
  operating_system         = var.image_operating_system
  operating_system_version = var.image_operating_system_version
  shape                    = each.value.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  ad_name = var.availability_domain != "" ? var.availability_domain : data.oci_identity_availability_domains.ads.availability_domains[0].name

  image_ids = {
    for shape_key, images in data.oci_core_images.ubuntu : shape_key => images.images[0].id
  }

  environment_types = {
    fw = {
      display = "firewall"
    }
    xdp = {
      display = "xdp"
    }
  }

  subnets = merge([
    for shape_key, _profile in var.benchmark_shapes : {
      for env_key, _env in local.environment_types : "${shape_key}_${env_key}" => {
        shape_key    = shape_key
        env          = env_key
        display_name = "xdpbench-${shape_key}-${env_key}-subnet"
        dns_label    = substr(replace("${shape_key}${env_key}", "_", ""), 0, 15)
        cidr_block   = cidrsubnet(var.vcn_cidr, 8, index(keys(var.benchmark_shapes), shape_key) * 2 + index(keys(local.environment_types), env_key))
      }
    }
  ]...)

  role_templates = {
    fw_client = {
      subnet_key  = "fw"
      role        = "client"
      bench_env   = "fw"
      peer_suffix = "fw_target"
    }
    fw_target = {
      subnet_key  = "fw"
      role        = "target"
      bench_env   = "fw"
      peer_suffix = "fw_client"
    }
    xdp_client = {
      subnet_key  = "xdp"
      role        = "client"
      bench_env   = "xdp"
      peer_suffix = "xdp_target"
    }
    xdp_target = {
      subnet_key  = "xdp"
      role        = "target"
      bench_env   = "xdp"
      peer_suffix = "xdp_client"
    }
  }

  nodes = merge([
    for shape_key, profile in var.benchmark_shapes : {
      for node_key, template in local.role_templates : "${shape_key}_${node_key}" => merge(template, {
        shape_key     = shape_key
        shape         = profile.shape
        ocpus         = profile.ocpus
        memory_in_gbs = profile.memory_in_gbs
        display_name  = "xdpbench-${shape_key}-${replace(node_key, "_", "-")}"
        peer_name     = "${shape_key}_${template.peer_suffix}"
      })
    }
  ]...)
}

resource "oci_core_vcn" "bench" {
  compartment_id = var.compartment_ocid
  cidr_block     = var.vcn_cidr
  display_name   = "xdpbench-vcn"
  dns_label      = "xdpbench"
}

resource "oci_core_internet_gateway" "bench" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.bench.id
  display_name   = "xdpbench-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.bench.id
  display_name   = "xdpbench-public-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.bench.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

resource "oci_core_security_list" "minimal" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.bench.id
  display_name   = "xdpbench-minimal-sl"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_network_security_group" "bench" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.bench.id
  display_name   = "xdpbench-nsg"
}

resource "oci_core_network_security_group_security_rule" "ssh" {
  network_security_group_id = oci_core_network_security_group.bench.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.allowed_ssh_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "internal_all" {
  network_security_group_id = oci_core_network_security_group.bench.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = var.vcn_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false
}

resource "oci_core_network_security_group_security_rule" "egress_all" {
  network_security_group_id = oci_core_network_security_group.bench.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}

resource "oci_core_subnet" "env" {
  for_each                   = local.subnets
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.bench.id
  cidr_block                 = each.value.cidr_block
  display_name               = each.value.display_name
  dns_label                  = each.value.dns_label
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.minimal.id]
  prohibit_public_ip_on_vnic = !var.assign_public_ip
}

resource "oci_core_instance" "nodes" {
  for_each             = local.nodes
  compartment_id       = var.compartment_ocid
  availability_domain  = local.ad_name
  display_name         = each.value.display_name
  shape                = each.value.shape
  preserve_boot_volume = false

  shape_config {
    ocpus         = each.value.ocpus
    memory_in_gbs = each.value.memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.env["${each.value.shape_key}_${each.value.subnet_key}"].id
    assign_public_ip = var.assign_public_ip
    nsg_ids          = [oci_core_network_security_group.bench.id]
    display_name     = "${each.value.display_name}-vnic"
    hostname_label   = replace(each.key, "_", "-")
  }

  source_details {
    source_type = "image"
    source_id   = local.image_ids[each.value.shape_key]
  }

  metadata = {
    ssh_authorized_keys = file(var.ssh_public_key_path)
  }

  freeform_tags = {
    project = "xdpbench"
    shape   = each.value.shape_key
    env     = each.value.bench_env
    role    = each.value.role
  }
}

data "oci_core_vnic_attachments" "nodes" {
  for_each       = oci_core_instance.nodes
  compartment_id = var.compartment_ocid
  instance_id    = each.value.id
}

data "oci_core_vnic" "nodes" {
  for_each = data.oci_core_vnic_attachments.nodes
  vnic_id  = each.value.vnic_attachments[0].vnic_id
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../inventory.ini"
  content = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    ssh_private_key_path = var.ssh_private_key_path
    nodes                = data.oci_core_vnic.nodes
    node_meta            = local.nodes
    shape_keys           = keys(var.benchmark_shapes)
  })
}
