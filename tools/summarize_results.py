#!/usr/bin/env python3
import csv
import json
import math
import os
import re
import statistics
import sys
import tarfile
from collections import defaultdict
from pathlib import Path
from typing import Dict, Any, Optional, Iterable, List, Tuple


TEST_MODE_ORDER = ["iptables", "nftables", "xdp-generic", "xdp-native", "xdp"]
AGGREGATE_METRICS = [
    "lat_avg_ms",
    "packet_loss_pct",
    "tcp_forward_recv_gbps",
    "tcp_reverse_recv_gbps",
    "udp_smallpps_pps",
    "udp_throughput_gbps",
    "udp_throughput_jitter_ms",
    "udp_throughput_lost_percent",
]

# Two-tailed Student's t critical values for a 95% confidence interval. Runs
# default to 10 samples (9 degrees of freedom), but the wider table keeps the
# calculation useful when REPETITIONS is overridden.
T_CRITICAL_95 = {
    1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571,
    6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228,
    11: 2.201, 12: 2.179, 13: 2.160, 14: 2.145, 15: 2.131,
    16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093, 20: 2.086,
    21: 2.080, 22: 2.074, 23: 2.069, 24: 2.064, 25: 2.060,
    26: 2.056, 27: 2.052, 28: 2.048, 29: 2.045, 30: 2.042,
}


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
    out = {"test_mode": None, "firewall_mode": None, "shape_key": None, "path": None, "sample_index": None}
    if not label:
        return out

    # Current label format: iptables_e6_firewall, xdp-generic_e6_xdp,
    # xdp-native_e6_ax_xdp. The plain xdp value remains for old bundles.
    m = re.match(
        r"^(?P<test_mode>iptables|nftables|xdp-generic|xdp-native|xdp|manual)_(?P<shape_key>.+)_(?P<path>firewall|xdp)(?:_run(?P<sample_index>[0-9]+))?$",
        label,
    )
    if m:
        out.update(m.groupdict())
        if out["sample_index"] is not None:
            out["sample_index"] = int(out["sample_index"])
        # Older result bundles used labels like iptables_e6_xdp and nftables_e6_xdp
        # for the XDP path. Treat any xdp path as the xdp test mode.
        if out["path"] == "xdp":
            if out["test_mode"] not in ("xdp-generic", "xdp-native", "xdp"):
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
            "sample_index": meta.get("sample_index"),
            "sample_count": meta.get("sample_count"),
        })
        row.update(parse_label(label))
        # Reclassify legacy labels using the actual attach mode captured in the
        # bundle. New bundles already carry explicit xdp-generic/xdp-native labels.
        if row.get("path") == "xdp" and row.get("test_mode") == "xdp":
            selected_mode = meta.get("xdp_selected_mode")
            if selected_mode == "xdpgeneric":
                row["test_mode"] = "xdp-generic"
            elif selected_mode == "xdpdrv":
                row["test_mode"] = "xdp-native"
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


def metric_values(rows: List[Dict[str, Any]], metric: str) -> Dict[Tuple[str, str], List[float]]:
    buckets: Dict[Tuple[str, str], List[float]] = defaultdict(list)
    for row in rows:
        shape = row.get("shape_key")
        mode = row.get("test_mode")
        value = safe_float(row.get(metric))
        if shape and mode and value is not None:
            buckets[(str(shape), str(mode))].append(value)
    return dict(buckets)


def metric_stats(rows: List[Dict[str, Any]], metric: str) -> Dict[Tuple[str, str], Tuple[float, float, int]]:
    buckets = metric_values(rows, metric)
    return {
        key: (statistics.fmean(values), statistics.stdev(values) if len(values) > 1 else 0.0, len(values))
        for key, values in buckets.items()
        if values
    }


def confidence_interval_95(stdev: float, count: int) -> Optional[float]:
    """Return the two-sided 95% confidence-interval margin for a sample mean."""
    if count < 2:
        return None
    degrees_of_freedom = count - 1
    if degrees_of_freedom <= 30:
        critical = T_CRITICAL_95[degrees_of_freedom]
    elif degrees_of_freedom <= 40:
        critical = 2.021
    elif degrees_of_freedom <= 60:
        critical = 2.000
    elif degrees_of_freedom <= 120:
        critical = 1.980
    else:
        critical = 1.960
    return critical * stdev / math.sqrt(count)


def aggregate_rows(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    buckets: Dict[Tuple[str, str], List[Dict[str, Any]]] = defaultdict(list)
    for row in rows:
        shape = row.get("shape_key")
        mode = row.get("test_mode")
        if shape and mode:
            buckets[(str(shape), str(mode))].append(row)

    aggregates: List[Dict[str, Any]] = []
    for (shape, mode), samples in sorted(
        buckets.items(), key=lambda item: (item[0][0], mode_sort_key(item[0][1]))
    ):
        aggregate: Dict[str, Any] = {
            "shape_key": shape,
            "test_mode": mode,
            "sample_count": len(samples),
        }
        for field in ("xdp_selected_mode", "xdp_selected_section", "xdp_driver", "xdp_mtu"):
            values = ordered_unique(sample.get(field) for sample in samples)
            aggregate[field] = ",".join(values)
        for metric in AGGREGATE_METRICS:
            values = [value for sample in samples if (value := safe_float(sample.get(metric))) is not None]
            mean = statistics.fmean(values) if values else None
            stdev = statistics.stdev(values) if len(values) > 1 else (0.0 if values else None)
            ci95 = confidence_interval_95(stdev, len(values)) if stdev is not None else None
            aggregate[f"{metric}_mean"] = mean
            aggregate[f"{metric}_stdev"] = stdev
            aggregate[f"{metric}_ci95_margin"] = ci95
        aggregates.append(aggregate)
    return aggregates


def generate_pngs(rows: List[Dict[str, Any]], root: Path) -> List[Path]:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.patches import Patch
        from matplotlib.ticker import FuncFormatter, MaxNLocator
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

    mode_styles = {
        "iptables": {"color": "#2563EB", "marker": "o", "label": "iptables"},
        "nftables": {"color": "#F59E0B", "marker": "s", "label": "nftables"},
        "xdp-generic": {"color": "#0F9D8A", "marker": "D", "label": "XDP generic"},
        "xdp-native": {"color": "#7C3AED", "marker": "^", "label": "XDP native"},
        "xdp": {"color": "#64748B", "marker": "P", "label": "XDP (legacy)"},
    }
    fallback_colors = ["#0891B2", "#E11D48", "#65A30D", "#C2410C"]

    theme = {
        "figure.facecolor": "#F8FAFC",
        "axes.facecolor": "#FFFFFF",
        "axes.edgecolor": "#CBD5E1",
        "axes.labelcolor": "#475569",
        "axes.titlecolor": "#0F172A",
        "font.family": "DejaVu Sans",
        "font.size": 10,
        "xtick.color": "#475569",
        "ytick.color": "#475569",
        "text.color": "#0F172A",
        "grid.color": "#E2E8F0",
        "grid.linewidth": 0.8,
        "axes.axisbelow": True,
    }

    def style_for(mode: str, index: int) -> Dict[str, str]:
        return mode_styles.get(
            mode,
            {"color": fallback_colors[index % len(fallback_colors)], "marker": "o", "label": mode},
        )

    def shape_label(shape: str) -> str:
        return shape.replace("_", ".").upper()

    def value_label(metric: str, value: float) -> str:
        if metric == "udp_smallpps_pps":
            if abs(value) >= 1_000_000:
                return f"{value / 1_000_000:.2f}M"
            if abs(value) >= 1_000:
                return f"{value / 1_000:.0f}k"
            return f"{value:,.0f}"
        if metric.endswith("_gbps"):
            return f"{value:.2f}"
        if metric.endswith("_pct") or metric.endswith("_percent"):
            return f"{value:.2f}%"
        if metric.endswith("_ms"):
            return f"{value:.3f}"
        return f"{value:,.3g}"

    def configure_y_axis(ax: Any, metric: str, observed_values: List[float]) -> None:
        observed_max = max(observed_values)
        if observed_max <= 0:
            ax.set_ylim(0, 1.0 if metric.endswith("_pct") or metric.endswith("_percent") else 0.1)
        else:
            # Bars encode magnitude by length, so a zero baseline is important.
            ax.set_ylim(0, observed_max * 1.27)

        ax.yaxis.set_major_locator(MaxNLocator(nbins=6))
        if metric == "udp_smallpps_pps":
            ax.yaxis.set_major_formatter(
                FuncFormatter(lambda value, _: f"{value / 1_000_000:.1f}M" if abs(value) >= 1_000_000 else
                              f"{value / 1_000:.0f}k" if abs(value) >= 1_000 else f"{value:.0f}")
            )
        elif metric.endswith("_pct") or metric.endswith("_percent"):
            ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value:g}%"))
        elif metric.endswith("_gbps"):
            ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value:.2f}"))
        elif metric.endswith("_ms"):
            ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value:.3f}"))

    with plt.rc_context(theme):
        for metric, title, ylabel, hint in charts:
            data = metric_stats(rows, metric)
            samples_by_group = metric_values(rows, metric)
            if not data:
                continue

            x_positions = list(range(len(shape_keys)))
            mode_count = max(len(test_modes), 1)
            bar_width = min(0.19, 0.78 / mode_count)
            offsets_by_mode = [bar_width * (idx - (mode_count - 1) / 2) for idx in range(mode_count)]
            fig_width = max(9.5, 3.2 + len(shape_keys) * 2.9)
            fig, ax = plt.subplots(figsize=(fig_width, 6.4))
            fig.subplots_adjust(left=0.11, right=0.97, bottom=0.15, top=0.70)

            observed_values: List[float] = []
            sample_sizes = set()

            for idx, mode in enumerate(test_modes):
                style = style_for(mode, idx)
                xs: List[float] = []
                values: List[float] = []
                ci_margins: List[float] = []
                group_samples: List[List[float]] = []
                groups: List[str] = []
                for x, shape in zip(x_positions, shape_keys):
                    point = data.get((shape, mode))
                    if point is None:
                        continue
                    mean, stdev, count = point
                    ci95 = confidence_interval_95(stdev, count)
                    xs.append(x + offsets_by_mode[idx])
                    values.append(mean)
                    ci_margins.append(ci95 or 0.0)
                    group_samples.append(samples_by_group[(shape, mode)])
                    groups.append(shape)
                    sample_sizes.add(count)

                if not values:
                    continue

                bars = ax.bar(
                    xs,
                    values,
                    width=bar_width * 0.88,
                    color=style["color"],
                    edgecolor="#FFFFFF",
                    linewidth=1.2,
                    alpha=0.90,
                    zorder=2,
                )

                for bar, x, value, ci95, samples, shape in zip(
                    bars, xs, values, ci_margins, group_samples, groups
                ):
                    if len(samples) > 1:
                        ax.errorbar(
                            x,
                            value,
                            yerr=ci95,
                            fmt="none",
                            ecolor="#0F172A",
                            elinewidth=1.35,
                            capsize=4,
                            capthick=1.35,
                            zorder=5,
                        )

                    if len(samples) == 1:
                        jittered_x = [x]
                    else:
                        spread = bar.get_width() * 0.58
                        jittered_x = [
                            x - spread / 2 + spread * sample_index / (len(samples) - 1)
                            for sample_index in range(len(samples))
                        ]
                    ax.scatter(
                        jittered_x,
                        samples,
                        s=15,
                        marker=style["marker"],
                        facecolor="#FFFFFF",
                        edgecolor="#0F172A",
                        linewidth=0.6,
                        alpha=0.78,
                        zorder=4,
                    )

                    baseline = data.get((shape, "iptables"))
                    relative_change = None
                    if mode != "iptables" and baseline and baseline[0] != 0:
                        relative_change = (value - baseline[0]) / abs(baseline[0]) * 100
                        if abs(relative_change) < 0.05:
                            relative_change = 0.0
                    label = value_label(metric, value)
                    if relative_change is not None:
                        label += f"\nΔ {relative_change:+.1f}%"
                    ax.annotate(
                        label,
                        (x, value + ci95),
                        xytext=(0, 7),
                        textcoords="offset points",
                        ha="center",
                        va="bottom",
                        fontsize=7.7,
                        fontweight="bold",
                        color="#334155",
                        annotation_clip=False,
                    )

                    observed_values.extend(samples)
                    observed_values.append(value + ci95)

            configure_y_axis(ax, metric, observed_values)
            ax.set_ylabel(ylabel, fontsize=10.5, fontweight="normal", labelpad=11)
            ax.set_xticks(x_positions)
            ax.set_xticklabels([shape_label(shape) for shape in shape_keys], fontsize=11, fontweight="bold")
            ax.tick_params(axis="both", which="major", length=0, pad=8)
            ax.grid(axis="y")
            ax.grid(axis="x", visible=False)
            ax.spines["top"].set_visible(False)
            ax.spines["right"].set_visible(False)
            ax.spines["left"].set_color("#CBD5E1")
            ax.spines["bottom"].set_color("#CBD5E1")

            sample_text = ""
            if len(sample_sizes) == 1:
                count = next(iter(sample_sizes))
                sample_text = f" · n={count} per bar"
            fig.suptitle(title, x=0.11, y=0.955, ha="left", fontsize=19, fontweight="bold", color="#0F172A")
            fig.text(
                0.11,
                0.905,
                f"{hint.capitalize()} · Bar = mean · Whisker = 95% CI (n≥2) · Dots = runs{sample_text} · Δ vs iptables",
                ha="left",
                va="center",
                fontsize=9.5,
                color="#64748B",
            )

            legend_handles = []
            for idx, mode in enumerate(test_modes):
                style = style_for(mode, idx)
                legend_handles.append(
                    Patch(
                        facecolor=style["color"],
                        edgecolor="#FFFFFF",
                        linewidth=1.0,
                        label=style["label"],
                    )
                )
            fig.legend(
                handles=legend_handles,
                loc="upper left",
                bbox_to_anchor=(0.102, 0.845),
                ncol=min(len(legend_handles), 4),
                frameon=False,
                handletextpad=0.45,
                columnspacing=1.6,
                fontsize=9.5,
            )

            png_path = out_dir / f"{metric}.png"
            fig.savefig(png_path, dpi=200, bbox_inches="tight", facecolor=fig.get_facecolor())
            plt.close(fig)
            generated.append(png_path)

    return generated


def write_outputs(rows: List[Dict[str, Any]], root: Path) -> Tuple[Path, Path, Path, List[Path]]:
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

    aggregates = aggregate_rows(rows)
    aggregate_csv_path = root / "summary_aggregated.csv"
    aggregate_keys: List[str] = []
    for aggregate in aggregates:
        for key in aggregate.keys():
            if key not in aggregate_keys:
                aggregate_keys.append(key)
    with aggregate_csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=aggregate_keys)
        writer.writeheader()
        writer.writerows(aggregates)

    pngs = generate_pngs(rows, root)

    md_path = root / "summary.md"
    preferred = [
        "sample_index", "sample_count", "test_mode", "firewall_mode", "shape_key", "path",
        "xdp_requested_mode", "xdp_selected_mode", "xdp_selected_section", "xdp_driver", "xdp_mtu",
        "lat_avg_ms", "lat_mdev_ms", "packet_loss_pct",
        "tcp_forward_recv_gbps", "tcp_reverse_recv_gbps",
        "udp_smallpps_pps", "udp_smallpps_lost_percent",
        "udp_throughput_gbps", "udp_throughput_jitter_ms", "udp_throughput_lost_percent",
        "label",
    ]
    with md_path.open("w") as f:
        f.write("# OCI Packet-Filter Benchmark Summary\n\n")
        f.write("## Aggregate statistics\n\n")
        aggregate_preferred = ["shape_key", "test_mode", "sample_count"]
        for metric in AGGREGATE_METRICS:
            aggregate_preferred.extend([f"{metric}_mean", f"{metric}_stdev"])
        f.write("| " + " | ".join(aggregate_preferred) + " |\n")
        f.write("| " + " | ".join(["---"] * len(aggregate_preferred)) + " |\n")
        for aggregate in aggregates:
            values = []
            for key in aggregate_preferred:
                value = aggregate.get(key)
                values.append("" if value is None else str(round(value, 4)) if isinstance(value, float) else str(value))
            f.write("| " + " | ".join(values) + " |\n")

        f.write("\n## Raw sample metrics\n\n")
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

    return csv_path, aggregate_csv_path, md_path, pngs


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
    csv_path, aggregate_csv_path, md_path, pngs = write_outputs(rows, root)

    print(f"Wrote {csv_path}")
    print(f"Wrote {aggregate_csv_path}")
    print(f"Wrote {md_path}")
    if pngs:
        print("Wrote PNG charts:")
        for p in pngs:
            print(f"  {p}")
    print(md_path.read_text())


if __name__ == "__main__":
    main()
