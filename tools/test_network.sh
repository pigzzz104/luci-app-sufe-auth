#!/bin/sh
# ==============================================================================
# test_network.sh - 三类多 WAN 架构标准化只读回归测试
#
# 用法（在路由器上执行）:
#   sh /tmp/test_network.sh
#   sh /tmp/test_network.sh --quick
#   sh /tmp/test_network.sh --client 192.168.6.216
#
# 原则:
#   - 只读: 不修改 UCI / iptables / ipset, 不重启任何服务
#   - FAIL = 明确的网络或策略异常
#   - WARN = 可能异常，也可能是站点侧/旧连接导致，需要人工判断
#
# 退出码: FAIL 数量（用于脚本化回归）
# ==============================================================================

QUICK=0
CLIENT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --quick)  QUICK=1 ;;
        --client) shift; CLIENT="${1:-}" ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 2
            ;;
    esac
    shift
done

PASS=0
FAIL=0
WARN=0

pass() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$*"; }
warn() { WARN=$((WARN + 1)); printf '[WARN] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
section() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'

http_strict() {
    # dev url min_bytes label
    dev=$1
    url=$2
    min=$3
    label=$4
    out=$(curl -m 15 --interface "$dev" -sS -H "User-Agent: $UA" -o /dev/null \
        -w '%{http_code} %{size_download} %{time_total}' "$url" 2>/dev/null)
    set -- $out
    code=${1:-000}
    bytes=${2:-0}
    t=${3:-0}
    case "$code" in
        2*|3*) ;;
        *)
            fail "$label via $dev: HTTP $code (${t}s)"
            return
            ;;
    esac
    if [ "$bytes" -ge "$min" ]; then
        pass "$label via $dev: HTTP $code ${bytes}B ${t}s"
    else
        fail "$label via $dev: only ${bytes}B (need ${min}B)"
    fi
}

http_reach() {
    # dev url label
    dev=$1
    url=$2
    label=$3
    out=$(curl -m 10 --interface "$dev" -sS -H "User-Agent: $UA" -o /dev/null \
        -w '%{http_code} %{size_download} %{time_total}' "$url" 2>/dev/null)
    set -- $out
    code=${1:-000}
    bytes=${2:-0}
    t=${3:-0}
    if [ "$code" != "000" ]; then
        pass "$label via $dev: HTTP $code ${bytes}B ${t}s"
    else
        warn "$label via $dev: no response (${t}s, may be site-side)"
    fi
}

fetch_check() {
    # dev url min_bytes label [extra curl args...]
    dev=$1
    url=$2
    min=$3
    label=$4
    shift 4
    out=$(curl -m 20 --interface "$dev" -sS -H "User-Agent: $UA" "$@" -o /dev/null \
        -w '%{http_code} %{size_download} %{time_total}' "$url" 2>/dev/null)
    set -- $out
    code=${1:-000}
    bytes=${2:-0}
    t=${3:-0}
    case "$code" in
        2*|3*) ;;
        *)
            fail "$label via $dev: HTTP $code (${t}s)"
            return
            ;;
    esac
    if [ "$bytes" -ge "$min" ]; then
        pass "$label via $dev: HTTP $code ${bytes}B ${t}s"
    else
        fail "$label via $dev: only ${bytes}B (need ${min}B)"
    fi
}

# ---------------------------------------------------------------------------
section "1. System"
UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
MEM=$(free 2>/dev/null | awk '/Mem:/{printf "%d/%d MB", $3/1024, $2/1024}')
info "uptime ${UP}s, load ${LOAD}"
info "memory used ${MEM}"
CT=$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null)
CTMAX=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null)
if [ -n "$CT" ] && [ -n "$CTMAX" ] && [ "$CT" -lt $((CTMAX / 2)) ]; then
    pass "conntrack ${CT}/${CTMAX}"
else
    warn "conntrack ${CT:-?}/${CTMAX:-?} is high"
fi

# ---------------------------------------------------------------------------
section "2. WAN health"
for pair in wan:eth1:10.64.0.1 wan2:eth0.2:10.64.0.1; do
    name=${pair%%:*}
    rest=${pair#*:}
    dev=${rest%%:*}
    gw=${rest#*:}

    st=$(cat "/var/run/mwan3/iface_state/$name" 2>/dev/null)
    if [ "$st" = "online" ]; then
        pass "$name ($dev) state online"
    else
        fail "$name ($dev) state=${st:-unknown}"
    fi

    ip4=$(ip -4 addr show "$dev" 2>/dev/null | awk '/inet /{print $2; exit}')
    if [ -n "$ip4" ]; then
        pass "$name IPv4 $ip4"
    else
        fail "$name has no IPv4 address"
    fi

    loss=$(ping -c 3 -W 2 -I "$dev" "$gw" 2>/dev/null | \
        sed -n 's/.*, \([0-9]*\)% packet loss.*/\1/p')
    if [ "$loss" = "0" ]; then
        pass "$name gateway $gw 0% loss"
    elif [ -n "$loss" ]; then
        fail "$name gateway $gw ${loss}% loss"
    else
        fail "$name gateway $gw unreachable"
    fi

    loss=$(ping -c 3 -W 2 -I "$dev" 223.5.5.5 2>/dev/null | \
        sed -n 's/.*, \([0-9]*\)% packet loss.*/\1/p')
    if [ "$loss" = "0" ]; then
        pass "$name public 223.5.5.5 0% loss"
    elif [ -n "$loss" ]; then
        warn "$name public 223.5.5.5 ${loss}% loss"
    else
        warn "$name public 223.5.5.5 unreachable"
    fi

    rxe=$(cat "/sys/class/net/$dev/statistics/rx_errors" 2>/dev/null)
    txe=$(cat "/sys/class/net/$dev/statistics/tx_errors" 2>/dev/null)
    if [ "${rxe:-0}" = "0" ] && [ "${txe:-0}" = "0" ]; then
        pass "$name link errors 0/0"
    else
        fail "$name link errors rx=${rxe:-?} tx=${txe:-?}"
    fi
done

# ---------------------------------------------------------------------------
section "3. Routing / policy"
NH=$(ip route show table 50 2>/dev/null | grep -c 'nexthop')
if [ "$NH" -ge 2 ]; then
    pass "Table 50 has ${NH} nexthops (dual WAN aggregation)"
else
    fail "Table 50 has only ${NH} nexthop(s)"
fi

if ip rule list 2>/dev/null | grep -q 'lookup 50'; then
    pass "ip rule for fwmark 0x300 -> table 50 present"
else
    fail "ip rule for table 50 missing"
fi

if iptables -t mangle -S mwan3_policy_balanced 2>/dev/null | grep -q '0x300/0x3f00'; then
    pass "balanced policy marks 0x300"
else
    fail "balanced policy does not mark 0x300"
fi

if iptables -t nat -S MWAN3_WAN2_SNAT 2>/dev/null | grep -q 'SNAT --to-source'; then
    pass "WAN2 explicit SNAT present"
else
    fail "WAN2 explicit SNAT missing"
fi

if iptables -t mangle -S mwan3_rules 2>/dev/null | \
        grep -q -- '-p tcp -m mark --mark 0x0/0x3f00 -j mwan3_rule_web_sticky'; then
    pass "all-TCP web_sticky rule present"
else
    fail "all-TCP web_sticky rule missing (only 80/443?)"
fi

LAST=$(iptables -t mangle -S mwan3_hook 2>/dev/null | tail -1)
case "$LAST" in
    *mwan3_connected*)
        fail "mwan3_hook ends with mwan3_connected (overwrites class marks)"
        ;;
    *)
        pass "mwan3_hook tail is CONNMARK save-mark"
        ;;
esac

HASH=$(sysctl -n net.ipv4.fib_multipath_hash_policy 2>/dev/null)
if [ "$HASH" = "0" ]; then
    pass "fib_multipath_hash_policy=0 (L3 hash)"
else
    fail "fib_multipath_hash_policy=${HASH:-?} (expected 0)"
fi

if [ -r /sys/kernel/debug/hnat/hnat_entry ]; then
    NAPT=$(grep -c NAPT /sys/kernel/debug/hnat/hnat_entry 2>/dev/null)
    if [ "${NAPT:-0}" = "0" ]; then
        pass "HNAT NAPT entries=0"
    else
        fail "HNAT NAPT entries=${NAPT} (hardware offload on)"
    fi
else
    info "HNAT debugfs not available; skipped"
fi

# ---------------------------------------------------------------------------
section "4. DNS"
for d in www.baidu.com api.bilibili.com lol.qq.com game.gtimg.cn pan.quark.cn; do
    a=$(nslookup "$d" 2>/dev/null | awk '/^Address:/{v=$2} END{print v}')
    if [ -n "$a" ]; then
        pass "DNS $d -> $a"
    else
        fail "DNS $d failed"
    fi
done
FAAAA=$(uci -q get dhcp.@dnsmasq[0].filter_aaaa 2>/dev/null)
if [ "$FAAAA" = "1" ]; then
    pass "dnsmasq filter_aaaa=1 (IPv4-only)"
else
    warn "dnsmasq filter_aaaa=${FAAAA:-unset}"
fi

# ---------------------------------------------------------------------------
section "5. Web / app / CDN"
for dev in eth1 eth0.2; do
    http_strict "$dev" "https://www.baidu.com/" 1000 "baidu"
    http_strict "$dev" "https://api.bilibili.com/x/web-interface/popular" 500 "bilibili-api"
    http_strict "$dev" "https://game.gtimg.cn/images/lol/act/img/champion/Aatrox.png" 15000 "lol-icon"
    http_reach  "$dev" "https://www.wegame.com.cn/" "wegame"
    http_reach  "$dev" "https://www.zhihu.com/" "zhihu"
    http_reach  "$dev" "https://www.taobao.com/" "taobao"
    http_reach  "$dev" "https://www.jd.com/" "jd"
    http_reach  "$dev" "https://www.qq.com/" "qq"
    http_reach  "$dev" "https://www.weibo.com/" "weibo"
    http_reach  "$dev" "https://arena.5eplay.com/" "5eplay"
    http_reach  "$dev" "https://store.steampowered.com/" "steam"
done

if [ "$QUICK" -eq 0 ]; then
    for dev in eth1 eth0.2; do
        http_strict "$dev" \
            "https://game.gtimg.cn/images/lol/act/img/skin/big1000.jpg" \
            100000 "lol-skin-104k"
    done

    section "5b. WAN throughput (10MB range)"
    for dev in eth1 eth0.2; do
        out=$(curl -m 20 -r 0-10485759 -o /dev/null -sS --interface "$dev" \
            -w '%{http_code} %{size_download} %{speed_download}' \
            "https://mirrors.aliyun.com/ubuntu/ls-lR.gz" 2>/dev/null)
        set -- $out
        code=${1:-000}
        bytes=${2:-0}
        speed=${3:-0}
        mb=$(awk -v s="$speed" 'BEGIN{printf "%.1f", s/1048576}')
        if [ "$code" = "206" ] && [ "$bytes" -ge 10485760 ]; then
            pass "$dev throughput ${mb} MB/s (10MB range)"
        else
            warn "$dev throughput: HTTP $code ${bytes}B ${mb} MB/s"
        fi
    done
fi

# ---------------------------------------------------------------------------
section "5c. Covers / images / video nodes"

# Bilibili: cover from the live popular feed, then a 256KB video segment.
BJ=$(curl -m 10 -sS -H "User-Agent: $UA" \
    "https://api.bilibili.com/x/web-interface/popular?ps=1&pn=1" 2>/dev/null)
BPIC=$(printf '%s' "$BJ" | grep -o '"pic":"[^"]*"' | head -1 | cut -d'"' -f4 | \
    sed 's#^http:#https:#')
if [ -n "$BPIC" ]; then
    for dev in eth1 eth0.2; do
        fetch_check "$dev" "$BPIC" 20000 "bilibili-cover"
    done
else
    warn "bilibili cover URL not found"
fi

BV=$(printf '%s' "$BJ" | grep -o '"bvid":"[^"]*"' | head -1 | cut -d'"' -f4)
CID=$(printf '%s' "$BJ" | grep -o '"cid":[0-9]*' | head -1 | cut -d: -f2)
if [ -n "$BV" ] && [ -n "$CID" ]; then
    PJ=$(curl -m 10 -sS -H "User-Agent: $UA" -H "Referer: https://www.bilibili.com/" \
        "https://api.bilibili.com/x/player/playurl?bvid=$BV&cid=$CID&qn=64&fnval=16" 2>/dev/null)
    VURL=$(printf '%s' "$PJ" | grep -o '"baseUrl":"[^"]*"' | head -1 | \
        cut -d'"' -f4 | sed 's#\\/#/#g; s/\\u0026/\&/g')
    if [ -n "$VURL" ]; then
        for dev in eth1 eth0.2; do
            fetch_check "$dev" "$VURL" 262144 "bilibili-video-256k" \
                -r 0-262143 -H "Referer: https://www.bilibili.com/"
        done
    else
        warn "bilibili video URL not found"
    fi
else
    warn "bilibili bvid/cid not found"
fi

# Zhihu Daily cover
ZJ=$(curl -m 10 -sS -H "User-Agent: $UA" \
    "https://daily.zhihu.com/api/4/news/latest" 2>/dev/null)
ZIMG=$(printf '%s' "$ZJ" | grep -o 'https:\\/\\/[^"]*zhimg[^"]*' | head -1 | \
    sed 's#\\/#/#g')
if [ -n "$ZIMG" ]; then
    for dev in eth1 eth0.2; do
        fetch_check "$dev" "$ZIMG" 5000 "zhihu-cover"
    done
else
    warn "zhihu cover URL not found"
fi

# Weibo/Sina image CDN
SJ=$(curl -m 10 -sS -H "User-Agent: $UA" \
    "https://feed.mix.sina.com.cn/api/roll/get?pageid=153&lid=2516&k=&num=1&page=1" 2>/dev/null)
SIMG=$(printf '%s' "$SJ" | grep -o '"u":"[^"]*"' | head -1 | cut -d'"' -f4 | \
    sed 's#\\/#/#g; s#^http:#https:#')
if [ -n "$SIMG" ]; then
    for dev in eth1 eth0.2; do
        fetch_check "$dev" "$SIMG" 20000 "weibo-sina-cover"
    done
else
    warn "sina/weibo image URL not found"
fi

# Taobao banner
TJ=$(curl -m 10 -sS -H "User-Agent: $UA" "https://www.taobao.com/" 2>/dev/null)
TIMG=$(printf '%s' "$TJ" | grep -o 'https://img.alicdn.com/[^" ]*' | head -1)
if [ -n "$TIMG" ]; then
    for dev in eth1 eth0.2; do
        fetch_check "$dev" "$TIMG" 20000 "taobao-banner"
    done
else
    warn "taobao image URL not found"
fi

# Steam cover (Akamai CDN, ~34KB)
for dev in eth1 eth0.2; do
    fetch_check "$dev" \
        "https://cdn.akamai.steamstatic.com/steam/apps/730/header.jpg" \
        20000 "steam-cover"
done

# ---------------------------------------------------------------------------
section "5d. WeChat official account"
WX_URL="https://mp.weixin.qq.com/s/ZXWzimnS7SQVynOomP6v8g"
WX_TMP="/tmp/test_network.wx.$$"

for dev in eth1 eth0.2; do
    fetch_check "$dev" "https://mp.weixin.qq.com/" 20000 "wechat-home"
done

curl -m 30 --interface eth1 -sS -H "User-Agent: $UA" -o "$WX_TMP" "$WX_URL" 2>/dev/null
WX_SIZE=$(wc -c < "$WX_TMP" 2>/dev/null)
WX_SIZE=${WX_SIZE:-0}
if [ "$WX_SIZE" -ge 200000 ]; then
    pass "wechat article via eth1: HTML ${WX_SIZE}B"
else
    warn "wechat article via eth1: only ${WX_SIZE}B (article may be removed)"
fi
fetch_check eth0.2 "$WX_URL" 200000 "wechat-article"

WIMG=$(grep -o 'https://mmbiz.qpic.cn/[^\\"]*' "$WX_TMP" 2>/dev/null | head -1)
if [ -n "$WIMG" ]; then
    for dev in eth1 eth0.2; do
        fetch_check "$dev" "$WIMG" 20000 "wechat-mmbiz-image" \
            -r 0-262143 -H "Referer: https://mp.weixin.qq.com/"
    done
else
    warn "no mmbiz image found in wechat article"
fi
rm -f "$WX_TMP"

# ---------------------------------------------------------------------------
section "6. Quark / video CDN"
for dev in eth1 eth0.2; do
    http_strict "$dev" "https://pan.quark.cn/" 5000 "quark-pan"
done
info "If Quark video buffers, rerun with --client <LAN-IP> while it plays."

# ---------------------------------------------------------------------------
section "7. Game UDP"
GP=$(iptables -t mangle -L mwan3_rules -v -n 2>/dev/null | \
    awk '/mwan3_rule_game_udp/ {print $1; exit}')
info "game_udp rule matched ${GP:-0} packets since boot"

awk '
{
    proto=$3; mark=""; dp="";
    for (i=1;i<=NF;i++) {
        if ($i ~ /^mark=/) mark=substr($i,6);
        if ($i ~ /^dport=/ && dp=="") dp=substr($i,7);
    }
    if (proto != "udp" || mark == "") next;
    d=dp+0;
    if (d==3074 || (d>=5000 && d<=5500) || (d>=7000 && d<=9000) || \
        (d>=27000 && d<=27100) || (d>=10000 && d<=20000)) {
        printf "GAME %s %s\n", mark, d;
    }
}' /proc/net/nf_conntrack > /tmp/test_network.game.$$
if [ -s /tmp/test_network.game.$$ ]; then
    N=$(wc -l < /tmp/test_network.game.$$)
    BAD=$(grep -vc '^GAME 256 ' /tmp/test_network.game.$$)
    if [ "${BAD:-0}" = "0" ]; then
        pass "${N} game UDP connections, all mark 0x100 (WAN1)"
    else
        warn "${BAD}/${N} game UDP connections are not on WAN1"
    fi
else
    info "no active game UDP connections"
fi
rm -f /tmp/test_network.game.$$

# ---------------------------------------------------------------------------
section "8. Classification / per-client consistency"
if ipset list mwan3_sticky_v4_web_sticky >/dev/null 2>&1; then
    N=$(ipset list mwan3_sticky_v4_web_sticky 2>/dev/null | \
        awk '/Number of entries/{print $4}')
    info "sticky assignments: ${N:-0}"
fi

awk '
{
    src=""; dst=""; mark="";
    for (i=1;i<=NF;i++) {
        if ($i ~ /^src=/ && src=="") src=substr($i,5);
        if ($i ~ /^dst=/ && dst=="") dst=substr($i,5);
        if ($i ~ /^mark=/) mark=substr($i,6);
    }
    if (src !~ /^192\.168\.6\./ || mark=="") next;
    total[src]++;
    if (mark=="256") w1[src]++;
    else if (mark=="512") w2[src]++;
    else if (mark=="768") bulk[src]++;
    else if (mark=="16128") conn[src]++;
    if ((mark=="256" || mark=="512") && dst!="") {
        key=src"|"dst;
        if (mark=="256") d1[key]=1; else d2[key]=1;
    }
}
END {
    for (k in total)
        printf "CLIENT %s %d %d %d %d\n", k, w1[k], w2[k], bulk[k], conn[k];
    for (k in d1) if (k in d2) printf "SPLITDST %s\n", k;
}' /proc/net/nf_conntrack > /tmp/test_network.ct.$$

grep '^CLIENT ' /tmp/test_network.ct.$$ | while read -r _ ip a b c d; do
    printf '[INFO] %s: WAN1=%s WAN2=%s bulk=%s connected=%s\n' \
        "$ip" "$a" "$b" "$c" "$d"
done

grep '^SPLITDST ' /tmp/test_network.ct.$$ | sed 's/^SPLITDST //' \
    > /tmp/test_network.split.$$
if [ -s /tmp/test_network.split.$$ ]; then
    while read -r k; do
        warn "same destination has both WAN1/WAN2 marks: $k (old connections may linger)"
    done < /tmp/test_network.split.$$
else
    pass "no same-destination WAN split in current conntrack"
fi

awk '$1=="CLIENT" && $3>0 && $4>0 {print $2}' /tmp/test_network.ct.$$ \
    > /tmp/test_network.client.$$
if [ -s /tmp/test_network.client.$$ ]; then
    while read -r ip; do
        warn "$ip has both WAN1 and WAN2 TCP connections (restart the app to confirm)"
    done < /tmp/test_network.client.$$
else
    pass "no client has both WAN1 and WAN2 TCP connections"
fi

CUR=$(iptables -t mangle -L WEB_BULK_CHECK -v -n 2>/dev/null | \
    awk '/MARK/ {print $1; exit}')
CUR=${CUR:-0}
if [ -f /tmp/test_network.bulk ]; then
    PREV=$(cat /tmp/test_network.bulk 2>/dev/null)
    PREV=${PREV:-0}
    if [ "$CUR" -ge "$PREV" ]; then
        DELTA=$((CUR - PREV))
        info "bulk 0x300 marks: total=${CUR}, since last run=${DELTA}"
        if [ "$DELTA" -gt 50 ]; then
            warn "bulk classifier fired ${DELTA} times since last run"
        fi
    else
        info "bulk 0x300 marks: total=${CUR} (counter reset)"
    fi
else
    info "bulk 0x300 marks: total=${CUR} (first run)"
fi
echo "$CUR" > /tmp/test_network.bulk
rm -f /tmp/test_network.ct.$$ /tmp/test_network.split.$$ /tmp/test_network.client.$$

# ---------------------------------------------------------------------------
section "9. Recent logs"
N=$(logread 2>/dev/null | grep -c 'failed for target')
if [ "${N:-0}" -gt 0 ]; then
    warn "mwan3track ping failures in log buffer: ${N}"
else
    pass "no mwan3track ping failures in log buffer"
fi

N=$(logread 2>/dev/null | grep -c 'EAP-Failure')
if [ "${N:-0}" -gt 0 ]; then
    warn "auth EAP-Failure in log buffer: ${N}"
else
    pass "no auth EAP-Failure in log buffer"
fi

WN=$(logread 2>/dev/null | grep 'kern.err' | grep -c '7981@')
if [ "${WN:-0}" -gt 0 ]; then
    info "WiFi driver noise 7981@: ${WN} (RRM/extension IE, harmless)"
fi
N=$(logread 2>/dev/null | grep 'kern.err' | grep -v '7981@' | wc -l)
if [ "${N:-0}" -gt 0 ]; then
    warn "non-WiFi kernel errors in log buffer: ${N}"
else
    pass "no non-WiFi kernel errors in log buffer"
fi

# ---------------------------------------------------------------------------
if [ -n "$CLIENT" ]; then
    section "10. Client $CLIENT"
    ipset list mwan3_sticky_v4_web_sticky 2>/dev/null | grep "^$CLIENT,"
    awk -v ip="$CLIENT" '
    {
        src=""; dst=""; dp=""; mark="";
        for (i=1;i<=NF;i++) {
            if ($i ~ /^src=/ && src=="") src=substr($i,5);
            if ($i ~ /^dst=/ && dst=="") dst=substr($i,5);
            if ($i ~ /^dport=/ && dp=="") dp=substr($i,7);
            if ($i ~ /^mark=/) mark=substr($i,6);
        }
        if (src==ip)
            printf "%s -> %s:%s mark=%s\n", $3, dst, dp, mark;
    }' /proc/net/nf_conntrack | sort | head -40
fi

# ---------------------------------------------------------------------------
printf '\n=== Summary ===\n'
printf 'PASS=%d WARN=%d FAIL=%d\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 125 ]; then
    exit 125
fi
exit "$FAIL"
