#!/bin/bash
set -u

# ---------- 基础检查 ----------
SUDO=""
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
  echo "错误：当前不是 root。请用 root 运行，或者装个 sudo。"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "错误：没找到 python3。脚本需要它来精准拆解 IPv6 地址，请先安装。"
  exit 1
fi

PING_CMD=""
PING_MODE=""
if command -v ping6 >/dev/null 2>&1; then
  PING_CMD="ping6"
  PING_MODE="ping6"
elif command -v ping >/dev/null 2>&1; then
  PING_CMD="ping"
  PING_MODE="ping-6"
else
  echo "错误：没找到 ping 命令。"
  exit 1
fi

# ---------- 工具函数 ----------
ping_ipv6() {
    local src_ip="$1"
    local target_ipv6="$2"
    local temp_file="$3"
    local ping_output

    if [ "$PING_MODE" = "ping6" ]; then
      ping_output=$($PING_CMD -I "$src_ip" -i 0.3 -c 30 "$target_ipv6" 2>&1)
      if echo "$ping_output" | grep -qiE 'invalid argument|unknown|bind|Cannot assign|bad address|Usage:'; then
          ping_output=$($PING_CMD -I "$interface_name" -S "$src_ip" -i 0.3 -c 30 "$target_ipv6" 2>&1)
      fi
    else
      ping_output=$($PING_CMD -6 -I "$src_ip" -i 0.3 -c 30 "$target_ipv6" 2>&1)
      if echo "$ping_output" | grep -qiE 'invalid argument|unknown|bind|Cannot assign|bad address|Usage:'; then
          ping_output=$($PING_CMD -6 -I "$interface_name" -S "$src_ip" -i 0.3 -c 30 "$target_ipv6" 2>&1)
      fi
    fi

    local loss
    loss=$(echo "$ping_output" | grep 'packets transmitted' | awk '{print $6}')
    [ -z "${loss:-}" ] || [ "$loss" = "100%" ] || [ "$loss" = "100.0%" ] && return

    local avg
    avg=$(echo "$ping_output" | awk -F'=' '/rtt|round-trip/ {print $2}' | awk -F'/' '{print $2}' | head -n 1)
    [ -z "${avg:-}" ] && return
    echo "$src_ip $avg" >> "$temp_file"
}

cleanup() {
    stty sane 2>/dev/null
    echo -e "\n正在清理测试用的临时 IPv6 地址，马上就好..."
    if [ "${#ip_array[@]}" -gt 0 ]; then
        for src_ip in "${ip_array[@]}"; do
            $SUDO ip -6 addr del "$src_ip/$prefix_len" dev "$interface_name" 2>/dev/null || true
        done
    fi
    rm -f "${temp_file:-}" "${temp_progress_file:-}" "${err_file:-}" 2>/dev/null
}

print_progress_bar() {
    local -i current=$1
    local -i total=$2
    local filled=$((current*60/total))
    local bars=$(printf "%-${filled}s" "|" | tr ' ' '|')
    local spaces=$(printf "%-$((60-filled))s" " ")
    local percent=$((current*100/total))
    echo -ne "\r[${bars}${spaces}] ${percent}% ($current/$total)"
}

# ---------- 初始化与网段识别 ----------
start_time=$(date +%s)
declare -a ip_array=()
trap cleanup EXIT

interface_name=$(ip -6 route | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
if [ -z "${interface_name:-}" ]; then
    echo "错误：没找到默认的 IPv6 网卡。"
    exit 1
fi

# 抓取完整的 IPv6 信息（带掩码）
full_ipv6_info=$(ip -6 addr show "$interface_name" | grep 'inet6 ' | grep -v 'fe80' | awk '{print $2}' | head -n 1)
if [ -z "${full_ipv6_info:-}" ]; then
    echo "错误：网卡 $interface_name 上没找到公网 IPv6 地址。"
    exit 1
fi

current_ipv6=$(echo "$full_ipv6_info" | cut -d'/' -f1)
prefix_len=$(echo "$full_ipv6_info" | cut -d'/' -f2)

# 兜底处理：如果获取不到掩码，或者掩码太小，统一按 /64 算
if [ -z "$prefix_len" ] || [ "$prefix_len" -lt 64 ]; then
    prefix_len=64
fi

if [ "$prefix_len" -ge 128 ]; then
    echo "你的 IPv6 是 /128 掩码，只有一个 IP，没法变出花来随机生成。"
    exit 1
fi

# 算出需要补充几个随机块 (每块16位)
random_blocks=$(( (128 - prefix_len) / 16 ))
if [ "$random_blocks" -lt 1 ] || [ $((prefix_len % 16)) -ne 0 ]; then
    echo "目前只支持 /64, /80, /96, /112 这类标准的掩码。你的掩码是 /$prefix_len，脚本搞不定。"
    exit 1
fi

# 借助 python3 把地址完全展开，提取固定的前缀部分
fixed_blocks=$(( prefix_len / 16 ))
base_prefix=$(python3 -c "
import ipaddress
try:
    ip = ipaddress.IPv6Address('$current_ipv6').exploded
    blocks = ip.split(':')
    print(':'.join(blocks[:$fixed_blocks]))
except Exception:
    print('')
" 2>/dev/null)

if [ -z "$base_prefix" ]; then
    echo "解析 IPv6 前缀失败了。这串 IP 看着不对劲。"
    exit 1
fi

echo "========================================="
echo "当前 IP:  $current_ipv6"
echo "真实掩码: /$prefix_len"
echo "固定前缀: $base_prefix"
echo "========================================="
echo ""

read -p "请输入你要检测的对端 IPv6: " target_ipv6
if ! [[ "$target_ipv6" =~ ^([0-9a-fA-F:]+)$ && "${#target_ipv6}" -ge 15 ]]; then
    echo "地址格式好像填错了。"
    exit 1
fi

echo "正在用主 IP 试探目标..."
if ! $PING_CMD -c 2 "$target_ipv6" >/dev/null 2>&1; then
    echo -e "\n警告：你的主 IPv6 根本 ping 不通目标地址。"
    read -p "网络可能不通，还要强行继续测吗？(y/n): " force_continue
    if [[ "$force_continue" != "y" && "$force_continue" != "Y" ]]; then
        exit 1
    fi
else
    echo "试探成功，目标网络可达。"
fi
echo ""

read -p "想生成多少个随机 IP 来测？(例如 100): " ipv6_num
if ! [[ "$ipv6_num" =~ ^[0-9]+$ ]] || [ "$ipv6_num" -eq 0 ]; then
    echo "数量得填个正整数。"
    exit 1
fi

declare -A used_ip_addrs
used_ip_addrs["$current_ipv6"]=1

# ---------- 生成 IP ----------
echo "正在 /$prefix_len 网段里生成 $ipv6_num 个随机 IP..."
current_count=0
err_file=$(mktemp)
max_tries=$((ipv6_num * 10))
tries=0
first_err_printed=0

for (( i=0; i<ipv6_num; i++ )); do
    while : ; do
        ((tries++))
        if [ "$tries" -gt "$max_tries" ]; then
            echo -e "\n错误：生成失败太多次了。你的云厂商估计限制了网卡绑定的 IP 数量。"
            exit 1
        fi

        # 动态生成所需数量的随机块
        random_part=""
        for ((j=0; j<random_blocks; j++)); do
            part=$(printf "%x" $((RANDOM%65536)))
            if [ $j -eq 0 ]; then
                random_part="$part"
            else
                random_part="$random_part:$part"
            fi
        done
        
        test_ipv6="$base_prefix:$random_part"

        if [ -z "${used_ip_addrs[$test_ipv6]+x}" ]; then
            # 注意这里绑定的掩码变成了动态的 $prefix_len
            if $SUDO ip -6 addr add "$test_ipv6/$prefix_len" dev "$interface_name" 2>>"$err_file"; then
                used_ip_addrs["$test_ipv6"]=1
                ip_array+=("$test_ipv6")
                ((current_count++))
                print_progress_bar "$current_count" "$ipv6_num"
                break
            else
                if [ "$first_err_printed" -eq 0 ]; then
                    first_err_printed=1
                    echo -e "\n提示：添加 IP 被拒绝了，正在自动重试..."
                fi
                continue
            fi
        fi
    done
done

echo -e "\n\n开始对这 ${#ip_array[@]} 个 IP 测延迟了，稍等..."
temp_file=$(mktemp)
temp_progress_file=$(mktemp)

total_jobs=${#ip_array[@]}
parallel_jobs=$(( total_jobs / 4 ))
[ "$parallel_jobs" -lt 1 ] && parallel_jobs=1
[ "$parallel_jobs" -gt 150 ] && parallel_jobs=150

completed_jobs=0
print_progress_bar "$completed_jobs" "$total_jobs"

# ---------- 并发 Ping ----------
for src_ip in "${ip_array[@]}"; do
    (
        ping_ipv6 "$src_ip" "$target_ipv6" "$temp_file"
        echo >> "$temp_progress_file"
    ) &

    while (( $(jobs -p | wc -l) >= parallel_jobs )); do
        sleep 0.1
    done

    completed_jobs=$(wc -l < "$temp_progress_file")
    print_progress_bar "$completed_jobs" "$total_jobs"
done

wait
completed_jobs=$(wc -l < "$temp_progress_file")
print_progress_bar "$completed_jobs" "$total_jobs"
echo -e "\n"

# ---------- 结果展示 ----------
echo "====================================================="
echo -e "IPv6 Address                             Average RTT"
echo "-----------------------------------------------------"
if [ -s "$temp_file" ]; then
    sort -k2 -n "$temp_file" | head -n 10 | while read -r line; do
        ipv6=$(echo "$line" | awk '{print $1}')
        rtt=$(echo "$line" | awk '{print $2}')
        printf "%-40s %s ms\n" "$ipv6" "$rtt"
    done
else
    echo "全部阵亡，没一个能 ping 通的。"
fi
echo "====================================================="

elapsed_time=$(( $(date +%s) - start_time ))
echo "搞定！总共花了 $elapsed_time 秒。"
