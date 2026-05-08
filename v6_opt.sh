#!/bin/bash
set -u

# ---------- 权限与命令可用性检查 ----------
SUDO=""
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
  echo "错误：当前不是 root，且系统未安装 sudo。"
  exit 1
fi

# 选择 ping 命令
PING_CMD=""
PING_MODE=""
if command -v ping6 >/dev/null 2>&1; then
  PING_CMD="ping6"
  PING_MODE="ping6"
elif command -v ping >/dev/null 2>&1; then
  PING_CMD="ping"
  PING_MODE="ping-6"
else
  echo "错误：未找到 ping6 或 ping 命令。"
  exit 1
fi

ping_ipv6() {
    local src_ip="$1"
    local target_ipv6="$2"
    local temp_file="$3"
    local ping_output

    if [ "$PING_MODE" = "ping6" ]; then
      ping_output=$($PING_CMD -I "$src_ip" -i 0.3 -c 30 "$target_ipv6" 2>&1)
      if echo "$ping_output" | grep -qiE 'invalid argument|unknown|bind|Cannot assign requested address|bad address|cannot assign|Usage:'; then
          ping_output=$($PING_CMD -I "$interface_name" -S "$src_ip" -i 0.3 -c 30 "$target_ipv6" 2>&1)
      fi
    else
      ping_output=$($PING_CMD -6 -I "$src_ip" -i 0.3 -c 30 "$target_ipv6" 2>&1)
      if echo "$ping_output" | grep -qiE 'invalid argument|unknown|bind|Cannot assign requested address|bad address|cannot assign|Usage:'; then
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
    # 还原终端设置，防止退格键失效
    stty sane 2>/dev/null
    
    if [ "${#ip_array[@]}" -gt 0 ]; then
        for src_ip in "${ip_array[@]}"; do
            $SUDO ip -6 addr del "$src_ip"/64 dev "$interface_name" 2>/dev/null || true
        done
    fi
    [ -n "${temp_file:-}" ] && [ -f "$temp_file" ] && rm -f "$temp_file"
    [ -n "${temp_progress_file:-}" ] && [ -f "$temp_progress_file" ] && rm -f "$temp_progress_file"
    [ -n "${err_file:-}" ] && [ -f "$err_file" ] && rm -f "$err_file"
}

print_progress_bar() {
    local -i current=$1
    local -i total=$2
    local filled=$((current*60/total))
    local bars=$(printf "%-${filled}s" "|" | tr ' ' '|')
    local spaces=$(printf "%-$((60-filled))s" " ")
    local percent=$((current*100/total))
    echo -ne "[${bars}${spaces}] ${percent}% ($current/$total)\r"
}

start_time=$(date +%s)
# 声明数组以供 cleanup 使用
declare -a ip_array=()
trap cleanup EXIT

# ---------- 获取默认 IPv6 网卡与前缀 ----------
interface_name=$(ip -6 route | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
if [ -z "${interface_name:-}" ]; then
    echo "未找到默认 IPv6 路由。"
    exit 1
fi

current_ipv6=$(ip -6 addr show "$interface_name" | grep 'inet6' | grep -v 'fe80' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
if [ -z "${current_ipv6:-}" ]; then
    echo "未找到全局 IPv6 地址。"
    exit 1
fi

current_prefix=$(echo "$current_ipv6" | cut -d':' -f1-4)

echo -e "\n网卡当前配置的IPv6： $current_ipv6"
echo -e "分配该虚拟机的IPv6： $current_prefix::/64\n"

# 修复点：移除了 stty erase '^H'，直接使用 read
read -p "请输入你要检测的对端IPv6: " target_ipv6
if ! [[ "$target_ipv6" =~ ^([0-9a-fA-F:]+)$ && "${#target_ipv6}" -ge 15 ]]; then
    echo "地址格式错误。"
    exit 1
fi

read -p "请输入测试数量: " ipv6_num
if ! [[ "$ipv6_num" =~ ^[0-9]+$ ]] || [ "$ipv6_num" -eq 0 ]; then
    echo "数量无效。"
    exit 1
fi

declare -A used_ip_addrs
used_ip_addrs["$current_ipv6"]=1

echo -e "\n在 $current_prefix::/64 中生成 $ipv6_num 个地址进行检测..."

current_count=0
err_file=$(mktemp)
max_tries=$((ipv6_num * 10))
tries=0
first_err_printed=0

for (( i=0; i<ipv6_num; i++ )); do
    while : ; do
        ((tries++))
        if [ "$tries" -gt "$max_tries" ]; then
            echo -e "\n错误：已达到最大重试次数。检查环境是否允许添加多IP。"
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
                    echo -e "\n提示：添加失败，正在重试..."
                fi
                continue
            fi
        fi
    done
done

echo -e "\n\n对 ${#ip_array[@]} 个地址进行 Ping 测试..."
temp_file=$(mktemp)
temp_progress_file=$(mktemp)

# 动态并发控制
total_jobs=${#ip_array[@]}
parallel_jobs=$(( total_jobs / 4 ))
[ "$parallel_jobs" -lt 1 ] && parallel_jobs=1
[ "$parallel_jobs" -gt 150 ] && parallel_jobs=150

completed_jobs=0
print_progress_bar "$completed_jobs" "$total_jobs"

for src_ip in "${ip_array[@]}"; do
    (
        ping_ipv6 "$src_ip" "$target_ipv6" "$temp_file"
        $SUDO ip -6 addr del "$src_ip"/64 dev "$interface_name" 2>/dev/null || true
        echo >> "$temp_progress_file"
    ) &

    if (( $(jobs -r | wc -l) >= parallel_jobs )); then
        wait -n
        completed_jobs=$(wc -l < "$temp_progress_file")
        print_progress_bar "$completed_jobs" "$total_jobs"
    fi
done
wait

completed_jobs=$(wc -l < "$temp_progress_file")
print_progress_bar "$completed_jobs" "$total_jobs"
echo -e "\n"

echo "====================================================="
echo -e "IPv6                                     Average"
sort -k2 -n "$temp_file" | head -n 10 | while read -r line; do
    ipv6=$(echo "$line" | awk '{print $1}')
    rtt=$(echo "$line" | awk '{print $2}')
    printf "%-40s %s ms\n" "$ipv6" "$rtt"
done
echo "====================================================="

elapsed_time=$(( $(date +%s) - start_time ))
echo "脚本总耗时: $elapsed_time 秒。"
