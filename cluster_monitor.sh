#!/usr/bin/env bash
# ==============================================================================
#  CLUSTER HEALTH MONITOR  —  Mixed Linux Edition
#  Version : 3.0
#  Author  : You
#
#  Usage:
#    ./cluster_monitor.sh              # Console output only
#    ./cluster_monitor.sh --email      # Email ONLY when alerts/issues found
#    ./cluster_monitor.sh --email --always-mail  # Email regardless
#    ./cluster_monitor.sh --quiet      # No terminal output (cron-safe)
#
#  Cron example (every 30 min, email on issues only):
#    */30 * * * * /opt/scripts/cluster_monitor.sh --email --quiet
#
#  Requirements:
#    - Passwordless SSH to all nodes
#    - mutt or mail installed on monitoring host (for --email)
#    - bc, awk, ssh available on monitoring host
# ==============================================================================

# ──────────────────────────────────────────────────────────────────────────────
#  ★  CONFIGURE THIS SECTION
# ──────────────────────────────────────────────────────────────────────────────

## ── Cluster Nodes ─────────────────────────────────────────────────────────
SERVERS=(
    "192.168.1.10"
    "192.168.1.11"
    "192.168.1.12"
    # "hostname-or-ip"   # add more here
)

## ── SSH Settings ──────────────────────────────────────────────────────────
SSH_USER="root"             # Must have passwordless SSH access
SSH_PORT="22"
SSH_TIMEOUT=10              # Seconds before giving up on a node
SSH_KEY=""                  # e.g. /home/user/.ssh/id_rsa  (leave "" for default)

## ── Alert Thresholds ──────────────────────────────────────────────────────
CPU_WARN=75       ; CPU_CRIT=90        # CPU usage %
MEM_WARN=80       ; MEM_CRIT=95        # RAM usage %
SWAP_WARN=40      ; SWAP_CRIT=75       # Swap usage %
DISK_WARN=80      ; DISK_CRIT=92       # Disk partition usage %
LOAD_WARN_MULT=2  ; LOAD_CRIT_MULT=4  # Load15 = cores x multiplier
NET_WARN_MB=800   ; NET_CRIT_MB=950    # Network throughput MB/s (per iface)

## ── Custom Services to Check ──────────────────────────────────────────────
#  Script auto-detects if each is installed; skips if not present on a node.
CUSTOM_SERVICES=(
    "nginx"
    "apache2"
    "httpd"
    "mysql"
    "mariadb"
    "postgresql"
    "redis"
    "redis-server"
    "docker"
    "sshd"
    "firewalld"
    "ufw"
)

## ── Email Settings ────────────────────────────────────────────────────────
EMAIL_TO="admin@yourdomain.com"
EMAIL_FROM="cluster-monitor@yourdomain.com"
EMAIL_SUBJECT_ALERT="[ALERT] Cluster Health Issues -- $(date '+%d %b %Y %H:%M')"
EMAIL_SUBJECT_OK="[OK] Cluster Health Report -- $(date '+%d %b %Y %H:%M')"

## ── Report Directory ──────────────────────────────────────────────────────
REPORT_DIR="/tmp/cluster_reports"

# ──────────────────────────────────────────────────────────────────────────────
#  INTERNALS
# ──────────────────────────────────────────────────────────────────────────────

R='\033[0;31m'  ; LR='\033[1;31m'
G='\033[0;32m'  ; LG='\033[1;32m'
Y='\033[1;33m'
C='\033[0;36m'  ; LC='\033[1;36m'
B='\033[0;34m'
W='\033[1;37m'  ; GR='\033[0;37m'
BO='\033[1m'    ; RS='\033[0m'

SEND_EMAIL=false
ALWAYS_MAIL=false
QUIET=false

TS=$(date '+%Y%m%d_%H%M%S')
HTML_REPORT="${REPORT_DIR}/report_${TS}.html"
TEXT_REPORT="${REPORT_DIR}/report_${TS}.txt"
TOTAL=0 ; HEALTHY=0 ; WARN_CT=0 ; CRIT_CT=0 ; DOWN_CT=0
HAS_ISSUES=false
declare -A SRV_STATUS

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=${SSH_TIMEOUT} -o BatchMode=yes -o LogLevel=ERROR"

# ──────────────────────────────────────────────────────────────────────────────
#  ARG PARSING
# ──────────────────────────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --email)        SEND_EMAIL=true ;;
        --always-mail)  SEND_EMAIL=true; ALWAYS_MAIL=true ;;
        --quiet)        QUIET=true ;;
        --help|-h)
            echo "Usage: $0 [--email] [--always-mail] [--quiet]"
            echo "  --email        Email when issues detected (threshold-based)"
            echo "  --always-mail  Email regardless of cluster health"
            echo "  --quiet        Suppress terminal output"
            echo "Exit: 0=healthy  1=warnings  2=critical/down"
            exit 0 ;;
    esac
done

# ──────────────────────────────────────────────────────────────────────────────
#  HELPERS
# ──────────────────────────────────────────────────────────────────────────────

out() { [[ "$QUIET" == false ]] && echo -e "$*"; }

ssh_cmd() {
    local host="$1"; shift
    local key_opt=""
    [[ -n "$SSH_KEY" ]] && key_opt="-i ${SSH_KEY}"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS $key_opt -p "${SSH_PORT}" "${SSH_USER}@${host}" "$@" 2>/dev/null
}

fge() { (( $(echo "$1 >= $2" | bc -l 2>/dev/null || echo 0) )); }

get_status() {
    local val="$1" warn="$2" crit="$3"
    fge "$val" "$crit" && echo "CRITICAL" && return
    fge "$val" "$warn" && echo "WARNING"  && return
    echo "OK"
}

cstatus() {
    case "$1" in
        CRITICAL) echo -e "${LR}X CRITICAL${RS}" ;;
        WARNING)  echo -e "${Y}! WARNING${RS}"   ;;
        OK)       echo -e "${LG}v OK${RS}"        ;;
        RUNNING)  echo -e "${LG}> RUNNING${RS}"   ;;
        STOPPED)  echo -e "${R}# STOPPED${RS}"    ;;
        *)        echo -e "${GR}$1${RS}"           ;;
    esac
}

bclass() {
    local v=$1 w=$2 c=$3
    fge "${v:-0}" "$c" && echo "crit" && return
    fge "${v:-0}" "$w" && echo "warn" && return
    echo "ok"
}

setup() { mkdir -p "$REPORT_DIR"; : > "$TEXT_REPORT"; }

# ──────────────────────────────────────────────────────────────────────────────
#  BANNER
# ──────────────────────────────────────────────────────────────────────────────

print_banner() {
    out ""
    out "${BO}${LC}+==================================================================+${RS}"
    out "${BO}${LC}|   CLUSTER HEALTH MONITOR  v3.0  --  Mixed Linux Edition          |${RS}"
    out "${BO}${LC}|   $(date '+%A, %d %B %Y  at  %H:%M:%S')                              |${RS}"
    out "${BO}${LC}+==================================================================+${RS}"
    out ""
}

# ──────────────────────────────────────────────────────────────────────────────
#  HTML
# ──────────────────────────────────────────────────────────────────────────────

html_start() {
    cat > "$HTML_REPORT" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Cluster Health Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#0d1117;color:#c9d1d9;font-size:14px;line-height:1.5}
.hdr{background:linear-gradient(135deg,#161b22 0%,#1c2a3a 100%);border-bottom:1px solid #30363d;padding:22px 32px;display:flex;align-items:center;gap:14px}
.hdr h1{font-size:20px;font-weight:700;color:#e6edf3;flex:1}
.hdr .ts{font-size:12px;color:#8b949e;white-space:nowrap}
.sumbar{display:flex;gap:0;background:#161b22;border-bottom:1px solid #21262d}
.sc{flex:1;padding:16px 24px;text-align:center;border-right:1px solid #21262d}
.sc:last-child{border-right:none}
.sc .n{font-size:28px;font-weight:700;line-height:1}
.sc .l{font-size:11px;text-transform:uppercase;letter-spacing:.8px;opacity:.55;margin-top:4px}
.sc.total .n{color:#79c0ff}.sc.ok .n{color:#56d364}.sc.warn .n{color:#f0b429}.sc.crit .n{color:#f85149}.sc.down .n{color:#6e7681}
.node{margin:20px 28px;border:1px solid #21262d;border-radius:10px;overflow:hidden;background:#161b22}
.node-hdr{display:flex;align-items:center;gap:10px;padding:14px 18px;background:#1c2333;border-bottom:1px solid #21262d}
.node-hdr h2{font-size:15px;font-weight:600;color:#e6edf3;margin:0}
.node-hdr .ip{font-size:12px;color:#8b949e;margin-left:4px}
.node-hdr .os-badge{font-size:11px;background:#21262d;padding:2px 8px;border-radius:12px;color:#8b949e;white-space:nowrap}
.node-hdr .st-badge{margin-left:auto;font-size:11px;font-weight:700;padding:3px 12px;border-radius:12px;white-space:nowrap}
.st-badge.ok{background:#1a3a2a;color:#56d364;border:1px solid #2ea043}
.st-badge.warn{background:#362a00;color:#f0b429;border:1px solid #9e6a03}
.st-badge.crit{background:#3d0f0f;color:#f85149;border:1px solid #b91c1c}
.st-badge.down{background:#1c2333;color:#6e7681;border:1px solid #30363d}
.meta{padding:8px 18px;font-size:12px;color:#6e7681;background:#161b22;border-bottom:1px solid #21262d;display:flex;flex-wrap:wrap;gap:18px}
.meta span strong{color:#8b949e}
.mgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:12px;padding:16px 18px}
.metric{background:#0d1117;border:1px solid #21262d;border-radius:8px;padding:14px}
.metric .mlabel{font-size:10px;text-transform:uppercase;letter-spacing:.8px;color:#6e7681;margin-bottom:6px}
.metric .mval{font-size:22px;font-weight:700}
.metric .msub{font-size:11px;color:#6e7681;margin-top:2px}
.metric.ok .mval{color:#56d364}.metric.warn .mval{color:#f0b429}.metric.crit .mval{color:#f85149}
.metric.info .mval{color:#79c0ff}.metric.neu .mval{color:#c9d1d9}
.pbar{height:4px;background:#21262d;border-radius:2px;margin-top:8px;overflow:hidden}
.pfill{height:100%;border-radius:2px}
.pfill.ok{background:#2ea043}.pfill.warn{background:#9e6a03}.pfill.crit{background:#b91c1c}
.sec{padding:0 18px 16px}
.sec-title{font-size:11px;text-transform:uppercase;letter-spacing:.8px;color:#6e7681;padding:12px 0 8px;border-top:1px solid #21262d;margin-bottom:0}
table{width:100%;border-collapse:collapse;font-size:13px}
th{background:#0d1117;padding:7px 12px;text-align:left;font-size:10px;text-transform:uppercase;letter-spacing:.6px;color:#6e7681;font-weight:500}
td{padding:6px 12px;border-bottom:1px solid #161b22}
tr:last-child td{border-bottom:none}
tr:hover td{background:#1c2333}
.badge-ok{color:#56d364;font-weight:600}.badge-warn{color:#f0b429;font-weight:600}
.badge-crit{color:#f85149;font-weight:600}.badge-down{color:#6e7681;font-weight:600}.badge-info{color:#79c0ff;font-weight:600}
.alerts{margin:0 18px 14px;padding:12px 16px;background:#1a0f0f;border:1px solid #b91c1c;border-radius:8px;font-size:13px;color:#f85149}
.alerts .al-title{font-weight:700;margin-bottom:6px}
.alerts ul{padding-left:18px}
.node-down{padding:24px;text-align:center;color:#6e7681;font-size:15px}
.sgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:8px;padding:0 0 4px}
.svc{display:flex;align-items:center;gap:8px;padding:7px 10px;background:#0d1117;border:1px solid #21262d;border-radius:6px;font-size:12px}
.svc .sdot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.sdot.run{background:#2ea043}.sdot.stop{background:#f85149}.sdot.abs{background:#30363d}
.footer{text-align:center;padding:20px;font-size:11px;color:#30363d}
</style>
</head>
<body>
EOF
}

html_end() {
    echo "<div class='footer'>Cluster Health Monitor v3.0 &nbsp;|&nbsp; $(date '+%d %b %Y %H:%M:%S')</div></body></html>" >> "$HTML_REPORT"
}

hline() { echo "$*" >> "$HTML_REPORT"; }

# ──────────────────────────────────────────────────────────────────────────────
#  REMOTE PROBE  (runs on each target server via SSH)
# ──────────────────────────────────────────────────────────────────────────────

REMOTE_PROBE=$(cat << 'PROBE'
#!/bin/bash
[[ -f /etc/os-release ]] && . /etc/os-release
DISTRO_NAME="${PRETTY_NAME:-Unknown Linux}"
KERNEL=$(uname -r)
HOSTNAME_F=$(hostname -f 2>/dev/null || hostname)
ARCH=$(uname -m)
UPTIME_SECS=$(awk '{print int($1)}' /proc/uptime)
UPTIME_DAYS=$(( UPTIME_SECS / 86400 ))
UPTIME_HRS=$(( (UPTIME_SECS % 86400) / 3600 ))
UPTIME_MIN=$(( (UPTIME_SECS % 3600) / 60 ))
UPTIME_HUMAN="${UPTIME_DAYS}d ${UPTIME_HRS}h ${UPTIME_MIN}m"
LAST_REBOOT=$(who -b 2>/dev/null | awk '{print $3" "$4}' | head -1)
[[ -z "$LAST_REBOOT" ]] && LAST_REBOOT=$(uptime -s 2>/dev/null || echo "N/A")

CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
CPU_MODEL=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)
read LOAD1 LOAD5 LOAD15 _ < /proc/loadavg

# CPU % via /proc/stat 1-sec delta
read _cpu u n s id wa hi si st _ < /proc/stat
sleep 1
read _cpu2 u2 n2 s2 id2 wa2 hi2 si2 st2 _ < /proc/stat
IDLE=$(( (id2+wa2)-(id+wa) ))
TOTAL_J=$(( (u2+n2+s2+id2+wa2+hi2+si2+st2)-(u+n+s+id+wa+hi+si+st) ))
(( TOTAL_J > 0 )) && CPU_USE=$(awk "BEGIN{printf \"%.1f\",100-($IDLE*100.0/$TOTAL_J)}") || CPU_USE="0.0"

MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_AVAIL=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
MEM_USED=$(( MEM_TOTAL - MEM_AVAIL ))
MEM_PCT=$(awk "BEGIN{printf \"%.1f\",$MEM_USED*100/$MEM_TOTAL}")
MEM_USED_H=$(awk "BEGIN{printf \"%.1f\",$MEM_USED/1048576}")
MEM_TOTAL_H=$(awk "BEGIN{printf \"%.1f\",$MEM_TOTAL/1048576}")
MEM_AVAIL_H=$(awk "BEGIN{printf \"%.1f\",$MEM_AVAIL/1048576}")

SWAP_TOTAL=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
SWAP_FREE=$(awk '/SwapFree/{print $2}'   /proc/meminfo)
SWAP_USED=$(( SWAP_TOTAL - SWAP_FREE ))
if (( SWAP_TOTAL > 0 )); then
    SWAP_PCT=$(awk "BEGIN{printf \"%.1f\",$SWAP_USED*100/$SWAP_TOTAL}")
    SWAP_USED_H=$(awk  "BEGIN{printf \"%.1f\",$SWAP_USED/1048576}")
    SWAP_TOTAL_H=$(awk "BEGIN{printf \"%.1f\",$SWAP_TOTAL/1048576}")
else SWAP_PCT=0; SWAP_USED_H=0; SWAP_TOTAL_H=0; fi

DISK_DATA=$(df -PlT 2>/dev/null | awk 'NR>1 && $2!="tmpfs" && $2!="devtmpfs" && $2!="overlay" && $2!="squashfs" {
    pct=$6; gsub(/%/,"",pct); printf "%s|%s|%s|%s|%s|%s\n",$7,$2,$3,$4,$5,pct}')

# Network 1-sec RX/TX rate
declare -A RX1 TX1
while IFS=: read iface stats; do
    iface=$(echo "$iface"|xargs); [[ "$iface" == "lo" ]] && continue
    RX1[$iface]=$(echo "$stats"|awk '{print $1}')
    TX1[$iface]=$(echo "$stats"|awk '{print $9}')
done < <(grep -v "Inter\|face\|lo:" /proc/net/dev)
sleep 1
NET_DATA=""
while IFS=: read iface stats; do
    iface=$(echo "$iface"|xargs); [[ "$iface" == "lo" ]] && continue
    rx2=$(echo "$stats"|awk '{print $1}'); tx2=$(echo "$stats"|awk '{print $9}')
    rx_mb=$(awk "BEGIN{printf \"%.3f\",(${rx2}-${RX1[$iface]:-0})/1048576}")
    tx_mb=$(awk "BEGIN{printf \"%.3f\",(${tx2}-${TX1[$iface]:-0})/1048576}")
    ip_addr=$(ip -4 addr show "$iface" 2>/dev/null|awk '/inet /{print $2}'|head -1)
    [[ -z "$ip_addr" ]] && ip_addr="no-ipv4"
    NET_DATA+="${iface}|${ip_addr}|${rx_mb}|${tx_mb}\n"
done < <(grep -v "Inter\|face\|lo:" /proc/net/dev)

REBOOT_HIST=$(last reboot 2>/dev/null | head -6 | awk '{if(NF>3) print $1"|"$5" "$6" "$7" "$8}')

FAILED_UNITS=$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null | awk '{print $1}' | paste -sd, -)
[[ -z "$FAILED_UNITS" ]] && FAILED_UNITS="none"

if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    DOCKER_RUN=$(docker ps -q 2>/dev/null | wc -l)
    DOCKER_STOP=$(docker ps -q --filter status=exited 2>/dev/null | wc -l)
    DOCKER_TOT=$(docker ps -aq 2>/dev/null | wc -l)
    DOCKER_STATS=$(docker stats --no-stream --format "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.Status}}" 2>/dev/null | head -8)
    DOCKER_AVAIL="yes"
else
    DOCKER_AVAIL="no"; DOCKER_RUN=0; DOCKER_STOP=0; DOCKER_TOT=0; DOCKER_STATS=""
fi

SVC_DATA=""
for svc in nginx apache2 httpd mysql mariadb postgresql redis redis-server docker sshd firewalld ufw; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1 | grep -q "$svc"; then
        state=$(systemctl is-active "$svc" 2>/dev/null)
        enabled=$(systemctl is-enabled "$svc" 2>/dev/null)
        SVC_DATA+="${svc}|${state}|${enabled}\n"
    fi
done

TOP_CPU=$(ps aux --sort=-%cpu 2>/dev/null | awk 'NR>1&&NR<=6{cmd=$11;for(i=12;i<=NF&&i<15;i++)cmd=cmd" "$i; printf "%s|%s|%s\n",cmd,$3,$4}')
TOP_MEM=$(ps aux --sort=-%mem 2>/dev/null | awk 'NR>1&&NR<=6{cmd=$11;for(i=12;i<=NF&&i<15;i++)cmd=cmd" "$i; printf "%s|%s|%s\n",cmd,$3,$4}')

echo "HOSTNAME=${HOSTNAME_F}"
echo "DISTRO=${DISTRO_NAME}"
echo "KERNEL=${KERNEL}"
echo "ARCH=${ARCH}"
echo "CPU_CORES=${CPU_CORES}"
echo "CPU_MODEL=${CPU_MODEL}"
echo "LOAD1=${LOAD1}"
echo "LOAD5=${LOAD5}"
echo "LOAD15=${LOAD15}"
echo "CPU_USE=${CPU_USE}"
echo "MEM_PCT=${MEM_PCT}"
echo "MEM_USED_H=${MEM_USED_H}"
echo "MEM_TOTAL_H=${MEM_TOTAL_H}"
echo "MEM_AVAIL_H=${MEM_AVAIL_H}"
echo "SWAP_PCT=${SWAP_PCT}"
echo "SWAP_USED_H=${SWAP_USED_H}"
echo "SWAP_TOTAL_H=${SWAP_TOTAL_H}"
echo "UPTIME_HUMAN=${UPTIME_HUMAN}"
echo "LAST_REBOOT=${LAST_REBOOT}"
echo "FAILED_UNITS=${FAILED_UNITS}"
echo "DOCKER_AVAIL=${DOCKER_AVAIL}"
echo "DOCKER_RUN=${DOCKER_RUN}"
echo "DOCKER_STOP=${DOCKER_STOP}"
echo "DOCKER_TOT=${DOCKER_TOT}"
echo "---DISK---"
echo "${DISK_DATA}"
echo "---NET---"
printf "%b" "${NET_DATA}"
echo "---REBOOT_HIST---"
echo "${REBOOT_HIST}"
echo "---SVC---"
printf "%b" "${SVC_DATA}"
echo "---DOCKER_STATS---"
echo "${DOCKER_STATS}"
echo "---TOP_CPU---"
echo "${TOP_CPU}"
echo "---TOP_MEM---"
echo "${TOP_MEM}"
echo "---END---"
PROBE
)

# ──────────────────────────────────────────────────────────────────────────────
#  PARSE BLOCK SECTION FROM RAW OUTPUT
# ──────────────────────────────────────────────────────────────────────────────

parse_block() {
    local raw="$1" start="$2" end="$3"
    echo "$raw" | awk "/^---${start}---/{f=1;next} /^---${end}---/{f=0} f{print}"
}

# ──────────────────────────────────────────────────────────────────────────────
#  CHECK ONE SERVER
# ──────────────────────────────────────────────────────────────────────────────

check_server() {
    local server="$1"
    TOTAL=$(( TOTAL + 1 ))
    local node_state="ok"
    local alerts=()

    out ""
    out "${BO}${W}  +-- Node: ${LC}${server}${RS}"

    # Connectivity
    if ! ssh_cmd "$server" "echo ok" &>/dev/null; then
        out "  ${LR}  X UNREACHABLE -- Cannot connect via SSH${RS}"
        SRV_STATUS[$server]="down"
        DOWN_CT=$(( DOWN_CT + 1 ))
        HAS_ISSUES=true
        {   echo ""
            echo "=================================================="
            echo "  SERVER: ${server}  |  UNREACHABLE"
            echo "=================================================="
        } >> "$TEXT_REPORT"
        hline "<div class='node'>"
        hline "  <div class='node-hdr'><h2>${server}</h2><span class='st-badge down'>UNREACHABLE</span></div>"
        hline "  <div class='node-down'>Cannot establish SSH connection</div>"
        hline "</div>"
        return
    fi

    # Run remote probe
    local raw
    raw=$(ssh_cmd "$server" bash <<< "$REMOTE_PROBE")

    if [[ -z "$raw" ]]; then
        out "  ${Y}  ! Connected but no data received${RS}"
        SRV_STATUS[$server]="warn"
        WARN_CT=$(( WARN_CT + 1 ))
        return
    fi

    # Parse key=value fields
    _v() { echo "$raw" | grep "^${1}=" | head -1 | cut -d= -f2-; }
    local HOSTNAME;     HOSTNAME=$(_v HOSTNAME)
    local DISTRO;       DISTRO=$(_v DISTRO)
    local KERNEL;       KERNEL=$(_v KERNEL)
    local ARCH;         ARCH=$(_v ARCH)
    local CPU_CORES;    CPU_CORES=$(_v CPU_CORES)
    local CPU_MODEL;    CPU_MODEL=$(_v CPU_MODEL)
    local LOAD1;        LOAD1=$(_v LOAD1)
    local LOAD5;        LOAD5=$(_v LOAD5)
    local LOAD15;       LOAD15=$(_v LOAD15)
    local CPU_USE;      CPU_USE=$(_v CPU_USE)
    local MEM_PCT;      MEM_PCT=$(_v MEM_PCT)
    local MEM_USED_H;   MEM_USED_H=$(_v MEM_USED_H)
    local MEM_TOTAL_H;  MEM_TOTAL_H=$(_v MEM_TOTAL_H)
    local MEM_AVAIL_H;  MEM_AVAIL_H=$(_v MEM_AVAIL_H)
    local SWAP_PCT;     SWAP_PCT=$(_v SWAP_PCT)
    local SWAP_USED_H;  SWAP_USED_H=$(_v SWAP_USED_H)
    local SWAP_TOTAL_H; SWAP_TOTAL_H=$(_v SWAP_TOTAL_H)
    local UPTIME_H;     UPTIME_H=$(_v UPTIME_HUMAN)
    local LAST_RBT;     LAST_RBT=$(_v LAST_REBOOT)
    local DOCKER_AVAIL; DOCKER_AVAIL=$(_v DOCKER_AVAIL)
    local DOCKER_RUN;   DOCKER_RUN=$(_v DOCKER_RUN)
    local DOCKER_STOP;  DOCKER_STOP=$(_v DOCKER_STOP)
    local DOCKER_TOT;   DOCKER_TOT=$(_v DOCKER_TOT)
    local FAILED_UNITS; FAILED_UNITS=$(_v FAILED_UNITS)

    # Parse blocks
    local DISK_BLK NET_BLK RBT_BLK SVC_BLK DCK_BLK TOP_CPU_BLK TOP_MEM_BLK
    DISK_BLK=$(parse_block    "$raw" "DISK"         "NET")
    NET_BLK=$(parse_block     "$raw" "NET"          "REBOOT_HIST")
    RBT_BLK=$(parse_block     "$raw" "REBOOT_HIST"  "SVC")
    SVC_BLK=$(parse_block     "$raw" "SVC"          "DOCKER_STATS")
    DCK_BLK=$(parse_block     "$raw" "DOCKER_STATS" "TOP_CPU")
    TOP_CPU_BLK=$(parse_block "$raw" "TOP_CPU"      "TOP_MEM")
    TOP_MEM_BLK=$(parse_block "$raw" "TOP_MEM"      "END")

    # Dynamic load thresholds based on core count
    local LOAD_WARN; LOAD_WARN=$(awk "BEGIN{printf \"%.1f\",${CPU_CORES:-1}*${LOAD_WARN_MULT}}")
    local LOAD_CRIT; LOAD_CRIT=$(awk "BEGIN{printf \"%.1f\",${CPU_CORES:-1}*${LOAD_CRIT_MULT}}")

    # Per-metric statuses
    local ST_CPU; ST_CPU=$(get_status "${CPU_USE:-0}"   "$CPU_WARN"   "$CPU_CRIT")
    local ST_MEM; ST_MEM=$(get_status "${MEM_PCT:-0}"   "$MEM_WARN"   "$MEM_CRIT")
    local ST_SWP; ST_SWP=$(get_status "${SWAP_PCT:-0}"  "$SWAP_WARN"  "$SWAP_CRIT")
    local ST_LOD; ST_LOD=$(get_status "${LOAD15:-0}"    "$LOAD_WARN"  "$LOAD_CRIT")

    # Worst disk partition
    local worst_disk=0 ST_DISK="OK"
    while IFS='|' read -r mnt fstype size used avail pct_num; do
        [[ -z "$mnt" || ! "$pct_num" =~ ^[0-9]+$ ]] && continue
        local ds; ds=$(get_status "$pct_num" "$DISK_WARN" "$DISK_CRIT")
        [[ "$ds" == "CRITICAL" ]] && ST_DISK="CRITICAL"
        [[ "$ds" == "WARNING" && "$ST_DISK" != "CRITICAL" ]] && ST_DISK="WARNING"
        (( pct_num > worst_disk )) && worst_disk=$pct_num
    done <<< "$DISK_BLK"

    # Failed systemd units
    local ST_UNIT="OK"
    [[ "$FAILED_UNITS" != "none" && -n "$FAILED_UNITS" ]] && ST_UNIT="CRITICAL"

    # Build alerts list
    [[ "$ST_CPU"  != "OK" ]] && alerts+=("CPU at ${CPU_USE}% [${ST_CPU}]")
    [[ "$ST_MEM"  != "OK" ]] && alerts+=("Memory at ${MEM_PCT}% [${ST_MEM}]")
    [[ "$ST_SWP"  != "OK" ]] && alerts+=("Swap at ${SWAP_PCT}% [${ST_SWP}]")
    [[ "$ST_LOD"  != "OK" ]] && alerts+=("Load15=${LOAD15} [${ST_LOD}] -- threshold ${LOAD_WARN}/${LOAD_CRIT}")
    [[ "$ST_DISK" != "OK" ]] && alerts+=("Disk partition at ${worst_disk}% [${ST_DISK}]")
    [[ "$ST_UNIT" != "OK" ]] && alerts+=("Failed systemd units: ${FAILED_UNITS}")

    # Check services
    while IFS='|' read -r svc state enabled; do
        [[ -z "$svc" ]] && continue
        [[ "$state" == "inactive" || "$state" == "failed" ]] && \
            alerts+=("Service ${svc} is ${state^^}")
    done <<< "$SVC_BLK"

    # Network alerts
    while IFS='|' read -r iface ip rx_mb tx_mb; do
        [[ -z "$iface" ]] && continue
        local net_st; net_st="OK"
        fge "$rx_mb" "$NET_CRIT_MB" && net_st="CRITICAL"
        fge "$rx_mb" "$NET_WARN_MB" && [[ "$net_st" != "CRITICAL" ]] && net_st="WARNING"
        [[ "$net_st" != "OK" ]] && alerts+=("Network ${iface} RX=${rx_mb} MB/s [${net_st}]")
    done <<< "$NET_BLK"

    # Overall node state
    for st in "$ST_CPU" "$ST_MEM" "$ST_SWP" "$ST_LOD" "$ST_DISK" "$ST_UNIT"; do
        [[ "$st" == "CRITICAL" ]] && node_state="crit" && break
        [[ "$st" == "WARNING"  ]] && node_state="warn"
    done
    [[ ${#alerts[@]} -gt 0 ]] && HAS_ISSUES=true
    SRV_STATUS[$server]="$node_state"
    case "$node_state" in
        crit) CRIT_CT=$(( CRIT_CT + 1 )) ;;
        warn) WARN_CT=$(( WARN_CT + 1 )) ;;
        ok)   HEALTHY=$(( HEALTHY + 1 ))  ;;
    esac

    # ── Terminal output ──────────────────────────────────────────────────────
    if [[ "$QUIET" == false ]]; then
        local state_lbl
        case "$node_state" in
            crit) state_lbl="${LR}X CRITICAL${RS}" ;;
            warn) state_lbl="${Y}! WARNING${RS}"   ;;
            *)    state_lbl="${LG}v OK${RS}"        ;;
        esac

        out "  ${GR}  Host  : ${W}${HOSTNAME}${RS}  |  ${GR}${DISTRO}  (${ARCH})${RS}"
        out "  ${GR}  Kernel: ${KERNEL}  |  CPUs: ${CPU_CORES}${RS}"
        out "  ${GR}  Uptime: ${UPTIME_H}  |  Last Reboot: ${LAST_RBT:-N/A}${RS}"
        out "  ${GR}  Status: ${state_lbl}${RS}"
        out ""
        out "  ${BO}CPU ${CPU_USE}% $(cstatus $ST_CPU)   RAM ${MEM_PCT}% $(cstatus $ST_MEM)   Swap ${SWAP_PCT}% $(cstatus $ST_SWP)   Load15=${LOAD15} $(cstatus $ST_LOD)${RS}"
        out "  ${GR}  Load: 1m=${LOAD1}  5m=${LOAD5}  15m=${LOAD15}  (cores=${CPU_CORES} warn>=${LOAD_WARN} crit>=${LOAD_CRIT})${RS}"
        out "  ${GR}  RAM : ${MEM_USED_H} GiB used / ${MEM_TOTAL_H} GiB total (${MEM_AVAIL_H} GiB free)${RS}"
        out "  ${GR}  Swap: ${SWAP_USED_H} GiB used / ${SWAP_TOTAL_H} GiB total${RS}"
        out ""

        # Disk
        out "  ${BO}${B}Disk Partitions:${RS}"
        printf "    ${GR}%-22s %-10s %5s  %-10s %-10s %-10s  Status${RS}\n" "Mount" "FS" "Use%" "Used" "Size" "Free"
        while IFS='|' read -r mnt fstype size used avail pct_num; do
            [[ -z "$mnt" || ! "$pct_num" =~ ^[0-9] ]] && continue
            local ds; ds=$(get_status "$pct_num" "$DISK_WARN" "$DISK_CRIT")
            printf "    ${GR}%-22s %-10s %4s%%  %-10s %-10s %-10s  %b${RS}\n" \
                "$mnt" "$fstype" "$pct_num" "$used" "$size" "$avail" "$(cstatus $ds)"
        done <<< "$DISK_BLK"
        out ""

        # Network
        out "  ${BO}${B}Network (1-sec live rate):${RS}"
        printf "    ${GR}%-14s %-20s  %-15s  %-15s  Status${RS}\n" "Interface" "IP" "RX (MB/s)" "TX (MB/s)"
        while IFS='|' read -r iface ip rx_mb tx_mb; do
            [[ -z "$iface" ]] && continue
            local net_st; net_st="OK"
            fge "$rx_mb" "$NET_CRIT_MB" && net_st="CRITICAL"
            fge "$rx_mb" "$NET_WARN_MB" && [[ "$net_st" != "CRITICAL" ]] && net_st="WARNING"
            printf "    ${GR}%-14s %-20s  %-15s  %-15s  %b${RS}\n" \
                "$iface" "$ip" "$rx_mb" "$tx_mb" "$(cstatus $net_st)"
        done <<< "$NET_BLK"
        out ""

        # Services
        out "  ${BO}${B}Services:${RS}"
        while IFS='|' read -r svc state enabled; do
            [[ -z "$svc" ]] && continue
            local sc; case "$state" in
                active)   sc="RUNNING"  ;;
                inactive) sc="STOPPED"  ;;
                failed)   sc="STOPPED"  ;;
                *)        sc="$state"   ;;
            esac
            printf "    ${GR}%-22s  %b  (enabled: %s)${RS}\n" "$svc" "$(cstatus $sc)" "$enabled"
        done <<< "$SVC_BLK"
        out ""

        # Docker
        if [[ "$DOCKER_AVAIL" == "yes" ]]; then
            out "  ${BO}${B}Docker:${RS}  ${LG}${DOCKER_RUN} running${RS}  |  ${Y}${DOCKER_STOP} stopped${RS}  |  ${GR}${DOCKER_TOT} total${RS}"
            if [[ -n "$DCK_BLK" ]]; then
                printf "    ${GR}%-32s %-10s %-22s %s${RS}\n" "Container" "CPU%" "Memory" "Status"
                echo "$DCK_BLK" | while IFS='|' read -r name cpu mem status; do
                    [[ -z "$name" ]] && continue
                    printf "    ${GR}%-32s %-10s %-22s %s${RS}\n" "${name:0:31}" "$cpu" "$mem" "$status"
                done
            fi
            out ""
        fi

        # Systemd
        if [[ "$FAILED_UNITS" != "none" && -n "$FAILED_UNITS" ]]; then
            out "  ${LR}  ! Failed Systemd Units: ${FAILED_UNITS}${RS}"
        else
            out "  ${LG}  v No failed systemd units${RS}"
        fi
        out ""

        # Reboot history
        out "  ${BO}${B}Recent Reboot History:${RS}"
        while IFS='|' read -r evt ts; do
            [[ -z "$evt" ]] && continue
            out "    ${GR}${evt}  --  ${ts}${RS}"
        done <<< "$RBT_BLK"
        out ""

        # Alerts
        if [[ ${#alerts[@]} -gt 0 ]]; then
            out "  ${LR}${BO}  *** ALERTS on ${server} ***${RS}"
            for al in "${alerts[@]}"; do
                out "  ${LR}    * ${al}${RS}"
            done
            out ""
        fi

        # Top processes
        out "  ${BO}${B}Top 5 by CPU:${RS}"
        printf "    ${GR}%-48s %-8s %-8s${RS}\n" "Process" "CPU%" "MEM%"
        echo "$TOP_CPU_BLK" | while IFS='|' read -r proc cpu mem; do
            [[ -z "$proc" ]] && continue
            printf "    ${GR}%-48s %-8s %-8s${RS}\n" "${proc:0:47}" "$cpu" "$mem"
        done
        out ""
        out "  ${BO}${B}Top 5 by Memory:${RS}"
        printf "    ${GR}%-48s %-8s %-8s${RS}\n" "Process" "CPU%" "MEM%"
        echo "$TOP_MEM_BLK" | while IFS='|' read -r proc cpu mem; do
            [[ -z "$proc" ]] && continue
            printf "    ${GR}%-48s %-8s %-8s${RS}\n" "${proc:0:47}" "$cpu" "$mem"
        done
        out ""
        out "${BO}${LC}  +-- Done: ${server}${RS}"
    fi

    # ── Text report ──────────────────────────────────────────────────────────
    {
        echo ""
        echo "======================================================"
        echo "  ${server}  (${HOSTNAME})  |  STATUS: ${node_state^^}"
        echo "  OS: ${DISTRO}  |  Kernel: ${KERNEL}  |  Uptime: ${UPTIME_H}"
        echo "======================================================"
        echo "  CPU : ${CPU_USE}%  [${ST_CPU}]"
        echo "  Load: 1m=${LOAD1}  5m=${LOAD5}  15m=${LOAD15}  [${ST_LOD}]  (warn>=${LOAD_WARN} crit>=${LOAD_CRIT})"
        echo "  RAM : ${MEM_USED_H} / ${MEM_TOTAL_H} GiB  (${MEM_PCT}%)  [${ST_MEM}]"
        echo "  Swap: ${SWAP_USED_H} / ${SWAP_TOTAL_H} GiB  (${SWAP_PCT}%)  [${ST_SWP}]"
        echo ""
        echo "  Disk:"
        while IFS='|' read -r mnt fs size used avail pct_num; do
            [[ -z "$mnt" || ! "$pct_num" =~ ^[0-9] ]] && continue
            ds=$(get_status "$pct_num" "$DISK_WARN" "$DISK_CRIT")
            printf "    %-22s %3s%%  used=%-8s free=%-8s [%s]\n" "$mnt" "$pct_num" "$used" "$avail" "$ds"
        done <<< "$DISK_BLK"
        echo ""
        echo "  Network (1-sec rate):"
        while IFS='|' read -r iface ip rx tx; do
            [[ -z "$iface" ]] && continue
            printf "    %-14s %-20s  RX=%-10s TX=%-10s MB/s\n" "$iface" "$ip" "$rx" "$tx"
        done <<< "$NET_BLK"
        echo ""
        echo "  Services:"
        while IFS='|' read -r svc state enabled; do
            [[ -z "$svc" ]] && continue
            printf "    %-22s %-12s (enabled: %s)\n" "$svc" "$state" "$enabled"
        done <<< "$SVC_BLK"
        echo ""
        [[ "$DOCKER_AVAIL" == "yes" ]] && echo "  Docker: ${DOCKER_RUN} running | ${DOCKER_STOP} stopped | ${DOCKER_TOT} total"
        echo "  Failed Units: ${FAILED_UNITS}"
        echo "  Last Reboot : ${LAST_RBT:-N/A}"
        echo ""
        if [[ ${#alerts[@]} -gt 0 ]]; then
            echo "  *** ALERTS ***"
            for al in "${alerts[@]}"; do echo "    * ${al}"; done
        fi
    } >> "$TEXT_REPORT"

    # ── HTML report ──────────────────────────────────────────────────────────
    local cpu_cl;  cpu_cl=$(bclass  "${CPU_USE:-0}"  "$CPU_WARN"  "$CPU_CRIT")
    local mem_cl;  mem_cl=$(bclass  "${MEM_PCT:-0}"  "$MEM_WARN"  "$MEM_CRIT")
    local swp_cl;  swp_cl=$(bclass  "${SWAP_PCT:-0}" "$SWAP_WARN" "$SWAP_CRIT")
    local lod_cl;  lod_cl=$(bclass  "${LOAD15:-0}"   "$LOAD_WARN" "$LOAD_CRIT")
    local dsk_cl;  dsk_cl=$(bclass  "${worst_disk}"  "$DISK_WARN" "$DISK_CRIT")

    local badge_icon badge_cls
    case "$node_state" in
        crit) badge_icon="[CRIT]"; badge_cls="crit" ;;
        warn) badge_icon="[WARN]"; badge_cls="warn" ;;
        *)    badge_icon="[OK]";   badge_cls="ok"   ;;
    esac

    hline "<div class='node'>"
    hline "  <div class='node-hdr'>"
    hline "    <h2>${server}</h2>"
    hline "    <span class='ip'>(${HOSTNAME})</span>"
    hline "    <span class='os-badge'>${DISTRO}</span>"
    hline "    <span class='st-badge ${badge_cls}'>${node_state^^}</span>"
    hline "  </div>"
    hline "  <div class='meta'>"
    hline "    <span><strong>Kernel:</strong> ${KERNEL}</span>"
    hline "    <span><strong>Arch:</strong> ${ARCH}</span>"
    hline "    <span><strong>CPUs:</strong> ${CPU_CORES} &mdash; ${CPU_MODEL}</span>"
    hline "    <span><strong>Uptime:</strong> ${UPTIME_H}</span>"
    hline "    <span><strong>Last Reboot:</strong> ${LAST_RBT:-N/A}</span>"
    hline "  </div>"

    if [[ ${#alerts[@]} -gt 0 ]]; then
        hline "  <div class='alerts'>"
        hline "    <div class='al-title'>${#alerts[@]} Alert(s) on this node</div><ul>"
        for al in "${alerts[@]}"; do hline "    <li>${al}</li>"; done
        hline "    </ul></div>"
    fi

    hline "  <div class='mgrid'>"
    hline "    <div class='metric ${cpu_cl}'><div class='mlabel'>CPU Usage</div><div class='mval'>${CPU_USE}%</div>"
    hline "      <div class='msub'>${CPU_CORES} cores &mdash; ${CPU_MODEL:0:30}</div>"
    hline "      <div class='pbar'><div class='pfill ${cpu_cl}' style='width:${CPU_USE}%'></div></div></div>"
    hline "    <div class='metric ${lod_cl}'><div class='mlabel'>Load (15m)</div><div class='mval'>${LOAD15}</div>"
    hline "      <div class='msub'>1m:${LOAD1} 5m:${LOAD5} | warn&ge;${LOAD_WARN}</div></div>"
    hline "    <div class='metric ${mem_cl}'><div class='mlabel'>Memory</div><div class='mval'>${MEM_PCT}%</div>"
    hline "      <div class='msub'>${MEM_USED_H} / ${MEM_TOTAL_H} GiB (${MEM_AVAIL_H} free)</div>"
    hline "      <div class='pbar'><div class='pfill ${mem_cl}' style='width:${MEM_PCT}%'></div></div></div>"
    hline "    <div class='metric ${swp_cl}'><div class='mlabel'>Swap</div><div class='mval'>${SWAP_PCT}%</div>"
    hline "      <div class='msub'>${SWAP_USED_H} / ${SWAP_TOTAL_H} GiB</div>"
    hline "      <div class='pbar'><div class='pfill ${swp_cl}' style='width:${SWAP_PCT}%'></div></div></div>"
    hline "    <div class='metric ${dsk_cl}'><div class='mlabel'>Disk (max)</div><div class='mval'>${worst_disk}%</div>"
    hline "      <div class='msub'>Worst partition</div>"
    hline "      <div class='pbar'><div class='pfill ${dsk_cl}' style='width:${worst_disk}%'></div></div></div>"
    hline "    <div class='metric info'><div class='mlabel'>Uptime</div><div class='mval' style='font-size:15px'>${UPTIME_H}</div>"
    hline "      <div class='msub'>Rebooted: ${LAST_RBT:-N/A}</div></div>"
    hline "  </div>"

    # Disk table
    hline "  <div class='sec'><div class='sec-title'>Disk Partitions</div>"
    hline "  <table><tr><th>Mount</th><th>Filesystem</th><th>Size</th><th>Used</th><th>Free</th><th>Use%</th><th>Status</th></tr>"
    while IFS='|' read -r mnt fstype size used avail pct_num; do
        [[ -z "$mnt" || ! "$pct_num" =~ ^[0-9] ]] && continue
        local ds dcl
        ds=$(get_status "$pct_num" "$DISK_WARN" "$DISK_CRIT")
        case "$ds" in CRITICAL) dcl="badge-crit";; WARNING) dcl="badge-warn";; *) dcl="badge-ok";; esac
        hline "    <tr><td><strong>${mnt}</strong></td><td>${fstype}</td><td>${size}</td><td>${used}</td><td>${avail}</td><td>${pct_num}%</td><td class='${dcl}'>${ds}</td></tr>"
    done <<< "$DISK_BLK"
    hline "  </table></div>"

    # Network table
    hline "  <div class='sec'><div class='sec-title'>Network &mdash; Live 1-Second Rate</div>"
    hline "  <table><tr><th>Interface</th><th>IP Address</th><th>RX (MB/s)</th><th>TX (MB/s)</th><th>Status</th></tr>"
    while IFS='|' read -r iface ip rx_mb tx_mb; do
        [[ -z "$iface" ]] && continue
        local net_st ncl
        net_st="OK"
        fge "$rx_mb" "$NET_CRIT_MB" && net_st="CRITICAL"
        fge "$rx_mb" "$NET_WARN_MB" && [[ "$net_st" != "CRITICAL" ]] && net_st="WARNING"
        case "$net_st" in CRITICAL) ncl="badge-crit";; WARNING) ncl="badge-warn";; *) ncl="badge-ok";; esac
        hline "    <tr><td><strong>${iface}</strong></td><td>${ip}</td><td>${rx_mb}</td><td>${tx_mb}</td><td class='${ncl}'>${net_st}</td></tr>"
    done <<< "$NET_BLK"
    hline "  </table></div>"

    # Services
    hline "  <div class='sec'><div class='sec-title'>Services</div><div class='sgrid'>"
    while IFS='|' read -r svc state enabled; do
        [[ -z "$svc" ]] && continue
        local dot_cls svc_label
        case "$state" in
            active)   dot_cls="run";  svc_label="running"  ;;
            inactive) dot_cls="stop"; svc_label="stopped"  ;;
            failed)   dot_cls="stop"; svc_label="FAILED"   ;;
            *)        dot_cls="abs";  svc_label="$state"   ;;
        esac
        hline "  <div class='svc'><span class='sdot ${dot_cls}'></span>"
        hline "    <span><strong>${svc}</strong><br><small>${svc_label} (${enabled})</small></span></div>"
    done <<< "$SVC_BLK"
    hline "  </div></div>"

    # Docker
    if [[ "$DOCKER_AVAIL" == "yes" ]]; then
        local dck_warn_cl; [[ "${DOCKER_STOP:-0}" -gt 0 ]] && dck_warn_cl="badge-warn" || dck_warn_cl="badge-ok"
        hline "  <div class='sec'><div class='sec-title'>Docker Containers</div>"
        hline "    <div style='display:flex;gap:20px;margin-bottom:10px;font-size:13px'>"
        hline "      <span class='badge-ok'>${DOCKER_RUN} Running</span>"
        hline "      <span class='${dck_warn_cl}'>${DOCKER_STOP} Stopped</span>"
        hline "      <span>${DOCKER_TOT} Total</span>"
        hline "    </div>"
        if [[ -n "$DCK_BLK" ]]; then
            hline "    <table><tr><th>Container</th><th>CPU%</th><th>Memory</th><th>Status</th></tr>"
            echo "$DCK_BLK" | while IFS='|' read -r name cpu mem status; do
                [[ -z "$name" ]] && continue
                hline "    <tr><td>${name}</td><td>${cpu}</td><td>${mem}</td><td>${status}</td></tr>"
            done
            hline "    </table>"
        fi
        hline "  </div>"
    fi

    # Failed units
    hline "  <div class='sec'><div class='sec-title'>Systemd Failed Units</div>"
    if [[ "$FAILED_UNITS" != "none" && -n "$FAILED_UNITS" ]]; then
        hline "  <div class='alerts' style='margin:0'><strong>${FAILED_UNITS}</strong></div>"
    else
        hline "  <span class='badge-ok' style='font-size:13px'>All units healthy</span>"
    fi
    hline "  </div>"

    # Reboot history
    hline "  <div class='sec'><div class='sec-title'>Reboot History</div>"
    hline "  <table><tr><th>Event</th><th>Date / Time</th></tr>"
    while IFS='|' read -r evt ts; do
        [[ -z "$evt" ]] && continue
        hline "  <tr><td>${evt}</td><td>${ts}</td></tr>"
    done <<< "$RBT_BLK"
    hline "  </table></div>"

    # Top processes
    hline "  <div class='sec'><div class='sec-title'>Top 5 by CPU</div>"
    hline "  <table><tr><th>Process</th><th>CPU%</th><th>MEM%</th></tr>"
    echo "$TOP_CPU_BLK" | while IFS='|' read -r proc cpu mem; do
        [[ -z "$proc" ]] && continue
        hline "  <tr><td>${proc}</td><td>${cpu}</td><td>${mem}</td></tr>"
    done
    hline "  </table></div>"
    hline "  <div class='sec'><div class='sec-title'>Top 5 by Memory</div>"
    hline "  <table><tr><th>Process</th><th>CPU%</th><th>MEM%</th></tr>"
    echo "$TOP_MEM_BLK" | while IFS='|' read -r proc cpu mem; do
        [[ -z "$proc" ]] && continue
        hline "  <tr><td>${proc}</td><td>${cpu}</td><td>${mem}</td></tr>"
    done
    hline "  </table></div>"

    hline "</div>"
}

# ──────────────────────────────────────────────────────────────────────────────
#  EMAIL
# ──────────────────────────────────────────────────────────────────────────────

send_email() {
    local subject="$1"
    out ""
    if command -v mutt &>/dev/null; then
        out "  ${C}Sending via mutt...${RS}"
        mutt -e "set content_type=text/html" \
             -e "set from=${EMAIL_FROM}" \
             -s "${subject}" \
             -a "${HTML_REPORT}" -- "${EMAIL_TO}" < "${TEXT_REPORT}" \
        && out "  ${LG}v Email sent to ${EMAIL_TO}${RS}" \
        || out "  ${LR}X mutt failed${RS}"
    elif command -v mail &>/dev/null; then
        out "  ${C}Sending via mail...${RS}"
        mail -s "${subject}" -a "Content-Type: text/html" "${EMAIL_TO}" < "${HTML_REPORT}" \
        && out "  ${LG}v Email sent${RS}" \
        || out "  ${LR}X mail failed${RS}"
    elif command -v sendmail &>/dev/null; then
        out "  ${C}Sending via sendmail...${RS}"
        { printf "From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/html\r\n\r\n" \
              "${EMAIL_FROM}" "${EMAIL_TO}" "${subject}"; cat "${HTML_REPORT}"; } \
        | sendmail -t \
        && out "  ${LG}v Email sent${RS}" \
        || out "  ${LR}X sendmail failed${RS}"
    else
        out "  ${Y}! No mail client found (mutt / mail / sendmail) -- email skipped${RS}"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
#  INJECT SUMMARY BAR INTO HTML
# ──────────────────────────────────────────────────────────────────────────────

inject_summary() {
    local sumbar
    sumbar="<div class='sumbar'>"
    sumbar+="<div class='sc total'><div class='n'>${TOTAL}</div><div class='l'>Total Nodes</div></div>"
    sumbar+="<div class='sc ok'><div class='n'>${HEALTHY}</div><div class='l'>Healthy</div></div>"
    sumbar+="<div class='sc warn'><div class='n'>${WARN_CT}</div><div class='l'>Warning</div></div>"
    sumbar+="<div class='sc crit'><div class='n'>${CRIT_CT}</div><div class='l'>Critical</div></div>"
    sumbar+="<div class='sc down'><div class='n'>${DOWN_CT}</div><div class='l'>Unreachable</div></div>"
    sumbar+="</div>"
    local tmp="/tmp/cluster_inject_$$.html"
    awk -v block="$sumbar" '/<\/div>/ && /hdr/{found++} found==1{print; print block; found=2; next} {print}' \
        "$HTML_REPORT" > "$tmp" 2>/dev/null && mv "$tmp" "$HTML_REPORT" || true
}

# ──────────────────────────────────────────────────────────────────────────────
#  MAIN
# ──────────────────────────────────────────────────────────────────────────────

main() {
    setup
    print_banner

    {
        echo "+============================================================+"
        echo "|  CLUSTER HEALTH REPORT -- $(date '+%d %b %Y  %H:%M:%S')      |"
        echo "+============================================================+"
        echo "  Nodes : ${#SERVERS[@]}"
        echo "  Thresholds:"
        echo "    CPU  : warn>=${CPU_WARN}%  crit>=${CPU_CRIT}%"
        echo "    RAM  : warn>=${MEM_WARN}%  crit>=${MEM_CRIT}%"
        echo "    Swap : warn>=${SWAP_WARN}%  crit>=${SWAP_CRIT}%"
        echo "    Disk : warn>=${DISK_WARN}%  crit>=${DISK_CRIT}%"
        echo "    Load : warn>=cores*${LOAD_WARN_MULT}  crit>=cores*${LOAD_CRIT_MULT}"
        echo "    Net  : warn>=${NET_WARN_MB} MB/s  crit>=${NET_CRIT_MB} MB/s"
    } >> "$TEXT_REPORT"

    html_start
    hline "<div class='hdr'><h1>Cluster Health Report</h1><span class='ts'>$(date '+%A, %d %B %Y at %H:%M:%S')</span></div>"

    out "${BO}  Scanning ${#SERVERS[@]} node(s)...${RS}"

    for server in "${SERVERS[@]}"; do
        check_server "$server"
    done

    inject_summary
    html_end

    {
        echo ""
        echo "+=================== SUMMARY ===================="
        echo "  Total: ${TOTAL}  Healthy: ${HEALTHY}  Warning: ${WARN_CT}  Critical: ${CRIT_CT}  Down: ${DOWN_CT}"
        echo "  HTML: ${HTML_REPORT}"
        echo "  TEXT: ${TEXT_REPORT}"
        echo "+================================================"
    } >> "$TEXT_REPORT"

    out ""
    out "${BO}${LC}+========================= SUMMARY =========================${RS}"
    out "  Total Nodes : ${W}${TOTAL}${RS}"
    out "  ${LG}Healthy     : ${HEALTHY}${RS}"
    out "  ${Y}Warning     : ${WARN_CT}${RS}"
    out "  ${LR}Critical    : ${CRIT_CT}${RS}"
    out "  ${GR}Unreachable : ${DOWN_CT}${RS}"
    out ""
    out "  HTML  --> ${HTML_REPORT}"
    out "  Text  --> ${TEXT_REPORT}"
    out "${BO}${LC}+============================================================${RS}"

    # Email decision
    if [[ "$SEND_EMAIL" == true ]]; then
        if [[ "$ALWAYS_MAIL" == true ]]; then
            send_email "$EMAIL_SUBJECT_OK"
        elif [[ "$HAS_ISSUES" == true ]]; then
            send_email "$EMAIL_SUBJECT_ALERT"
        else
            out ""
            out "  ${LG}v All nodes healthy -- no alert email sent${RS}"
            out "  ${GR}  (use --always-mail to send a report regardless)${RS}"
        fi
    fi

    # Exit code for cron / nagios / zabbix wrappers
    (( CRIT_CT > 0 || DOWN_CT > 0 )) && exit 2
    (( WARN_CT > 0 ))                  && exit 1
    exit 0
}

main "$@"