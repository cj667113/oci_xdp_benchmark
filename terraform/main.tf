data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_ocid
}

data "oci_core_images" "oracle_linux" {
  for_each         = var.benchmark_shapes
  compartment_id   = var.compartment_ocid
  operating_system = "Oracle Linux"
  shape            = each.value.shape
  state            = "AVAILABLE"
  sort_by          = "TIMECREATED"
  sort_order       = "DESC"
}

locals {
  ad_name = var.availability_domain != "" ? var.availability_domain : data.oci_identity_availability_domains.ads.availability_domains[0].name

  # OCI returns several image families whose operating_system is "Oracle Linux"
  # (including Autonomous, Minimal, and GPU images). Keep only the standard OL
  # platform image for the requested major release. The shape filter above keeps
  # selection compatible with each shape (including architecture when Arm shapes
  # are added to the matrix).
  oracle_linux_image_candidates = {
    for shape_key, result in data.oci_core_images.oracle_linux : shape_key => [
      for image in result.images : image
      if startswith(image.display_name, "Oracle-Linux-${var.oracle_linux_major_version}.")
      && !strcontains(lower(image.display_name), "minimal")
      && !strcontains(lower(image.display_name), "gpu")
      && !strcontains(lower(image.display_name), "developer")
    ]
  }

  image_ids = {
    for shape_key, images in local.oracle_linux_image_candidates : shape_key => try(images[0].id, "")
  }

  image_names = {
    for shape_key, images in local.oracle_linux_image_candidates : shape_key => try(images[0].display_name, "")
  }

  # Every benchmark mode gets a dedicated client, target, VCN, and subnet.
  # Underscores are used in Terraform/Ansible keys; test_mode keeps the labels
  # written into result bundles.
  benchmark_modes = {
    iptables = {
      bench_env     = "fw"
      test_mode     = "iptables"
      firewall_mode = "iptables"
      xdp_mode      = ""
    }
    nftables = {
      bench_env     = "fw"
      test_mode     = "nftables"
      firewall_mode = "nftables"
      xdp_mode      = ""
    }
    xdp_generic = {
      bench_env     = "xdp"
      test_mode     = "xdp-generic"
      firewall_mode = ""
      xdp_mode      = "xdpgeneric"
    }
    xdp_native = {
      bench_env     = "xdp"
      test_mode     = "xdp-native"
      firewall_mode = ""
      xdp_mode      = "xdpdrv"
    }
  }

  labs = merge([
    for shape_key, profile in var.benchmark_shapes : {
      for mode_key, mode in local.benchmark_modes : "${shape_key}_${mode_key}" => merge(mode, {
        lab_key       = "${shape_key}_${mode_key}"
        mode_key      = mode_key
        shape_key     = shape_key
        shape         = profile.shape
        ocpus         = profile.ocpus
        memory_in_gbs = profile.memory_in_gbs
        image_name    = local.image_names[shape_key]
        vcn_cidr = cidrsubnet(
          var.vcn_cidr,
          4,
          index(keys(var.benchmark_shapes), shape_key) * length(local.benchmark_modes) + index(keys(local.benchmark_modes), mode_key)
        )
        subnet_cidr = cidrsubnet(
          cidrsubnet(
            var.vcn_cidr,
            4,
            index(keys(var.benchmark_shapes), shape_key) * length(local.benchmark_modes) + index(keys(local.benchmark_modes), mode_key)
          ),
          4,
          0
        )
      })
    }
  ]...)

  nodes = merge([
    for lab_key, lab in local.labs : {
      "${lab_key}_client" = merge(lab, {
        role         = "client"
        display_name = "xdpbench-${replace(lab_key, "_", "-")}-client"
        peer_name    = "${lab_key}_target"
      })
      "${lab_key}_target" = merge(lab, {
        role         = "target"
        display_name = "xdpbench-${replace(lab_key, "_", "-")}-target"
        peer_name    = "${lab_key}_client"
      })
    }
  ]...)
}

resource "oci_core_vcn" "bench" {
  for_each       = local.labs
  compartment_id = var.compartment_ocid
  cidr_block     = each.value.vcn_cidr
  display_name   = "xdpbench-${replace(each.key, "_", "-")}-vcn"
  dns_label      = substr(replace(each.key, "_", ""), 0, 15)
}

resource "oci_core_internet_gateway" "bench" {
  for_each       = local.labs
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.bench[each.key].id
  display_name   = "xdpbench-${replace(each.key, "_", "-")}-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  for_each       = local.labs
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.bench[each.key].id
  display_name   = "xdpbench-${replace(each.key, "_", "-")}-public-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.bench[each.key].id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

resource "oci_core_security_list" "minimal" {
  for_each       = local.labs
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.bench[each.key].id
  display_name   = "xdpbench-${replace(each.key, "_", "-")}-minimal-sl"

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_network_security_group" "bench" {
  for_each       = local.labs
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.bench[each.key].id
  display_name   = "xdpbench-${replace(each.key, "_", "-")}-nsg"
}

resource "oci_core_network_security_group_security_rule" "ssh" {
  for_each                  = local.labs
  network_security_group_id = oci_core_network_security_group.bench[each.key].id
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
  for_each                  = local.labs
  network_security_group_id = oci_core_network_security_group.bench[each.key].id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = each.value.subnet_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false
}

resource "oci_core_network_security_group_security_rule" "egress_all" {
  for_each                  = local.labs
  network_security_group_id = oci_core_network_security_group.bench[each.key].id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}

resource "oci_core_subnet" "env" {
  for_each                   = local.labs
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.bench[each.key].id
  cidr_block                 = each.value.subnet_cidr
  display_name               = "xdpbench-${replace(each.key, "_", "-")}-subnet"
  dns_label                  = "bench"
  route_table_id             = oci_core_route_table.public[each.key].id
  security_list_ids          = [oci_core_security_list.minimal[each.key].id]
  prohibit_public_ip_on_vnic = !var.assign_public_ip
}

resource "oci_core_instance" "nodes" {
  for_each             = local.nodes
  compartment_id       = var.compartment_ocid
  availability_domain  = local.ad_name
  display_name         = each.value.display_name
  shape                = each.value.shape
  preserve_boot_volume = false

  lifecycle {
    precondition {
      condition     = local.image_ids[each.value.shape_key] != ""
      error_message = "No standard Oracle Linux ${var.oracle_linux_major_version} platform image is available for shape ${each.value.shape}. Check that the shape and image family are offered in ${var.region}."
    }
  }

  shape_config {
    ocpus         = each.value.ocpus
    memory_in_gbs = each.value.memory_in_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.env[each.value.lab_key].id
    assign_public_ip = var.assign_public_ip
    nsg_ids          = [oci_core_network_security_group.bench[each.value.lab_key].id]
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
    mode    = each.value.test_mode
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
    ssh_private_key_path       = var.ssh_private_key_path
    nodes                      = data.oci_core_vnic.nodes
    node_meta                  = local.nodes
    shape_keys                 = keys(var.benchmark_shapes)
    mode_keys                  = keys(local.benchmark_modes)
    oracle_linux_major_version = var.oracle_linux_major_version
  })
}
