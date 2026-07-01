# OCI iptables/nftables vs Generic/Native XDP Benchmark Lab

This lab provisions independent OCI benchmark pairs for multiple OCI shapes and runs a four-mode packet-filter performance matrix:

1. `iptables`
2. `nftables`
3. `xdp-generic`
4. `xdp-native`

All instances use the newest standard Oracle Linux 10 OCI platform image that
is compatible with their shape. Terraform performs image discovery per shape
rather than relying on a hard-coded image OCID. E6 and E6.Ax (AMD Acceleron)
are both x86_64; a true Arm shape added later would resolve its aarch64 image.

Each shape now receives four isolated labs. A lab has its own client, target,
VCN, subnet, internet gateway, route table, security list, and network security
group; no benchmark mode reuses another mode's instances or private network.

The default Terraform shape matrix is:

| Shape key | OCI shape | OCPUs/node | RAM/node | Isolated labs | Nodes |
|---|---:|---:|---:|---:|---:|
| `e6` | `VM.Standard.E6.Flex` | 10 | 80 GB | 4 | 8 |
| `e6_ax` | `VM.Standard.E6.Ax.Flex` | 10 | 80 GB | 4 | 8 |

That is 16 instances and eight isolated VCN/subnet pairs by default. Node names
make the ownership explicit, for example:

- `e6_iptables_client` -> `e6_iptables_target`
- `e6_nftables_client` -> `e6_nftables_target`
- `e6_xdp_generic_client` -> `e6_xdp_generic_target`
- `e6_xdp_native_client` -> `e6_xdp_native_target`

The benchmark collects:

- ICMP latency: min/avg/max/mdev and packet loss
- TCP forward and reverse throughput with iperf3 JSON
- UDP throughput and jitter
- Small-packet UDP packets per second estimate
- Linux link, qdisc, and nstat counters before/after each run
- Requested and selected XDP mode, ELF section, target driver, and target MTU

The Linux egress cap is set to `10gbit` with `tc`, so the test has a consistent maximum bandwidth cap. The shape config is also locked to 10 OCPUs and 80 GB RAM per instance in Terraform validation.

## Prerequisites

The control host needs:

- Terraform 1.6 or newer
- Ansible Core 2.13 or newer
- Python 3
- Matplotlib for PNG generation (`python3 -m pip install matplotlib`)
- An OCI API signing key and the tenancy, user, fingerprint, region, and
  compartment values used by the OCI Terraform provider
- An SSH key pair for the generated Oracle Linux instances

Run Ansible commands from the `ansible/` directory so the repository's
`ansible.cfg` is loaded. It uses the built-in default callback with YAML result
formatting; the removed `community.general.yaml` callback is not required.

The default deployment creates 16 public instances totaling 160 OCPUs and
1,280 GB of RAM, plus eight VCNs, 16 public IPv4 addresses, and related network
resources. Confirm E6/E6.Ax availability, service limits, and expected OCI
cost before applying. The instances also need outbound package-repository
access during provisioning.

## 1. Configure Terraform

From the repository root:

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars
```

Set at minimum:

- `tenancy_ocid`
- `user_ocid`
- `fingerprint`
- `private_key_path`
- `region`
- `compartment_ocid`
- `allowed_ssh_cidr`

Also verify `ssh_public_key_path` and `ssh_private_key_path` if your SSH keys
are not the default `~/.ssh/id_rsa.pub` and `~/.ssh/id_rsa` files.

Strong recommendation: set `allowed_ssh_cidr` to your workstation public IP `/32`.

The default `oracle_linux_major_version = "10"` selects the newest compatible
Oracle Linux 10 point/build image available in the configured OCI region.

The default `vcn_cidr = "10.77.0.0/16"` is an address pool. Terraform divides
it into one non-overlapping `/20` VCN and one `/24` subnet for each shape/mode
lab. The current plan supports up to four shapes.

Default shape matrix:

```hcl
benchmark_shapes = {
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
```

If you also want to keep the old E4 baseline, uncomment the `e4` block in `terraform.tfvars.example` and copy it into `terraform.tfvars`.

## 2. Provision OCI infrastructure

If this state was created with the previous shared `fw` and `xdp` topology,
`terraform plan` will show the old eight instances and shared network being
replaced by the new 16-instance, eight-VCN topology. Review that replacement
before applying; result bundles under `results/` are local and unaffected.

```bash
terraform init
terraform plan
terraform apply
```

Terraform writes `../inventory.ini` for Ansible.

Oracle Linux platform images use the `opc` SSH account; the generated inventory
sets this automatically. Ansible enables `ol10_codeready_builder`, installs the
DNF-based benchmark/eBPF toolchain, and disables `firewalld` before managing
the benchmark's nftables and iptables-nft rules directly.

Expected generated inventory groups:

- `[e6]`
- `[e6_ax]`
- `[clients]`
- `[targets]`
- `[fw]`
- `[xdp]`
- `[fw_clients]`
- `[xdp_clients]`
- `[fw_targets]`
- `[xdp_targets]`
- `[iptables]`, `[iptables_clients]`, `[iptables_targets]`
- `[nftables]`, `[nftables_clients]`, `[nftables_targets]`
- `[xdp_generic]`, `[xdp_generic_clients]`, `[xdp_generic_targets]`
- `[xdp_native]`, `[xdp_native_clients]`, `[xdp_native_targets]`

The broad `fw` and `xdp` groups remain available for common setup. Benchmark
configuration and test runs use the mode-specific groups.

## 3. Run the complete matrix

```bash
cd ../ansible
./run_matrix.sh
```

By default, `run_matrix.sh` runs exactly these modes:

```bash
MODES="iptables nftables xdp-generic xdp-native"
```

The execution order is sequential, but every step uses different hardware and
network resources:

1. Configure and test the dedicated `iptables` client/target lab
2. Configure and test the dedicated `nftables` client/target lab
3. Configure and test the dedicated `xdp_generic` client/target lab
4. Configure and test the dedicated `xdp_native` client/target lab

Defaults:

| Variable | Default | Meaning |
|---|---:|---|
| `RULE_COUNT` | `128` | No-match destination ports scanned per protocol before the accept rule |
| `DURATION` | `30` | Seconds per iperf3 test |
| `PARALLEL` | `8` | Parallel streams for TCP tests |
| `UDP_RATE` | `10G` | Requested iperf3 UDP send rate |
| `REPETITIONS` | `10` | Complete benchmark samples per shape and mode; must be a positive integer |

Each repetition runs the full ping, TCP forward, TCP reverse, small-packet UDP,
and UDP-throughput sequence. With the default durations, the complete four-mode
matrix takes roughly 95–100 minutes plus configuration and SSH overhead.
With two shapes, four modes, and ten repetitions, it fetches 80 raw result
bundles before generating the aggregate outputs.

Before attaching the benchmark filter, Ansible now tests the actual compiled
program in generic mode, native driver mode, and native `xdp.frags` mode. The
probe records the interface, driver, kernel, MTU, raw attach failures, and its
normalized verdict on each XDP target in:

```text
/var/lib/oci-netbench/xdp-capabilities.txt
/var/lib/oci-netbench/xdp-capabilities.env
```

This is an attach-based check: a driver name or advertised feature alone is not
treated as proof that the benchmark program can run. The probe always detaches
its temporary programs before the configured benchmark program is attached.

Override examples:

```bash
RULE_COUNT=512 DURATION=60 PARALLEL=16 UDP_RATE=10G REPETITIONS=10 ./run_matrix.sh
```

Run only one shape group:

```bash
LIMIT=e6 ./run_matrix.sh
LIMIT=e6_ax ./run_matrix.sh
```

`LIMIT` is intersected with each dedicated mode group—for example, the
iptables step with `LIMIT=e6` uses the Ansible limit `e6:&iptables`.

Run selected modes:

```bash
MODES="xdp-generic xdp-native" ./run_matrix.sh
MODES="xdp-native" ./run_matrix.sh
MODES="iptables nftables" ./run_matrix.sh
```

Add a native-XDP result to an existing run directory and regenerate its summary:

```bash
RUN_ID=EXISTING_RUN_ID MODES="xdp-native" ./run_matrix.sh
```

Reusing a `RUN_ID` preserves existing bundles and regenerates the summaries
from every `.tar.gz` bundle in that directory. Avoid rerunning the same
shape/mode/sample combination into the same directory because its bundle name
will be replaced.

`xdp-native` is strict: the play fails rather than silently falling back to
generic mode if neither the plain nor multi-buffer/`xdp.frags` native program
can attach. This prevents generic results from being mislabeled as native.
Hardware-offloaded XDP (`xdpoffload`) remains outside this benchmark because it
is a separate capability from native driver-mode XDP.

## 4. Results and PNG charts

Results are fetched into:

```bash
results/<RUN_ID>/
```

At the end of every `run_matrix.sh` run, the summarizer creates:

```bash
results/<RUN_ID>/summary.csv
results/<RUN_ID>/summary_aggregated.csv
results/<RUN_ID>/summary.md
results/<RUN_ID>/png/lat_avg_ms.png
results/<RUN_ID>/png/packet_loss_pct.png
results/<RUN_ID>/png/tcp_forward_recv_gbps.png
results/<RUN_ID>/png/tcp_reverse_recv_gbps.png
results/<RUN_ID>/png/udp_throughput_gbps.png
results/<RUN_ID>/png/udp_throughput_jitter_ms.png
results/<RUN_ID>/png/udp_throughput_lost_percent.png
results/<RUN_ID>/png/udp_smallpps_pps.png
```

The PNG charts compare `iptables`, `nftables`, `xdp-generic`, and `xdp-native`
side by side for each OCI shape group. The charts use a high-resolution,
color-accessible grouped-bar design. Each bar is the sample mean, each whisker
is the Student's t 95% confidence interval for that mean, and the overlaid dots
are the individual runs. Bar labels include the relative change from the
iptables result for the same OCI shape. Labels use compact units and each chart
states whether higher or lower values are better. Titles, statistical
descriptions, and legends are centered above the plotting area. A confidence
interval is only drawn when at least two samples are available. `summary.csv`
retains every raw sample; `summary_aggregated.csv` contains grouped mean,
standard deviation, and 95% confidence-interval margin values.

The summary includes these grouping columns:

- `test_mode`: `iptables`, `nftables`, `xdp-generic`, or `xdp-native`
- `firewall_mode`: `iptables` or `nftables` for firewall tests; blank for XDP
- `shape_key`: `e6`, `e6_ax`, or any extra shape key you add
- `path`: `firewall` or `xdp`
- `xdp_requested_mode`: `xdpgeneric`, `xdpdrv`, or `auto` for XDP tests
- `xdp_selected_mode`: the attach mode actually benchmarked
- `xdp_selected_section`: `xdp` or `xdp.frags`
- `xdp_driver` and `xdp_mtu`: target interface context captured by the preflight

Run the summarizer manually if needed:

From the repository root:

```bash
python3 tools/summarize_results.py results/<RUN_ID>
```

If PNG generation says `matplotlib is not available`, install it on the control host:

```bash
python3 -m pip install matplotlib
```

## 5. Manual single-mode runs

These commands run one mode across the relevant clients. `run_tests.yml`
defaults to 10 samples, matching `run_matrix.sh`; add
`-e benchmark_repetitions=1` to a test command for a quick single-sample smoke
test. Start from the repository root so `cd ansible` loads the included
`ansible.cfg`.

Configure nftables and run it on only the dedicated nftables labs:

```bash
cd ansible
ansible-playbook -i ../inventory.ini site.yml --limit nftables -e firewall_rule_count=128
ansible-playbook -i ../inventory.ini run_tests.yml --limit nftables
```

Configure iptables and run it on only the dedicated iptables labs:

```bash
ansible-playbook -i ../inventory.ini site.yml --limit iptables -e firewall_rule_count=128
ansible-playbook -i ../inventory.ini run_tests.yml --limit iptables
```

Configure and run generic XDP on only the dedicated generic-XDP labs:

```bash
ansible-playbook -i ../inventory.ini site.yml --limit xdp_generic -e firewall_rule_count=128
ansible-playbook -i ../inventory.ini run_tests.yml --limit xdp_generic
```

Configure and run native XDP on only the dedicated native-XDP labs:

```bash
ansible-playbook -i ../inventory.ini site.yml --limit xdp_native -e firewall_rule_count=128
ansible-playbook -i ../inventory.ini run_tests.yml --limit xdp_native
```

Run a manual test for only Acceleron:

```bash
ansible-playbook -i ../inventory.ini site.yml --limit 'e6_ax:&nftables' -e firewall_rule_count=128
ansible-playbook -i ../inventory.ini run_tests.yml --limit 'e6_ax:&nftables'
```

## 6. Cleanup

From the repository root:

```bash
cd terraform
terraform destroy
```
