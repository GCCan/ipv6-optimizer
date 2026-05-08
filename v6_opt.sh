#!/bin/bash
set -u

# ---------- 基础检查 ----------
SUDO=""
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
  echo "Error: Not running as root. Please install sudo or switch to root."
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
  echo "Error: ping/ping6 not found."
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
    echo -e "\nCleaning up temporary IPv6 addresses..."
    if [ "${#ip_array[@]}" -gt 0 ]; then
        for src_ip in "${ip_array[@]}"; do
            $SUDO ip -6 addr del "$src_ip"/64 dev "$interface_name" 2>/dev/null || true
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

# ---------- 初始化 ----------
start_time=$(date +%s)
declare -a ip_array=()
trap cleanup EXIT

interface_name=$(ip -6 route | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
if [ -z "${interface_name:-}" ]; then
    echo "Error: No default IPv6 route found."
    exit 1
fi

current_ipv6=$(ip -6 addr show "$interface_name" | grep 'inet6' | grep -v 'fe80' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
if [ -z "${current_ipv6:-}" ]; then
    echo "Error: No global IPv6 address found on $interface_name."
    exit 1
fi

current_prefix=$(echo "$current_ipv6" | cut -d':' -f1-4)

echo "========================================="
echo "Current IPv6: $current_ipv6"
echo "Subnet:       $current_prefix::/64"
echo "========================================="
echo ""

read -p "Enter the target IPv6 address to test: " target_ipv6
if ! [[ "$target_ipv6" =~ ^([0-9a-fA-F:]+)$ && "${#target_ipv6}" -ge 15 ]]; then
    echo "Invalid IPv6 address format."
    exit 1
fi

# 预检功能：测试目标是否可达
echo "Running pre-flight check..."
if ! $PING_CMD -c 2 "$target_ipv6" >/dev/null 2>&1; then
    echo -e "\nWarning: The target IP seems unreachable from your current main IPv6."
    read -p "Do you want to continue anyway? (y/n): " force_continue
    if [[ "$force_continue" != "y" && "$force_continue" != "Y" ]]; then
        exit 1
    fi
else
    echo "Pre-flight check passed. Target is reachable."
fi
echo ""

read -p "How many IPs do you want to generate and test? (e.g., 100): " ipv6_num
if ! [[ "$ipv6_num" =~ ^[0-9]+$ ]] || [ "$ipv6_num" -eq 0 ]; then
    echo "Invalid number."
    exit 1
fi

declare -A used_ip_addrs
used_ip_addrs["$current_ipv6"]=1

# ---------- 生成 IP ----------
echo "Generating $ipv6_num IPs in $current_prefix::/64..."
current_count=0
err_file=$(mktemp)
max_tries=$((ipv6_num * 10))
tries=0
first_err_printed=0

for (( i=0; i<ipv6_num; i++ )); do
    while : ; do
        ((tries++))
        if [ "$tries" -gt "$max_tries" ]; then
            echo -e "\nError: Max retries reached. Check if your provider allows adding multiple IPs."
            exit 1
        fi

        random_part=$(printf '%x:%x:%x:%x' $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)))
        test_ipv6="$current_prefix:$random_part"

        if [ -z "${used_ip_addrs[$test_ipv6]+x}" ]; then
            if $SUDO ip -6 addr add "$test_ipv6"/64 dev "$interface_name" 2>>"$err_file"; then
                used_ip_addrs["$test_ipv6"]=1
                ip_array+=("$test_ipv6")
                ((current_count++))
                print_progress_bar "$current_count" "$ipv6_num"
                break
            else
                if [ "$first_err_printed" -eq 0 ]; then
                    first_err_printed=1
                    echo -e "\nTip: Failed to add IP, retrying automatically..."
                fi
                continue
            fi
        fi
    done
done

echo -e "\n\nTesting ping latency for ${#ip_array[@]} addresses..."
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

    # 控制并发数量
    while (( $(jobs -p | wc -l) >= parallel_jobs )); do
        sleep 0.1
    done

    # 动态更新进度
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
    echo "No successful pings recorded. All tested IPs failed."
fi
echo "====================================================="

elapsed_time=$(( $(date +%s) - start_time ))
echo "Done! Total time: $elapsed_time seconds."
