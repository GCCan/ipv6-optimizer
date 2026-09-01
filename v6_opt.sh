#!/bin/bash

target_ip="${1}"
ssh_user="${2:-root}"
ssh_port="${3:-22}"
threads="${4:-4}"

if [ -z "$target_ip" ]; then
    echo "用法: $0 <目标IPv6> [SSH用户名] [SSH端口] [并发线程数]"
    echo "示例: $0 2402:4e00:c011:2700:9cb6:df2a:9aa0:1 root 22 4"
    exit 1
fi

read -r -p "请输入要随机抽样测试的 IPv6 数量 (默认 100): " test_count
test_count="${test_count:-100}"

# 1. 自动检测网卡与 /64 前缀
interface=$(ip -6 route show default 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
[ -z "$interface" ] && interface="eth0"

ipv6_prefix=$(ip -6 route show dev "$interface" 2>/dev/null | awk '/\/64/ && !/default/ {print $1}' | head -n 1)
ipv6_base="${ipv6_prefix%/*}"

if [ -z "$ipv6_base" ]; then
    raw_ip=$(ip -6 addr show dev "$interface" scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d/ -f1 | head -n 1)
    ipv6_base=$(echo "$raw_ip" | awk -F: '{print $1":"$2":"$3":"$4}')
fi

# 去除末尾的 ::，统一格式为前 4 段（例如 2607:8140:212:a29:）
ipv6_base="${ipv6_base%::}:"

echo "=========================================="
echo "网卡: $interface | 前缀: ${ipv6_base}:/64"
echo "目标: $target_ip | 并发: $threads | 随机采样数: $test_count"
echo "=========================================="

subnet_mask="/64"
output_file="ping_${target_ip//:/_}.csv"
echo "IPv6 Address,Local to Target(ms),Target to Local(ms)" > "$output_file"

# 2. 生成随机 64 位后缀函数 (xxxx:xxxx:xxxx:xxxx)
get_random_v6_suffix() {
    printf '%x:%x:%x:%x' \
        $(( (RANDOM << 1) ^ RANDOM )) \
        $(( (RANDOM << 1) ^ RANDOM )) \
        $(( (RANDOM << 1) ^ RANDOM )) \
        $(( (RANDOM << 1) ^ RANDOM ))
}

# 3. 创建并发令牌桶
fifo_file="/tmp/$$.fifo"
mkfifo "$fifo_file"
exec 6<>"$fifo_file"
rm -f "$fifo_file"

for ((j=0; j<threads; j++)); do
    echo >&6
done

# 4. 退出清理
cleanup() {
    trap - SIGINT SIGTERM EXIT
    echo -e "\n正在终止并清理资源..."
    exec 6>&- 2>/dev/null
    exec 6<&- 2>/dev/null
    kill $(jobs -p) 2>/dev/null
    rm -f "${output_file}.lock"
    exit 1
}
trap cleanup SIGINT SIGTERM

# 5. 单 IP 测试任务
do_ping() {
    local ipv6_addr="$1"

    ip -6 addr add "${ipv6_addr}${subnet_mask}" dev "$interface" nodad 2>/dev/null

    # 本地 Ping
    ping_local=$(timeout 1.5 ping -6 -I "$ipv6_addr" -c 2 -i 0.1 -W 1 "$target_ip" 2>/dev/null)
    min_delay_local=$(echo "$ping_local" | awk -F'/' '/rtt|min\/avg\/max/{print $4}' | awk '{print $NF}')
    [ -z "$min_delay_local" ] && min_delay_local="TIMEOUT"

    # 远端 SSH 回 Ping
    ping_ssh=$(timeout 2.5 ssh -o BatchMode=yes \
                            -o ConnectTimeout=2 \
                            -o ServerAliveInterval=1 \
                            -o ServerAliveCountMax=1 \
                            -o StrictHostKeyChecking=no \
                            -p "$ssh_port" "$ssh_user@$target_ip" "ping -6 -c 2 -i 0.1 -W 1 $ipv6_addr" 2>/dev/null)
    min_delay_ssh=$(echo "$ping_ssh" | awk -F'/' '/rtt|min\/avg\/max/{print $4}' | awk '{print $NF}')
    [ -z "$min_delay_ssh" ] && min_delay_ssh="TIMEOUT"

    result="$ipv6_addr,$min_delay_local,$min_delay_ssh"
    echo "$result"

    (
        flock -x 200
        echo "$result" >> "$output_file"
    ) 200>"${output_file}.lock"

    ip -6 addr del "${ipv6_addr}${subnet_mask}" dev "$interface" 2>/dev/null
}

export -f do_ping
export subnet_mask interface target_ip ssh_port ssh_user output_file

# 6. 分发随机采样任务
for ((i=1; i<=test_count; i++)); do
    read -u6
    {
        trap - SIGINT SIGTERM
        random_suffix=$(get_random_v6_suffix)
        random_ipv6="${ipv6_base}${random_suffix}"

        timeout 5 bash -c "do_ping '$random_ipv6'" 2>/dev/null
        echo >&6
    } &
done

wait

# 清理资源
trap - SIGINT SIGTERM EXIT
exec 6>&- 2>/dev/null
exec 6<&- 2>/dev/null
rm -f "${output_file}.lock"

# 7. 提取并展示最快 Top 5
echo -e "\n================ 最快的 5 个 IPv6 ================"
valid_results=$(grep -v "TIMEOUT" "$output_file" | tail -n +2 | sort -t',' -k2,2n | head -n 5)

if [ -z "$valid_results" ]; then
    echo "未找到有效响应的 IP（所有测试均超时）。"
else
    printf "%-48s | %-16s | %-16s\n" "IPv6 地址" "去程延迟 (ms)" "回程延迟 (ms)"
    echo "-------------------------------------------------+------------------+------------------"
    echo "$valid_results" | while IFS=',' read -r ip d1 d2; do
        printf "%-48s | %-16s | %-16s\n" "$ip" "$d1" "$d2"
    done
fi
echo "=================================================="
echo "完整数据已保存至: $output_file"
