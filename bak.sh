#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 定义路径
CONFIG_FILE="/etc/nftables.conf"
SHORTCUT_PATH="/usr/bin/nft-helper"
# 更新地址
UPDATE_URL="https://raw.githubusercontent.com/RomanovCaesar/nft-helper/main/nft_helper.sh"

# 检查是否为 root 用户
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 检测系统类型
if [ -f /etc/alpine-release ]; then
    IS_ALPINE=1
    SYS_TYPE="Alpine (OpenRC)"
    SERVICE_NAME="nftables"
else
    IS_ALPINE=0
    SYS_TYPE="Debian/Ubuntu (Systemd)"
    SERVICE_NAME="nftables"
fi

# 开启 IP 转发功能的函数 (优化版：防重复，防覆盖)
enable_ip_forward() {
    # 1. 临时生效
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    
    # 2. 永久生效 (写入配置文件)
    if ! grep -q "^net.ipv4.ip_forward=1$" /etc/sysctl.conf; then
        sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi
}

# 检查系统依赖
check_dependencies() {
    enable_ip_forward

    if [ "$IS_ALPINE" -eq 0 ]; then
        # Debian/Ubuntu
        if ! command -v curl &> /dev/null || ! command -v nano &> /dev/null || ! command -v vim &> /dev/null || ! command -v grep &> /dev/null; then
            apt-get update && apt-get install -y curl nano vim grep
        fi
    else
        # Alpine
        if ! command -v curl &> /dev/null; then
            apk add curl
        fi
        if ! command -v nano &> /dev/null; then
            apk add nano
        fi
        if ! command -v vim &> /dev/null; then
            apk add vim
        fi
    fi
}

# 检查并安装快捷方式
check_shortcut() {
    if [ ! -f "$SHORTCUT_PATH" ] || [[ "$(realpath "$0")" != "$(realpath "$SHORTCUT_PATH")" ]]; then
        cp "$0" "$SHORTCUT_PATH"
        chmod +x "$SHORTCUT_PATH"
    fi
}

# 获取 Nftables 状态
get_status() {
    # 1. 安装状态
    if command -v nft &> /dev/null; then
        local ver=$(nft --version | awk '{print $2}')
        INSTALL_STATUS="${GREEN}已安装 (版本: $ver)${PLAIN}"
    else
        INSTALL_STATUS="${RED}未安装${PLAIN}"
    fi

    # 2. 运行状态
    RUN_STATUS="${RED}未运行${PLAIN}"
    
    if [ "$IS_ALPINE" -eq 1 ]; then
        # OpenRC 检测
        if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -q "started"; then
            RUN_STATUS="${GREEN}运行中${PLAIN}"
        fi
    else
        # Systemd 检测
        if command -v systemctl &> /dev/null; then
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                RUN_STATUS="${GREEN}运行中${PLAIN}"
            fi
        fi
    fi
    
    # 3. IP Forward 状态检测
    IP_FW=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    if [ "$IP_FW" == "1" ]; then
        FW_STATUS="${GREEN}已开启${PLAIN}"
    else
        FW_STATUS="${RED}未开启 (转发将失效)${PLAIN}"
        enable_ip_forward
    fi
}

# 任意键返回
wait_for_key() {
    echo ""
    echo -e "${YELLOW}按下任意键返回主菜单...${PLAIN}"
    read -n 1 -s -r
    main_menu
}

# 验证端口范围
validate_port_range() {
    local start=$1
    local end=$2
    local name=$3
    
    if [[ ! "$start" =~ ^[0-9]+$ ]] || [[ ! "$end" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误：端口必须是数字。${PLAIN}"
        return 1
    fi
    
    if [ "$start" -lt 1 ] || [ "$start" -gt 65535 ] || [ "$end" -lt 1 ] || [ "$end" -gt 65535 ]; then
        echo -e "${RED}错误：端口范围必须在 1-65535 之间。${PLAIN}"
        return 1
    fi
    
    if [ "$start" -gt "$end" ]; then
        echo -e "${RED}错误：起始端口不能大于结束端口。${PLAIN}"
        return 1
    fi
    
    return 0
}

# 检查端口范围是否已存在
check_port_range_exists() {
    local start=$1
    local end=$2
    
    # 检查是否有任何规则使用了这个范围内的端口
    while read -r line; do
        if echo "$line" | grep -q "dport"; then
            # 尝试匹配单端口
            local single_port=$(echo "$line" | grep -oP 'dport \K\d+')
            if [[ -n "$single_port" ]] && [ "$single_port" -ge "$start" ] && [ "$single_port" -le "$end" ]; then
                return 1
            fi
            
            # 尝试匹配端口范围
            local range=$(echo "$line" | grep -oP 'dport \{\K[0-9,-]+\}')
            if [[ -n "$range" ]]; then
                # 简单的范围重叠检查
                return 1
            fi
        fi
    done < <(grep "dnat to" "$CONFIG_FILE")
    
    return 0
}

# 安装或更新 Nftables
install_nftables() {
    echo -e "${GREEN}正在通过包管理器安装 Nftables...${PLAIN}"
    
    if [ "$IS_ALPINE" -eq 1 ]; then
        apk add nftables
        rc-update add nftables default
    else
        apt-get update
        apt-get install -y nftables
        systemctl enable nftables
    fi

    enable_ip_forward
    init_config force

    echo -e "${GREEN}Nftables 安装完成！${PLAIN}"
    
    if [ "$IS_ALPINE" -eq 1 ]; then
        rc-service nftables start
    else
        systemctl start nftables
    fi
    
    wait_for_key
}

# 初始化配置文件
init_config() {
    local force=$1
    if [ ! -f "$CONFIG_FILE" ] || [ "$force" == "force" ]; then
        cat > "$CONFIG_FILE" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # MARKER_START
        # MARKER_END
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        masquerade
    }
}
EOF
        chmod +x "$CONFIG_FILE"
    fi
    
    if ! grep -q "MARKER_START" "$CONFIG_FILE"; then
         echo -e "${RED}警告: 配置文件格式不兼容本脚本，建议备份后运行选项1重置配置。${PLAIN}"
    fi
}

# 添加单端口转发规则
add_rule() {
    init_config
    echo -e "${YELLOW}=== 添加单端口转发规则 (TCP+UDP) ===${PLAIN}"
    
    read -p "请输入监听 IP (默认 0.0.0.0, 回车即可): " listen_ip
    
    read -p "请输入监听端口 (必填): " listen_port
    if [[ -z "$listen_port" ]]; then
        echo -e "${RED}错误：监听端口不能为空。${PLAIN}"
        wait_for_key
        return
    fi

    if [[ ! "$listen_port" =~ ^[0-9]+$ ]] || [ "$listen_port" -lt 1 ] || [ "$listen_port" -gt 65535 ]; then
        echo -e "${RED}错误：端口必须是 1-65535 之间的数字。${PLAIN}"
        wait_for_key
        return
    fi

    if grep -q "dport $listen_port dnat" "$CONFIG_FILE"; then
        echo -e "${RED}错误：该端口已在配置文件中存在。${PLAIN}"
        wait_for_key
        return
    fi

    read -p "请输入转发目标 IP (必填): " remote_ip
    if [[ -z "$remote_ip" ]]; then
        echo -e "${RED}错误：目标 IP 不能为空。${PLAIN}"
        wait_for_key
        return
    fi

    read -p "请输入转发目标端口 (必填): " remote_port
    if [[ -z "$remote_port" ]]; then
        echo -e "${RED}错误：目标端口 不能为空。${PLAIN}"
        wait_for_key
        return
    fi
    
    if [[ ! "$remote_port" =~ ^[0-9]+$ ]] || [ "$remote_port" -lt 1 ] || [ "$remote_port" -gt 65535 ]; then
        echo -e "${RED}错误：目标端口必须是 1-65535 之间的数字。${PLAIN}"
        wait_for_key
        return
    fi

    if [[ -n "$listen_ip" && "$listen_ip" != "0.0.0.0" ]]; then
        RULE_STR="        ip daddr $listen_ip meta l4proto {tcp, udp} th dport $listen_port dnat to $remote_ip:$remote_port"
    else
        RULE_STR="        meta l4proto {tcp, udp} th dport $listen_port dnat to $remote_ip:$remote_port"
    fi

    sed -i "/# MARKER_END/i \\$RULE_STR" "$CONFIG_FILE"

    echo -e "${GREEN}规则添加成功！${PLAIN}"
    echo -e "已添加: [Local] $listen_ip:$listen_port -> [Remote] $remote_ip:$remote_port"
    echo -e "${YELLOW}注意：请重启服务 (选项 12) 使配置生效。${PLAIN}"
    wait_for_key
}

# 添加端口段转发规则
add_range_rule() {
    init_config
    echo -e "${YELLOW}=== 添加端口段转发规则 (TCP+UDP) ===${PLAIN}"
    echo -e "${YELLOW}说明：将本地端口段转发到目标服务器${PLAIN}"
    
    read -p "请输入监听 IP (默认 0.0.0.0, 回车即可): " listen_ip
    
    read -p "请输入起始监听端口 (必填): " port_start
    if [[ -z "$port_start" ]]; then
        echo -e "${RED}错误：起始端口不能为空。${PLAIN}"
        wait_for_key
        return
    fi
    
    read -p "请输入结束监听端口 (必填): " port_end
    if [[ -z "$port_end" ]]; then
        echo -e "${RED}错误：结束端口不能为空。${PLAIN}"
        wait_for_key
        return
    fi
    
    # 验证端口范围
    if ! validate_port_range "$port_start" "$port_end" "监听"; then
        wait_for_key
        return
    fi
    
    # 检查端口范围是否已存在
    if ! check_port_range_exists "$port_start" "$port_end"; then
        echo -e "${RED}错误：该端口范围内已有规则存在。${PLAIN}"
        wait_for_key
        return
    fi

    read -p "请输入转发目标 IP (必填): " remote_ip
    if [[ -z "$remote_ip" ]]; then
        echo -e "${RED}错误：目标 IP 不能为空。${PLAIN}"
        wait_for_key
        return
    fi
    
    read -p "请输入目标起始端口 (不填则默认与监听端口相同，1:1映射): " remote_port_start
    
    # 确认信息并构建规则
    if [[ -z "$remote_port_start" ]]; then
        # 1:1 映射
        echo -e "\n${YELLOW}请确认以下信息：${PLAIN}"
        echo -e "监听 IP: ${GREEN}${listen_ip:-0.0.0.0}${PLAIN}"
        echo -e "监听端口范围: ${GREEN}$port_start - $port_end${PLAIN}"
        echo -e "目标 IP: ${GREEN}$remote_ip${PLAIN}"
        echo -e "目标端口范围: ${GREEN}$port_start - $port_end (1:1映射)${PLAIN}"
        
        read -p "确认添加？[y/n] (默认 y): " confirm
        if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            echo -e "${YELLOW}已取消添加。${PLAIN}"
            wait_for_key
            return
        fi
        
        # 构建1:1映射规则
        if [[ -n "$listen_ip" && "$listen_ip" != "0.0.0.0" ]]; then
            RULE_STR="        ip daddr $listen_ip meta l4proto {tcp, udp} th dport { $port_start-$port_end } dnat to $remote_ip"
        else
            RULE_STR="        meta l4proto {tcp, udp} th dport { $port_start-$port_end } dnat to $remote_ip"
        fi
        
        echo -e "${GREEN}端口段规则添加成功！${PLAIN}"
        echo -e "已添加: [Local] ${listen_ip:-0.0.0.0}:$port_start-$port_end -> [Remote] $remote_ip:$port_start-$port_end (1:1映射)"
    else
        # 端口段偏移映射
        read -p "请输入目标结束端口 (必填): " remote_port_end
        if [[ -z "$remote_port_end" ]]; then
            echo -e "${RED}错误：目标结束端口不能为空。${PLAIN}"
            wait_for_key
            return
        fi
        
        # 验证目标端口范围
        if ! validate_port_range "$remote_port_start" "$remote_port_end" "目标"; then
            wait_for_key
            return
        fi
        
        # 检查端口数量是否一致
        local listen_count=$((port_end - port_start + 1))
        local remote_count=$((remote_port_end - remote_port_start + 1))
        if [ $listen_count -ne $remote_count ]; then
            echo -e "${RED}错误：监听端口数量 ($listen_count) 与目标端口数量 ($remote_count) 不一致。${PLAIN}"
            wait_for_key
            return
        fi
        
        echo -e "\n${YELLOW}请确认以下信息：${PLAIN}"
        echo -e "监听 IP: ${GREEN}${listen_ip:-0.0.0.0}${PLAIN}"
        echo -e "监听端口范围: ${GREEN}$port_start - $port_end${PLAIN}"
        echo -e "目标 IP: ${GREEN}$remote_ip${PLAIN}"
        echo -e "目标端口范围: ${GREEN}$remote_port_start - $remote_port_end (端口段偏移)${PLAIN}"
        
        read -p "确认添加？[y/n] (默认 y): " confirm
        if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            echo -e "${YELLOW}已取消添加。${PLAIN}"
            wait_for_key
            return
        fi
        
        # 构建端口映射字符串
        local map_str="{ "
        local l_port=$port_start
        local r_port=$remote_port_start
        local first=true
        
        while [ $l_port -le $port_end ]; do
            if [ "$first" = true ]; then
                first=false
            else
                map_str="$map_str, "
            fi
            map_str="$map_str$l_port : $r_port"
            l_port=$((l_port + 1))
            r_port=$((r_port + 1))
        done
        map_str="$map_str }"
        
        # 构建端口段偏移映射规则
        if [[ -n "$listen_ip" && "$listen_ip" != "0.0.0.0" ]]; then
            RULE_STR="        ip daddr $listen_ip meta l4proto {tcp, udp} th dport { $port_start-$port_end } dnat to $remote_ip : th dport map $map_str"
        else
            RULE_STR="        meta l4proto {tcp, udp} th dport { $port_start-$port_end } dnat to $remote_ip : th dport map $map_str"
        fi
        
        # 计算偏移量显示
        local offset=$((remote_port_start - port_start))
        if [ $offset -gt 0 ]; then
            offset_dir="向后偏移 $offset"
        elif [ $offset -lt 0 ]; then
            offset_dir="向前偏移 $((0 - offset))"
        else
            offset_dir="无偏移"
        fi
        
        echo -e "${GREEN}端口段规则添加成功！${PLAIN}"
        echo -e "已添加: [Local] ${listen_ip:-0.0.0.0}:$port_start-$port_end -> [Remote] $remote_ip:$remote_port_start-$remote_port_end (端口段$offset_dir)"
    fi

    sed -i "/# MARKER_END/i \\$RULE_STR" "$CONFIG_FILE"

    echo -e "${YELLOW}注意：请重启服务 (选项 12) 使配置生效。${PLAIN}"
    wait_for_key
}

# 查看现有规则
view_rules() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件不存在。${PLAIN}"
        wait_for_key
        return
    fi

    echo -e "${YELLOW}=== 现有转发规则 ===${PLAIN}"
    echo -e "格式: [监听IP]:监听端口(范围) -> 目标IP:目标端口(范围)"
    echo "--------------------------------"
    
    local rule_count=0
    while read -r line; do
        # 匹配单端口规则
        if echo "$line" | grep -q "dport [0-9]\+ dnat to"; then
            l_port=$(echo "$line" | grep -oP 'dport \K\d+')
            r_addr=$(echo "$line" | grep -oP 'dnat to \K[0-9.:]+')
            l_ip="0.0.0.0"
            
            if echo "$line" | grep -q "ip daddr"; then
                l_ip=$(echo "$line" | grep -oP 'ip daddr \K[0-9.]+')
            fi
            
            if [[ -n "$l_port" && -n "$r_addr" ]]; then
                echo "$l_ip:$l_port -> $r_addr"
                ((rule_count++))
            fi
        # 匹配端口段规则
        elif echo "$line" | grep -q "dport { [0-9]\+-[0-9]\+ } dnat to"; then
            l_range=$(echo "$line" | grep -oP 'dport { \K[0-9]+-[0-9]+')
            l_start=$(echo $l_range | cut -d'-' -f1)
            l_end=$(echo $l_range | cut -d'-' -f2)
            
            # 检查是否有端口映射
            if echo "$line" | grep -q "th dport map"; then
                # 有端口映射，提取第一个映射关系计算偏移
                r_ip=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+')
                map_part=$(echo "$line" | grep -oP '{ [0-9]+ : [0-9]+(, [0-9]+ : [0-9]+)* }')
                first_map=$(echo "$map_part" | grep -oP '[0-9]+ : [0-9]+' | head -1)
                l_map_port=$(echo "$first_map" | cut -d':' -f1 | tr -d ' ')
                r_map_port=$(echo "$first_map" | cut -d':' -f2 | tr -d ' ')
                
                if [[ -n "$l_map_port" && -n "$r_map_port" ]]; then
                    offset=$((r_map_port - l_map_port))
                    if [ $offset -gt 0 ]; then
                        offset_dir="向后偏移 $offset"
                    elif [ $offset -lt 0 ]; then
                        offset_dir="向前偏移 $((0 - offset))"
                    else
                        offset_dir="无偏移"
                    fi
                    
                    # 计算实际目标端口段
                    r_start=$((l_start + offset))
                    r_end=$((l_end + offset))
                    echo "$l_ip:$l_range -> $r_ip:$r_start-$r_end (端口段$offset_dir)"
                    ((rule_count++))
                fi
            else
                # 无端口映射，1:1映射
                r_ip=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+')
                l_ip="0.0.0.0"
                
                if echo "$line" | grep -q "ip daddr"; then
                    l_ip=$(echo "$line" | grep -oP 'ip daddr \K[0-9.]+')
                fi
                
                if [[ -n "$l_range" && -n "$r_ip" ]]; then
                    echo "$l_ip:$l_range -> $r_ip:$l_range (1:1映射)"
                    ((rule_count++))
                fi
            fi
        fi
    done < <(grep "dnat to" "$CONFIG_FILE")
    
    if [ $rule_count -eq 0 ]; then
        echo -e "${YELLOW}暂无转发规则。${PLAIN}"
    fi
    
    echo "--------------------------------"
    echo -e "总计: ${GREEN}$rule_count${PLAIN} 条规则"
    wait_for_key
}

# 快速修改转发规则 (Wizard)
quick_edit_rule() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件不存在。${PLAIN}"
        wait_for_key
        return
    fi

    echo -e "${YELLOW}=== 快速修改转发规则 ===${PLAIN}"
    
    # 收集所有规则行号
    mapfile -t line_numbers < <(grep -n "dnat to" "$CONFIG_FILE" | cut -d: -f1)
    total=${#line_numbers[@]}

    if [ $total -eq 0 ]; then
        echo -e "${RED}没有发现任何转发规则。${PLAIN}"
        wait_for_key
        return
    fi

    echo "当前共有 $total 条规则："
    local i=1
    for ln in "${line_numbers[@]}"; do
        line=$(sed -n "${ln}p" "$CONFIG_FILE")
        
        # 判断规则类型并显示
        if echo "$line" | grep -q "dport { [0-9]\+-[0-9]\+ }"; then
            # 端口段规则
            l_range=$(echo "$line" | grep -oP 'dport { \K[0-9]+-[0-9]+')
            l_start=$(echo $l_range | cut -d'-' -f1)
            l_end=$(echo $l_range | cut -d'-' -f2)
            l_ip="0.0.0.0"
            if echo "$line" | grep -q "ip daddr"; then
                l_ip=$(echo "$line" | grep -oP 'ip daddr \K[0-9.]+')
            fi
            
            # 检查是否有端口映射
            if echo "$line" | grep -q "th dport map"; then
                # 端口段偏移映射
                r_ip=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+')
                map_part=$(echo "$line" | grep -oP '{ [0-9]+ : [0-9]+(, [0-9]+ : [0-9]+)* }')
                first_map=$(echo "$map_part" | grep -oP '[0-9]+ : [0-9]+' | head -1)
                l_map_port=$(echo "$first_map" | cut -d':' -f1 | tr -d ' ')
                r_map_port=$(echo "$first_map" | cut -d':' -f2 | tr -d ' ')
                
                if [[ -n "$l_map_port" && -n "$r_map_port" ]]; then
                    offset=$((r_map_port - l_map_port))
                    if [ $offset -gt 0 ]; then
                        offset_dir="向后偏移 $offset"
                    elif [ $offset -lt 0 ]; then
                        offset_dir="向前偏移 $((0 - offset))"
                    else
                        offset_dir="无偏移"
                    fi
                    
                    # 计算实际目标端口段
                    r_start=$((l_start + offset))
                    r_end=$((l_end + offset))
                    echo -e "${GREEN}$i.${PLAIN} [端口段] $l_ip:$l_range -> $r_ip:$r_start-$r_end (端口段$offset_dir)"
                fi
            else
                # 1:1映射
                r_ip=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+')
                echo -e "${GREEN}$i.${PLAIN} [端口段] $l_ip:$l_range -> $r_ip:$l_range (1:1映射)"
            fi
        else
            # 单端口规则
            l_port=$(echo "$line" | grep -oP 'dport \K\d+')
            r_addr=$(echo "$line" | grep -oP 'dnat to \K[0-9.:]+')
            l_ip="0.0.0.0"
            if echo "$line" | grep -q "ip daddr"; then
                l_ip=$(echo "$line" | grep -oP 'ip daddr \K[0-9.]+')
            fi
            echo -e "${GREEN}$i.${PLAIN} [单端口] $l_ip:$l_port -> $r_addr"
        fi
        ((i++))
    done
    echo -e "--------------------------------"

    read -p "请输入要修改的规则序号 (输入 0 取消): " choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}输入无效。${PLAIN}"
        wait_for_key
        return
    fi
    if [ "$choice" -eq 0 ]; then main_menu; return; fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ]; then
        echo -e "${RED}序号超出范围。${PLAIN}"
        wait_for_key
        return
    fi

    idx=$((choice - 1))
    target_line_num=${line_numbers[$idx]}
    line_content=$(sed -n "${target_line_num}p" "$CONFIG_FILE")
    
    # 判断规则类型并执行相应的修改逻辑
    if echo "$line_content" | grep -q "dport { [0-9]\+-[0-9]\+ }"; then
        # 端口段规则修改
        echo -e "${YELLOW}正在修改端口段规则...${PLAIN}"
        
        # 提取当前规则信息
        old_l_range=$(echo "$line_content" | grep -oP 'dport { \K[0-9]+-[0-9]+')
        old_l_start=$(echo $old_l_range | cut -d'-' -f1)
        old_l_end=$(echo $old_l_range | cut -d'-' -f2)
        old_l_ip="0.0.0.0"
        if echo "$line_content" | grep -q "ip daddr"; then
            old_l_ip=$(echo "$line_content" | grep -oP 'ip daddr \K[0-9.]+')
        fi
        
        # 检查是否是端口段偏移映射
        local is_offset=false
        local old_r_ip=""
        local old_r_start=""
        local old_r_end=""
        
        if echo "$line_content" | grep -q "th dport map"; then
            is_offset=true
            old_r_ip=$(echo "$line_content" | grep -oP 'dnat to \K[0-9.]+')
            # 从映射中提取目标端口范围
            map_part=$(echo "$line_content" | grep -oP '{ [0-9]+ : [0-9]+(, [0-9]+ : [0-9]+)* }')
            first_map=$(echo "$map_part" | grep -oP '[0-9]+ : [0-9]+' | head -1)
            last_map=$(echo "$map_part" | grep -oP '[0-9]+ : [0-9]+' | tail -1)
            r_first_port=$(echo "$first_map" | cut -d':' -f2 | tr -d ' ')
            r_last_port=$(echo "$last_map" | cut -d':' -f2 | tr -d ' ')
            old_r_start=$r_first_port
            old_r_end=$r_last_port
        else
            # 1:1映射
            old_r_ip=$(echo "$line_content" | grep -oP 'dnat to \K[0-9.]+')
            old_r_start=$old_l_start
            old_r_end=$old_l_end
        fi
        
        echo -e "${YELLOW}请逐项输入新值 (直接回车保持原值):${PLAIN}"
        
        # 修改监听IP
        read -p "监听 IP [当前: $old_l_ip]: " new_l_ip
        [[ -z "$new_l_ip" ]] && new_l_ip="$old_l_ip"
        
        # 修改监听端口范围
        read -p "监听起始端口 [当前: $old_l_start]: " new_l_start
        [[ -z "$new_l_start" ]] && new_l_start="$old_l_start"
        
        read -p "监听结束端口 [当前: $old_l_end]: " new_l_end
        [[ -z "$new_l_end" ]] && new_l_end="$old_l_end"
        
        # 验证监听端口范围
        if ! validate_port_range "$new_l_start" "$new_l_end" "监听"; then
            wait_for_key
            return
        fi
        
        # 修改目标IP
        read -p "目标 IP [当前: $old_r_ip]: " new_r_ip
        [[ -z "$new_r_ip" ]] && new_r_ip="$old_r_ip"
        
        # 询问修改类型
        echo -e "\n${YELLOW}请选择转发类型:${PLAIN}"
        echo "[1]1:1映射 (目标端口与监听端口相同)"
        echo "[2]端口段偏移 (自定义目标端口范围)"
        read -p "请选择 [1/2] (默认 1): " rule_type
        
        if [[ "$rule_type" == "2" ]]; then
            # 端口段偏移映射
            read -p "目标起始端口 [当前: $old_r_start]: " new_r_start
            [[ -z "$new_r_start" ]] && new_r_start="$old_r_start"
            
            read -p "目标结束端口 [当前: $old_r_end]: " new_r_end
            [[ -z "$new_r_end" ]] && new_r_end="$old_r_end"
            
            # 验证目标端口范围
            if ! validate_port_range "$new_r_start" "$new_r_end" "目标"; then
                wait_for_key
                return
            fi
            
            # 检查端口数量是否一致
            local listen_count=$((new_l_end - new_l_start + 1))
            local remote_count=$((new_r_end - new_r_start + 1))
            if [ $listen_count -ne $remote_count ]; then
                echo -e "${RED}错误：监听端口数量 ($listen_count) 与目标端口数量 ($remote_count) 不一致。${PLAIN}"
                wait_for_key
                return
            fi
            
            # 构建端口映射字符串
            local map_str="{ "
            local l_port=$new_l_start
            local r_port=$new_r_start
            local first=true
            
            while [ $l_port -le $new_l_end ]; do
                if [ "$first" = true ]; then
                    first=false
                else
                    map_str="$map_str, "
                fi
                map_str="$map_str$l_port : $r_port"
                l_port=$((l_port + 1))
                r_port=$((r_port + 1))
            done
            map_str="$map_str }"
            
            # 构建端口段偏移映射规则
            if [[ -n "$new_l_ip" && "$new_l_ip" != "0.0.0.0" ]]; then
                NEW_RULE="        ip daddr $new_l_ip meta l4proto {tcp, udp} th dport { $new_l_start-$new_l_end } dnat to $new_r_ip : th dport map $map_str"
            else
                NEW_RULE="        meta l4proto {tcp, udp} th dport { $new_l_start-$new_l_end } dnat to $new_r_ip : th dport map $map_str"
            fi
            
            # 计算偏移量显示
            local offset=$((new_r_start - new_l_start))
            if [ $offset -gt 0 ]; then
                offset_dir="向后偏移 $offset"
            elif [ $offset -lt 0 ]; then
                offset_dir="向前偏移 $((0 - offset))"
            else
                offset_dir="无偏移"
            fi
            
            echo -e "${GREEN}规则修改成功！${PLAIN}"
            echo -e "新规则: $new_l_ip:$new_l_start-$new_l_end -> $new_r_ip:$new_r_start-$new_r_end (端口段$offset_dir)"
        else
            # 1:1映射
            if [[ -n "$new_l_ip" && "$new_l_ip" != "0.0.0.0" ]]; then
                NEW_RULE="        ip daddr $new_l_ip meta l4proto {tcp, udp} th dport { $new_l_start-$new_l_end } dnat to $new_r_ip"
            else
                NEW_RULE="        meta l4proto {tcp, udp} th dport { $new_l_start-$new_l_end } dnat to $new_r_ip"
            fi
            
            echo -e "${GREEN}规则修改成功！${PLAIN}"
            echo -e "新规则: $new_l_ip:$new_l_start-$new_l_end -> $new_r_ip:$new_l_start-$new_l_end (1:1映射)"
        fi
    else
        # 原有的单端口修改逻辑
        old_l_port=$(echo "$line_content" | grep -oP 'dport \K\d+')
        old_full_remote=$(echo "$line_content" | grep -oP 'dnat to \K[0-9.:]+')
        old_r_port=$(echo "$old_full_remote" | rev | cut -d: -f1 | rev)
        old_r_ip=$(echo "$old_full_remote" | rev | cut -d: -f2- | rev)
        old_l_ip="0.0.0.0"
        if echo "$line_content" | grep -q "ip daddr"; then
            old_l_ip=$(echo "$line_content" | grep -oP 'ip daddr \K[0-9.]+')
        fi

        echo -e "${YELLOW}请逐项输入新值 (直接回车保持原值):${PLAIN}"

        read -p "监听 IP [当前: $old_l_ip]: " new_l_ip
        [[ -z "$new_l_ip" ]] && new_l_ip="$old_l_ip"
        
        read -p "监听 端口 [当前: $old_l_port]: " new_l_port
        [[ -z "$new_l_port" ]] && new_l_port="$old_l_port"

        read -p "目标 IP [当前: $old_r_ip]: " new_r_ip
        [[ -z "$new_r_ip" ]] && new_r_ip="$old_r_ip"

        read -p "目标 端口 [当前: $old_r_port]: " new_r_port
        [[ -z "$new_r_port" ]] && new_r_port="$old_r_port"

        if [[ -n "$new_l_ip" && "$new_l_ip" != "0.0.0.0" ]]; then
            NEW_RULE="        ip daddr $new_l_ip meta l4proto {tcp, udp} th dport $new_l_port dnat to $new_r_ip:$new_r_port"
        else
            NEW_RULE="        meta l4proto {tcp, udp} th dport $new_l_port dnat to $new_r_ip:$new_r_port"
        fi

        echo -e "${GREEN}规则修改成功！${PLAIN}"
        echo -e "新规则: $new_l_ip:$new_l_port -> $new_r_ip:$new_r_port"
    fi

    sed -i "${target_line_num}c\\$NEW_RULE" "$CONFIG_FILE"

    echo -e "${YELLOW}注意：请重启服务 (选项 12) 使配置生效。${PLAIN}"
    wait_for_key
}

# 修改现有转发规则 (nano)
edit_rule_nano() {
    echo -e "${GREEN}正在打开配置文件 (使用 nano)...${PLAIN}"
    echo -e "${YELLOW}提示：Nftables 语法严格，请确保保留 chain prerouting 和 chain postrouting 结构。${PLAIN}"
    sleep 2
    nano "$CONFIG_FILE"
    echo -e "${GREEN}修改完成。${PLAIN}"
    echo -e "${YELLOW}注意：请重启服务 (选项 12) 使配置生效。${PLAIN}"
    wait_for_key
}

# 修改现有转发规则 (vim)
edit_rule_vim() {
    # 确保 vim 已安装
    if ! command -v vim &> /dev/null; then
        echo -e "${YELLOW}检测到系统未安装 vim，正在自动安装...${PLAIN}"
        if [ "$IS_ALPINE" -eq 1 ]; then
            apk add vim
        else
            apt-get update && apt-get install -y vim
        fi
    fi
    
    echo -e "${GREEN}正在打开配置文件 (使用 vim)...${PLAIN}"
    echo -e "${YELLOW}提示：Nftables 语法严格，请确保保留 chain prerouting 和 chain postrouting 结构。${PLAIN}"
    echo -e "${YELLOW}vim 基础操作: i 进入编辑模式, Esc 退出编辑模式, :wq 保存退出, :q! 不保存退出${PLAIN}"
    sleep 3
    vim -n "$CONFIG_FILE"
    echo -e "${GREEN}修改完成。${PLAIN}"
    echo -e "${YELLOW}注意：请重启服务 (选项 12) 使配置生效。${PLAIN}"
    wait_for_key
}

# 选择编辑器修改配置文件
choose_editor() {
    echo -e "${YELLOW}=== 选择编辑器 ===${PLAIN}"
    echo -e " 1. 使用 nano 编辑 (简单易用)"
    echo -e " 2. 使用 vim 编辑 (功能强大)"
    echo -e " 0. 返回主菜单"
    read -p "请输入数字: " editor_choice
    
    case "$editor_choice" in
        1) edit_rule_nano ;;
        2) edit_rule_vim ;;
        0) main_menu ;;
        *) echo -e "${RED}请输入正确的数字！${PLAIN}"; sleep 1; choose_editor ;;
    esac
}

# 删除转发规则
delete_rule() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件不存在。${PLAIN}"
        wait_for_key
        return
    fi

    echo -e "${YELLOW}=== 删除转发规则 ===${PLAIN}"
    
    line_numbers=($(grep -n "dnat to" "$CONFIG_FILE" | cut -d: -f1))
    total=${#line_numbers[@]}

    if [ $total -eq 0 ]; then
        echo -e "${RED}没有发现任何转发规则。${PLAIN}"
        wait_for_key
        return
    fi

    echo "当前共有 $total 条规则："
    local i=1
    for ln in "${line_numbers[@]}"; do
        line=$(sed -n "${ln}p" "$CONFIG_FILE")
        
        # 判断是单端口还是端口段规则
        if echo "$line" | grep -q "dport { [0-9]\+-[0-9]\+ }"; then
            # 端口段规则
            l_range=$(echo "$line" | grep -oP 'dport { \K[0-9]+-[0-9]+')
            l_start=$(echo $l_range | cut -d'-' -f1)
            l_end=$(echo $l_range | cut -d'-' -f2)
            
            # 检查是否有端口映射
            if echo "$line" | grep -q "th dport map"; then
                # 有端口映射，提取第一个映射关系计算偏移
                r_ip=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+')
                map_part=$(echo "$line" | grep -oP '{ [0-9]+ : [0-9]+(, [0-9]+ : [0-9]+)* }')
                first_map=$(echo "$map_part" | grep -oP '[0-9]+ : [0-9]+' | head -1)
                l_map_port=$(echo "$first_map" | cut -d':' -f1 | tr -d ' ')
                r_map_port=$(echo "$first_map" | cut -d':' -f2 | tr -d ' ')
                
                if [[ -n "$l_map_port" && -n "$r_map_port" ]]; then
                    offset=$((r_map_port - l_map_port))
                    if [ $offset -gt 0 ]; then
                        offset_dir="向后偏移 $offset"
                    elif [ $offset -lt 0 ]; then
                        offset_dir="向前偏移 $((0 - offset))"
                    else
                        offset_dir="无偏移"
                    fi
                    
                    # 计算实际目标端口段
                    r_start=$((l_start + offset))
                    r_end=$((l_end + offset))
                    echo -e "${GREEN}$i.${PLAIN} [端口段] $l_ip:$l_range -> $r_ip:$r_start-$r_end (端口段$offset_dir)"
                fi
            else
                # 无端口映射，1:1映射
                r_ip=$(echo "$line" | grep -oP 'dnat to \K[0-9.]+')
                l_ip="0.0.0.0"
                if echo "$line" | grep -q "ip daddr"; then
                    l_ip=$(echo "$line" | grep -oP 'ip daddr \K[0-9.]+')
                fi
                echo -e "${GREEN}$i.${PLAIN} [端口段] $l_ip:$l_range -> $r_ip:$l_range (1:1映射)"
            fi
        else
            # 单端口规则
            l_port=$(echo "$line" | grep -oP 'dport \K\d+')
            r_addr=$(echo "$line" | grep -oP 'dnat to \K[0-9.:]+')
            l_ip="0.0.0.0"
            if echo "$line" | grep -q "ip daddr"; then
                l_ip=$(echo "$line" | grep -oP 'ip daddr \K[0-9.]+')
            fi
            echo -e "${GREEN}$i.${PLAIN} [单端口] $l_ip:$l_port -> $r_addr"
        fi
        ((i++))
    done

    echo -e "--------------------------------"
    read -p "请输入要删除的规则序号 (输入 0 取消): " choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}输入无效，请输入数字。${PLAIN}"
        wait_for_key
        return
    fi
    if [ "$choice" -eq 0 ]; then main_menu; return; fi
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ]; then
        echo -e "${RED}序号超出范围。${PLAIN}"
        wait_for_key
        return
    fi

    idx=$((choice - 1))
    target_line_num=${line_numbers[$idx]}
    
    # 显示将要删除的规则
    echo -e "${YELLOW}即将删除规则:${PLAIN}"
    sed -n "${target_line_num}p" "$CONFIG_FILE"
    read -p "确认删除？[y/n] (默认 y): " confirm
    
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        echo -e "${YELLOW}已取消删除。${PLAIN}"
        wait_for_key
        return
    fi
    
    sed -i "${target_line_num}d" "$CONFIG_FILE"
    
    echo -e "${GREEN}规则 $choice 已删除。${PLAIN}"
    echo -e "${YELLOW}注意：请重启服务 (选项 12) 使配置生效。${PLAIN}"
    wait_for_key
}

# 服务管理统一入口
manage_service() {
    action=$1
    
    if [ "$IS_ALPINE" -eq 1 ]; then
        # Alpine (OpenRC)
        case "$action" in
            enable)
                rc-update add nftables default
                echo -e "${GREEN}已设置开机自启 (OpenRC)。${PLAIN}"
                ;;
            disable)
                rc-update del nftables default
                echo -e "${GREEN}已取消开机自启 (OpenRC)。${PLAIN}"
                ;;
            start)
                if rc-service nftables status 2>/dev/null | grep -q "started"; then
                    echo -e "${YELLOW}服务已经在运行中。${PLAIN}"
                else
                    rc-service nftables start
                    echo -e "${GREEN}服务已启动。${PLAIN}"
                fi
                ;;
            stop)
                rc-service nftables stop
                echo -e "${GREEN}服务已停止。${PLAIN}"
                ;;
            restart)
                rc-service nftables restart
                echo -e "${GREEN}服务已重启并加载新配置。${PLAIN}"
                ;;
        esac
    else
        # Debian/Ubuntu (Systemd)
        case "$action" in
            enable)
                systemctl enable nftables
                echo -e "${GREEN}已设置开机自启 (Systemd)。${PLAIN}"
                ;;
            disable)
                systemctl disable nftables
                echo -e "${GREEN}已取消开机自启 (Systemd)。${PLAIN}"
                ;;
            start)
                if systemctl is-active --quiet nftables; then
                    echo -e "${YELLOW}服务已经在运行中。${PLAIN}"
                else
                    systemctl start nftables
                    echo -e "${GREEN}服务已启动。${PLAIN}"
                fi
                ;;
            stop)
                systemctl stop nftables
                echo -e "${GREEN}服务已停止。${PLAIN}"
                ;;
            restart)
                systemctl restart nftables
                echo -e "${GREEN}服务已重启并加载新配置。${PLAIN}"
                ;;
        esac
    fi
    wait_for_key
}

# 清空配置 (替代卸载)
clear_config() {
    echo -e "${RED}警告：此操作将清空所有已添加的转发规则！${PLAIN}"
    read -p "确定要清空配置并重置为初始状态吗？[y/n]: " choice
    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        # 备份当前配置
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
        echo -e "${YELLOW}当前配置已备份至 ${CONFIG_FILE}.bak${PLAIN}"

        # 强制重置配置文件
        init_config force
        
        # 立即生效
        if command -v nft &> /dev/null; then
            nft flush ruleset
            nft -f "$CONFIG_FILE"
        fi

        echo -e "${GREEN}配置已成功清空并重置。${PLAIN}"
    else
        echo -e "${YELLOW}取消操作。${PLAIN}"
    fi
    wait_for_key
}

# 更新脚本
update_script() {
    echo -e "${GREEN}正在检查脚本更新...${PLAIN}"
    
    # 下载新脚本
    curl -L -o /tmp/nft_helper_new.sh "$UPDATE_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}更新失败，无法连接到 GitHub。${PLAIN}"
        wait_for_key
        return
    fi

    # 简单校验
    if ! grep -q "#!/bin/bash" /tmp/nft_helper_new.sh; then
        echo -e "${RED}下载的文件无效，请检查 URL 或网络。${PLAIN}"
        rm -f /tmp/nft_helper_new.sh
        wait_for_key
        return
    fi

    # 覆盖当前脚本
    mv /tmp/nft_helper_new.sh "$0"
    chmod +x "$0"
    
    # 同时更新快捷方式
    if [[ "$(realpath "$0")" != "$(realpath "$SHORTCUT_PATH")" ]]; then
        cp "$0" "$SHORTCUT_PATH"
        chmod +x "$SHORTCUT_PATH"
    fi

    echo -e "${GREEN}脚本更新成功！正在重启脚本...${PLAIN}"
    sleep 2
    exec "$0"
}

# 主菜单
main_menu() {
    clear
    get_status
    echo -e "################################################"
    echo -e "#         Caesar 蜜汁 Nft 端口转发管理脚本        #"
    echo -e "#          系统: ${SYS_TYPE}        #"
    echo -e "################################################"
    echo -e "Nftables 状态: ${INSTALL_STATUS}"
    echo -e "服务运行 状态: ${RUN_STATUS}"
    echo -e "IP转发   状态: ${FW_STATUS}"
    echo -e "提示: 输入 nft-helper 可快速启动本脚本"
    echo -e "################################################"
    echo -e " 1. 安装 / 重置 Nftables 配置"
    echo -e " 2. 添加单端口转发规则"
    echo -e " 3. 添加端口段转发规则"
    echo -e " 4. 查看现有转发规则"
    echo -e " 5. 快速修改转发规则 (向导)"
    echo -e " 6. 修改配置文件 (选择编辑器)"
    echo -e " 7. 删除转发规则"
    echo -e "------------------------------------------------"
    echo -e " 8. 设置开机自启 (enable)"
    echo -e " 9. 取消开机自启 (disable)"
    echo -e "10. 启动服务 (start)"
    echo -e "11. 停止服务 (stop)"
    echo -e "12. 重启服务 (restart - 应用配置)"
    echo -e "------------------------------------------------"
    echo -e "13. 清空所有规则 (重置配置)"
    echo -e "99. 更新本脚本"
    echo -e " 0. 退出脚本"
    echo -e "################################################"
    read -p "请输入数字: " num

    case "$num" in
        1) install_nftables ;;
        2) add_rule ;;
        3) add_range_rule ;;
        4) view_rules ;;
        5) quick_edit_rule ;;
        6) choose_editor ;;
        7) delete_rule ;;
        8) manage_service enable ;;
        9) manage_service disable ;;
        10) manage_service start ;;
        11) manage_service stop ;;
        12) manage_service restart ;;
        13) clear_config ;;
        99) update_script ;;
        0) echo -e "${GREEN}谢谢使用本脚本，再见。${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}请输入正确的数字！${PLAIN}"; sleep 1; main_menu ;;
    esac
}

# 脚本入口
check_dependencies
check_shortcut
main_menu