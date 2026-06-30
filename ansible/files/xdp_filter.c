#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/in.h>

#ifndef TEST_PORT
#define TEST_PORT 5201
#endif

#ifndef RULE_SCAN
#define RULE_SCAN 128
#endif

char LICENSE[] SEC("license") = "GPL";

static __always_inline int inspect_port(__u16 dport)
{
    /*
     * Emulate a linear firewall scan with deterministic no-match rules.
     * Traffic to TEST_PORT passes after the scan. Traffic to ports in the
     * synthetic rule range drops so you can also test drop-path PPS if needed.
     */
#pragma clang loop unroll(disable)
    for (__u16 p = 10000; p < 10000 + RULE_SCAN; p++) {
        if (dport == p)
            return XDP_DROP;
    }

    if (dport == TEST_PORT)
        return XDP_PASS;

    return XDP_PASS;
}

SEC("xdp")
int xdp_bench_filter(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (bpf_ntohs(eth->h_proto) != ETH_P_IP)
        return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    __u32 ihl = ip->ihl * 4;
    if (ihl < sizeof(*ip))
        return XDP_PASS;

    void *l4 = (void *)ip + ihl;
    if (l4 > data_end)
        return XDP_PASS;

    if (ip->protocol == IPPROTO_TCP) {
        struct tcphdr *tcp = l4;
        if ((void *)(tcp + 1) > data_end)
            return XDP_PASS;
        return inspect_port(bpf_ntohs(tcp->dest));
    }

    if (ip->protocol == IPPROTO_UDP) {
        struct udphdr *udp = l4;
        if ((void *)(udp + 1) > data_end)
            return XDP_PASS;
        return inspect_port(bpf_ntohs(udp->dest));
    }

    return XDP_PASS;
}
