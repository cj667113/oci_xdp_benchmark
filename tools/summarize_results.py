#!/usr/bin/env python3
import csv
import json
import os
import re
import sys
import tarfile
from collections import defaultdict
from pathlib import Path
from typing import Dict, Any, Optional, Iterable, List, Tuple


TEST_MODE_ORDER = ["iptables", "nftables", "xdp"]


def read_member(tar: tarfile.TarFile, suffix: str) -> Optional[str]:
    for m in tar.getmembers():
        if m.name.endswith(suffix):
            f = tar.extractfile(m)
            if f:
                return f.read().decode("utf-8", errors="replace")
    return None


def read_json_member(tar: tarfile.TarFile, suffix: str) -> Optional[Dict[str, Any]]:
    text = read_member(tar, suffix)
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def parse_ping(text: Optional[str]) -> Dict[str, Any]:
    out = {"lat_min_ms": None, "lat_avg_ms": None, "lat_max_ms": None, "lat_mdev_ms": None, "packet_loss_pct": None}
    if not text:
        return out
    loss = re.search(r"(\d+(?:\.\d+)?)% packet loss", text)
    if loss:
        out["packet_loss_pct"] = float(loss.group(1))
    rtt = re.search(r"(?:rtt|round-trip).* = ([0-9.]+)/([0-9.]+)/([0-9.]+)/([0-9.]+) ms", text)
    if rtt:
        out["lat_min_ms"] = float(rtt.group(1))
        out["lat_avg_ms"] = float(rtt.group(2))
        out["lat_max_ms"] = float(rtt.group(3))
        out["lat_mdev_ms"] = float(rtt.group(4))
    return out


def iperf_summary(data: Optional[Dict[str, Any]], mode: str) -> Dict[str, Any]:
    out = {}
    if not data:
        return out
    end = data.get("end", {})

    def bps_to_gbps(v):
        return None if v is None else float(v) / 1_000_000_000

    if mode.startswith("tcp"):
        sent = end.get("sum_sent", {})
        received = end.get("sum_received", {})
        out[f"{mode}_sent_gbps"] = bps_to_gbps(sent.get("bits_per_second"))
        out[f"{mode}_recv_gbps"] = bps_to_gbps(received.get("bits_per_second"))
        out[f"{mode}_retransmits"] = sent.get("retransmits")
    else:
        udp = end.get("sum", {}) or end.get("sum_received", {})
        seconds = udp.get("seconds") or end.get("seconds") or None
        packets = udp.get("packets")
        out[f"{mode}_gbps"] = bps_to_gbps(udp.get("bits_per_second"))
        out[f"{mode}_jitter_ms"] = udp.get("jitter_ms")
        out[f"{mode}_lost_percent"] = udp.get("lost_percent")
        out[f"{mode}_packets"] = packets
        out[f"{mode}_pps"] = (float(packets) / float(seconds)) if packets and seconds else None
    return out


def parse_label(label: Optional[str]) -> Dict[str, Any]:
    out = {"test_mode": None, "firewall_mode": None, "shape_key": None, "path": None}
    if not label:
        return out

    # Current label format: iptables_e6_firewall, nftables_e6_ax_firewall, xdp_e6_xdp.
    m = re.match(r"^(?P<test_mode>iptables|nftables|xdp|manual)_(?P<shape_key>.+)_(?P<path>firewall|xdp)$", label)
    if m:
        out.update(m.groupdict())
        # Older result bundles used labels like iptables_e6_xdp and nftables_e6_xdp
        # for the XDP path. Treat any xdp path as the xdp test mode.
        if out["path"] == "xdp":
            out["test_mode"] = "xdp"
            out["firewall_mode"] = None
        else:
            out["firewall_mode"] = out["test_mode"] if out["test_mode"] in ("iptables", "nftables") else None
        return out

    # Backward-compatible label support from older project zips.
    old = re.match(r"^(?P<firewall_mode>iptables|nftables|manual)_(?P<shape_key>.+)_(?P<path>firewall|xdp)$", label)
    if old:
        out.update(old.groupdict())
        out["test_mode"] = "xdp" if out["path"] == "xdp" else out["firewall_mode"]
    return out


def summarize_tar(path: Path) -> Dict[str, Any]:
    row: Dict[str, Any] = {"bundle": path.name}
    with tarfile.open(path, "r:gz") as tar:
        meta = read_json_member(tar, "metadata.json") or {}
        label = meta.get("label")
        row.update({
            "label": label,
            "hostname": meta.get("hostname"),
            "target_ip": meta.get("target_ip"),
            "duration": meta.get("duration"),
            "parallel": meta.get("parallel"),
            "udp_rate": meta.get("udp_rate"),
            "udp_len": meta.get("udp_len"),
            "kernel": meta.get("kernel"),
            "xdp_requested_mode": meta.get("xdp_requested_mode"),
            "xdp_selected_mode": meta.get("xdp_selected_mode"),
            "xdp_selected_section": meta.get("xdp_selected_section"),
            "xdp_driver": meta.get("xdp_driver"),
            "xdp_mtu": meta.get("xdp_mtu"),
        })
        row.update(parse_label(label))
        row.update(parse_ping(read_member(tar, "ping.txt")))
        tests = {
            "tcp_forward": "tcp_forward.out",
            "tcp_reverse": "tcp_reverse.out",
            "udp_smallpps": "udp_smallpps.out",
            "udp_throughput": "udp_throughput.out",
        }
        for mode, suffix in tests.items():
            row.update(iperf_summary(read_json_member(tar, suffix), mode))
    return row


def safe_float(value: Any) -> Optional[float]:
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def ordered_unique(values: Iterable[Any]) -> List[str]:
    strings = [str(v) for v in values if v not in (None, "")]
    return sorted(set(strings))


def mode_sort_key(mode: str) -> Tuple[int, str]:
    try:
        return (TEST_MODE_ORDER.index(mode), mode)
    except ValueError:
        return (len(TEST_MODE_ORDER), mode)


def average_rows(rows: List[Dict[str, Any]], metric: str) -> Dict[Tuple[str, str], float]:
    buckets: Dict[Tuple[str, str], List[float]] = defaultdict(list)
    for row in rows:
        shape = row.get("shape_key")
        mode = row.get("test_mode")
        value = safe_float(row.get(metric))
        if shape and mode and value is not None:
            buckets[(str(shape), str(mode))].append(value)
    return {k: sum(v) / len(v) for k, v in buckets.items() if v}


def generate_pngs(rows: List[Dict[str, Any]], root: Path) -> List[Path]:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as exc:
        print(f"WARNING: matplotlib is not available; skipping PNG generation: {exc}", file=sys.stderr)
        print("Install it on the control host with: python3 -m pip install matplotlib", file=sys.stderr)
        return []

    charts = [
        ("lat_avg_ms", "ICMP average latency", "Milliseconds", "lower is better"),
        ("packet_loss_pct", "ICMP packet loss", "Percent", "lower is better"),
        ("tcp_forward_recv_gbps", "TCP forward throughput", "Gbit/s", "higher is better"),
        ("tcp_reverse_recv_gbps", "TCP reverse throughput", "Gbit/s", "higher is better"),
        ("udp_throughput_gbps", "UDP throughput", "Gbit/s", "higher is better"),
        ("udp_throughput_jitter_ms", "UDP jitter", "Milliseconds", "lower is better"),
        ("udp_throughput_lost_percent", "UDP loss", "Percent", "lower is better"),
        ("udp_smallpps_pps", "Small-packet UDP rate", "Packets/sec", "higher is better"),
    ]

    shape_keys = ordered_unique(row.get("shape_key") for row in rows)
    test_modes = sorted(ordered_unique(row.get("test_mode") for row in rows), key=mode_sort_key)
    if not shape_keys or not test_modes:
        return []

    out_dir = root / "png"
    out_dir.mkdir(exist_ok=True)
    generated: List[Path] = []

    for metric, title, ylabel, hint in charts:
        data = average_rows(rows, metric)
        if not data:
            continue

        x_positions = list(range(len(shape_keys)))
        width = 0.8 / max(len(test_modes), 1)
        fig_width = max(8, 2 + len(shape_keys) * 2.2)
        fig, ax = plt.subplots(figsize=(fig_width, 5.5))

        for idx, mode in enumerate(test_modes):
            offsets = [x - 0.4 + width / 2 + idx * width for x in x_positions]
            values = [data.get((shape, mode), 0.0) for shape in shape_keys]
            bars = ax.bar(offsets, values, width, label=mode)
            for bar, value in zip(bars, values):
                if value == 0.0:
                    continue
                if abs(value) >= 1000:
                    label = f"{value:,.0f}"
                elif abs(value) >= 100:
                    label = f"{value:,.1f}"
                else:
                    label = f"{value:,.3g}"
                ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height(), label,
                        ha="center", va="bottom", fontsize=8, rotation=0)

        ax.set_title(f"{title} by shape and mode ({hint})")
        ax.set_xlabel("OCI shape group")
        ax.set_ylabel(ylabel)
        ax.set_xticks(x_positions)
        ax.set_xticklabels(shape_keys)
        ax.legend(title="Test mode")
        ax.grid(axis="y", alpha=0.25)
        fig.tight_layout()

        png_path = out_dir / f"{metric}.png"
        fig.savefig(png_path, dpi=160)
        plt.close(fig)
        generated.append(png_path)

    return generated


def write_outputs(rows: List[Dict[str, Any]], root: Path) -> Tuple[Path, Path, List[Path]]:
    keys: List[str] = []
    for row in rows:
        for k in row.keys():
            if k not in keys:
                keys.append(k)

    csv_path = root / "summary.csv"
    with csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=keys)
        writer.writeheader()
        writer.writerows(rows)

    pngs = generate_pngs(rows, root)

    md_path = root / "summary.md"
    preferred = [
        "test_mode", "firewall_mode", "shape_key", "path",
        "xdp_requested_mode", "xdp_selected_mode", "xdp_selected_section", "xdp_driver", "xdp_mtu",
        "lat_avg_ms", "lat_mdev_ms", "packet_loss_pct",
        "tcp_forward_recv_gbps", "tcp_reverse_recv_gbps",
        "udp_smallpps_pps", "udp_smallpps_lost_percent",
        "udp_throughput_gbps", "udp_throughput_jitter_ms", "udp_throughput_lost_percent",
        "label",
    ]
    with md_path.open("w") as f:
        f.write("# OCI XDP vs iptables/nftables Benchmark Summary\n\n")
        f.write("## Metrics table\n\n")
        f.write("| " + " | ".join(preferred) + " |\n")
        f.write("| " + " | ".join(["---"] * len(preferred)) + " |\n")
        for r in rows:
            vals = []
            for k in preferred:
                v = r.get(k)
                vals.append("" if v is None else str(round(v, 4)) if isinstance(v, float) else str(v))
            f.write("| " + " | ".join(vals) + " |\n")

        if pngs:
            f.write("\n## PNG comparison charts\n\n")
            for p in pngs:
                rel = p.relative_to(root)
                title = p.stem.replace("_", " ").title()
                f.write(f"- [{title}]({rel.as_posix()})\n")

    return csv_path, md_path, pngs


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} RESULTS_DIR", file=sys.stderr)
        sys.exit(2)
    root = Path(sys.argv[1])
    bundles = sorted(root.glob("*.tar.gz"))
    if not bundles:
        print(f"No .tar.gz result bundles found in {root}", file=sys.stderr)
        sys.exit(1)

    rows = [summarize_tar(p) for p in bundles]
    csv_path, md_path, pngs = write_outputs(rows, root)

    print(f"Wrote {csv_path}")
    print(f"Wrote {md_path}")
    if pngs:
        print("Wrote PNG charts:")
        for p in pngs:
            print(f"  {p}")
    print(md_path.read_text())


if __name__ == "__main__":
    main()
