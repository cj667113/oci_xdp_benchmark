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

The default Terraform shape matrix is:

| Shape key | OCI shape | OCPUs | RAM | Nodes created |
|---|---:|---:|---:|---|
| `e6` | `VM.Standard.E6.Flex` | 10 | 80 GB | `e6_fw_client`, `e6_fw_target`, `e6_xdp_client`, `e6_xdp_target` |
| `e6_ax` | `VM.Standard.E6.Ax.Flex` | 10 | 80 GB | `e6_ax_fw_client`, `e6_ax_fw_target`, `e6_ax_xdp_client`, `e6_ax_xdp_target` |

That is 8 instances total by default:

- `*_fw_client` -> `*_fw_target`: sequentially configured and tested as `iptables`, then `nftables`
- `*_xdp_client` -> `*_xdp_target`: tested sequentially with generic/SKB-mode XDP and native driver-mode XDP

The benchmark collects:

- ICMP latency: min/avg/max/mdev and packet loss
- TCP forward and reverse throughput with iperf3 JSON
- UDP throughput and jitter
- Small-packet UDP packets per second estimate
- Linux link, qdisc, and nstat counters before/after each run
- Requested and selected XDP mode, ELF section, target driver, and target MTU

The Linux egress cap is set to `10gbit` with `tc`, so the test has a consistent maximum bandwidth cap. The shape config is also locked to 10 OCPUs and 80 GB RAM per instance in Terraform validation.

## 1. Configure Terraform

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

Strong recommendation: set `allowed_ssh_cidr` to your workstation public IP `/32`.

The default `oracle_linux_major_version = "10"` selects the newest compatible
Oracle Linux 10 point/build image available in the configured OCI region.

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

```bash
terraform init
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

## 3. Run the complete matrix

```bash
cd ../ansible
./run_matrix.sh
```

By default, `run_matrix.sh` runs exactly these modes:

```bash
MODES="iptables nftables xdp-generic xdp-native"
```

The execution order is:

1. Configure `*_fw_target` with synthetic `iptables` rules, then test `*_fw_client -> *_fw_target`
2. Configure `*_fw_target` with synthetic `nftables` rules, then test `*_fw_client -> *_fw_target`
3. Configure `*_xdp_target` with generic XDP, then test `*_xdp_client -> *_xdp_target`
4. Reconfigure `*_xdp_target` with native driver-mode XDP, then repeat the same tests

Defaults:

- `RULE_COUNT=128`
- `DURATION=30`
- `PARALLEL=8`
- `UDP_RATE=10G`
- `REPETITIONS=10`

Each repetition runs the full ping, TCP forward, TCP reverse, small-packet UDP,
and UDP-throughput sequence. With the default durations, the complete four-mode
matrix takes roughly 95–100 minutes plus configuration and SSH overhead.

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

Run selected modes:

```bash
MODES="xdp-generic xdp-native" ./run_matrix.sh
MODES="xdp-native" ./run_matrix.sh
MODES="iptables nftables" ./run_matrix.sh
```

Add a native-XDP result to an existing run directory and regenerate its summary:

```bash
RUN_ID=20260630T173437Z MODES="xdp-native" ./run_matrix.sh
```

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
states whether higher or lower values are better. A confidence interval is only
drawn when at least two samples are available. `summary.csv` retains every raw
sample; `summary_aggregated.csv` contains grouped mean, standard deviation, and
95% confidence-interval margin values.

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

```bash
python3 tools/summarize_results.py results/<RUN_ID>
```

If PNG generation says `matplotlib is not available`, install it on the control host:

```bash
python3 -m pip install matplotlib
```

## 5. Manual single-mode runs

Configure nftables and run one test across all shape labs:

```bash
cd ansible
ansible-playbook -i ../inventory.ini site.yml --limit fw -e firewall_mode=nftables -e firewall_rule_count=128
ansible-playbook -i ../inventory.ini run_tests.yml --limit fw -e test_label=nftables
```

Configure iptables and run one test across all shape labs:

```bash
ansible-playbook -i ../inventory.ini site.yml --limit fw -e firewall_mode=iptables -e firewall_rule_count=128
ansible-playbook -i ../inventory.ini run_tests.yml --limit fw -e test_label=iptables
```

Configure and run generic XDP across all shape labs:

```bash
ansible-playbook -i ../inventory.ini site.yml --limit xdp -e firewall_rule_count=128 -e xdp_mode=xdpgeneric
ansible-playbook -i ../inventory.ini run_tests.yml --limit xdp -e test_label=xdp-generic
```

Configure and run native XDP across all shape labs:

```bash
ansible-playbook -i ../inventory.ini site.yml --limit xdp -e firewall_rule_count=128 -e xdp_mode=xdpdrv
ansible-playbook -i ../inventory.ini run_tests.yml --limit xdp -e test_label=xdp-native
```

Run a manual test for only Acceleron:

```bash
ansible-playbook -i ../inventory.ini site.yml --limit 'e6_ax:&fw' -e firewall_mode=nftables -e firewall_rule_count=128
ansible-playbook -i ../inventory.ini run_tests.yml --limit 'e6_ax:&fw' -e test_label=nftables
```

## 6. Cleanup

```bash
cd terraform
terraform destroy
```
