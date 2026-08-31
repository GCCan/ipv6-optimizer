#!/bin/bash

target_ip="${1}"
ssh_user="${2:-root}"
ssh_port="${3:-22}"
threads="${4:-4}" # 推荐并发设为 4，避免触发目标服务器 sshd 频控

if [ -z "$target_ip" ]; then
    echo "用法: $0 <目标IPv6> [SSH用户名] [SSH端口] [并发线程数]"
    echo "示例: $0 2402:4e00:c011:2700:9cb6:df2a:9aa0:1 root 22 4"
    exit 1
fi

read -r -p "请输入要测试的 IPv6 数量 (1-65535，默认 100): " test_count
test_count="${test_count:-100}"

if ! [[ "$test_count" =~ ^[0-9]+$ ]] || [ "$test_count" -lt 1 ] || [ "$test_count" -gt 65535 ]; then
    echo "输入无效，已重置为默认值 100"
    test_count=100
fi

# 1. 自动检测网卡与 /64 前缀
interface=$(ip -6 route show default 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
[ -z "$interface" ] && interface="eth0"

ipv6_prefix=$(ip -6 route show dev "$interface" 2>/dev/null | awk '/\/64/ && !/default/ {print $1}' | head -n 1)
ipv6_base="${ipv6_prefix%/*}"

if [ -z "$ipv6_base" ]; then
    raw_ip=$(ip -6 addr show dev "$interface" scope global 2>/dev/null | awk '/inet6/ {print $2}' | cut -d/ -f1 | head -n 1)
    ipv6_base=$(echo "$raw_ip" | awk -F: '{print $1":"$2":"$3":"$4"::"}')
fi

[[ "$ipv6_base" != *"::" ]] && ipv6_base="${ipv6_base}::"

echo "=========================================="
echo "网卡: $interface | 前缀: $ipv6_base"
echo "目标: $target_ip | 并发: $threads | 测试数: $test_count"
echo "=========================================="

subnet_mask="/64"
output_file="ping_${target_ip//:/_}.csv"
echo "IPv6 Address,Local to Target(ms),Target to Local(ms)" > "$output_file"

# 2. 创建并发令牌桶
fifo_file="/tmp/$$.fifo"
mkfifo "$fifo_file"
exec 6<>"$fifo_file"
rm -f "$fifo_file"

for ((j=0; j<threads; j++)); do
    echo >&6
done

# 3. 退出清理
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

# 4. 单 IP 执行逻辑
do_ping() {
    local hex_suffix="$1"
    local ipv6_addr="${ipv6_base}${hex_suffix}"

    ip -6 addr add "${ipv6_addr}${subnet_mask}" dev "$interface" nodad 2>/dev/null

    # 本地 Ping 目标
    ping_local=$(timeout 1.5 ping -6 -I "$ipv6_addr" -c 2 -i 0.1 -W 1 "$target_ip" 2>/dev/null)
    min_delay_local=$(echo "$ping_local" | awk -F'/' '/rtt|min\/avg\/max/{print $4}' | awk '{print $NF}')
    [ -z "$min_delay_local" ] && min_delay_local="TIMEOUT"

    # 独立 SSH Ping（带快速断开与保活限制）
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

# 导出函数供 subshell 调用
export -f do_ping
export ipv6_base subnet_mask interface target_ip ssh_port ssh_user output_file

# 5. 分发并发任务（增加外层 5 秒硬超时，死锁直接强杀）
for i in $(seq 1 "$test_count"); do
    read -u6
    {
        trap - SIGINT SIGTERM
        hex_suffix=$(printf '%x' $i)
        # 整体任务加装 5 秒超时保护
        timeout 5 bash -c "do_ping '$hex_suffix'" 2>/dev/null
        # 无论发生什么，必释放令牌
        echo >&6
    } &
done

wait

# 清理资源
trap - SIGINT SIGTERM EXIT
exec 6>&- 2>/dev/null
exec 6<&- 2>/dev/null
rm -f "${output_file}.lock"

# 6. 提取并展示最快的 5 个 IP
echo -e "\n================ 最快的 5 个 IPv6 ================"
valid_results=$(grep -v "TIMEOUT" "$output_file" | tail -n +2 | sort -t',' -k2,2n | head -n 5)

if [ -z "$valid_results" ]; then
    echo "未找到有效响应的 IP（所有测试均超时）。"
else
    printf "%-40s | %-16s | %-16s\n" "IPv6 地址" "去程延迟 (ms)" "回程延迟 (ms)"
    echo "-----------------------------------------+------------------+------------------"
    echo "$valid_results" | while IFS=',' read -r ip d1 d2; do
        printf "%-40s | %-16s | %-16s\n" "$ip" "$d1" "$d2"
    done
fi
echo "=================================================="
echo "完整数据已保存至: $output_file"
