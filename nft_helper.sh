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
        if ! command -v curl &> /dev/null || ! command -v nano &> /dev/null || ! command -v grep &> /dev/null; then
            apt-get update && apt-get install -y curl nano grep
        fi
    else
        # Alpine
        if ! command -v curl &> /dev/null; then
            apk add curl
        fi
        if ! command -v nano &> /dev/null; then
            apk add nano
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

# 添加转发规则
add_rule() {
    init_config
    echo -e "${YELLOW}=== 添加转发规则 (TCP+UDP) ===${PLAIN}"
    
    read -p "请输入监听 IP (默认 0.0.0.0, 回车即可): " listen_ip
    
    read -p "请输入监听端口 (必填): " listen_port
    if [[ -z "$listen_port" ]]; then
        echo -e "${RED}错误：监听端口不能为空。${PLAIN}"
        wait_for_key
        return
    fi

    if grep -q "dport $listen_port dnat" "$CONFIG_FILE"; then
        echo -e "${RED}错误：该端口已在配置文件中存在。${PLAIN}"
        exit 1
    fi

    read -p "请输入转发目标 IP (必填): " remote_ip
    if [[ -z "$remote_ip" ]]; then
        echo -e "${RED}错误：目标 IP 不能为空。${PLAIN}"
        exit 1
    fi

    read -p "请输入转发目标端口 (必填): " remote_port
    if [[ -z "$remote_port" ]]; then
        echo -e "${RED}错误：目标端口 不能为空。${PLAIN}"
        exit 1
    fi

    if [[ -n "$listen_ip" && "$listen_ip" != "0.0.0.0" ]]; then
        RULE_STR="        ip daddr $listen_ip meta l4proto {tcp, udp} th dport $listen_port dnat to $remote_ip:$remote_port"
    else
        RULE_STR="        meta l4proto {tcp, udp} th dport $listen_port dnat to $remote_ip:$remote_port"
    fi

    sed -i "/# MARKER_END/i \\$RULE_STR" "$CONFIG_FILE"

    echo -e "${GREEN}规则添加成功！${PLAIN}"
    echo -e "已添加: [Local] $listen_ip:$listen_port -> [Remote] $remote_ip:$remote_port"
    echo -e "${YELLOW}注意：请重启服务 (选项 11) 使配置生效。${PLAIN}"
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
    echo -e "格式: [监听IP]:监听端口 -> 目标IP:目标端口"
    echo "--------------------------------"
    
    grep "dnat to" "$CONFIG_FILE" | while read -r line; do
        l_port=$(echo "$line" | grep -oP 'dport \K\d+')
        r_addr=$(echo "$line" | grep -oP 'dnat to \K[0-9.:]+')
        l_ip="0.0.0.0"
        
        if echo "$line" | grep -q "ip daddr"; then
            l_ip=$(echo "$line" | grep -oP 'ip daddr \K[0-9.]+')
        fi
        
        if [[ -n "$l_port" && -n "$r_addr" ]]; then
            echo "$l_ip:$l_port -> $r_addr"
        fi
    done
    
    echo "--------------------------------"
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
        l_port=$(echo "$line" | grep -oP 'dport \K\d+')
        r_addr=$(echo "$line" | grep -oP 'dnat to \K[0-9.:]+')
        l_ip="0.0.0.0"
        if echo "$line" | grep -q "ip daddr"; then
            l_ip=$(echo "$line" | grep -oP 'ip daddr \K[0-9.]+')
        fi
        
        echo -e "${GREEN}$i.${PLAIN} $l_ip:$l_port -> $r_addr"
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

    sed -i "${target_line_num}c\\$NEW_RULE" "$CONFIG_FILE"

    echo -e "${GREEN}规则修改成功！${PLAIN}"
    echo -e "新规则: $new_l_ip:$new_l_port -> $new_r_ip:$new_r_port"
    echo -e "${YELLOW}注意：请重启服务 (选项 11) 使配置生效。${PLAIN}"
    wait_for_key
}

# 修改现有转发规则 (nano)
edit_rule_nano() {
    echo -e "${GREEN}正在打开配置文件...${PLAIN}"
    echo -e "${YELLOW}提示：Nftables 语法严格，请确保保留 chain prerouting 和 chain postrouting 结构。${PLAIN}"
    sleep 2
    nano "$CONFIG_FILE"
    echo -e "${GREEN}修改完成。${PLAIN}"
    echo -e "${YELLOW}注意：请重启服务 (选项 11) 使配置生效。${PLAIN}"
    wait_for_key
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
        l_port=$(echo "$line" | grep -oP 'dport \K\d+')
        r_addr=$(echo "$line" | grep -oP 'dnat to \K[0-9.:]+')
        l_ip="0.0.0.0"
        if echo "$line" | grep -q "ip daddr"; then
            l_ip=$(echo "$line" | grep -oP 'ip daddr \K[0-9.]+')
        fi
        
        echo -e "${GREEN}$i.${PLAIN} $l_ip:$l_port -> $r_addr"
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
    
    sed -i "${target_line_num}d" "$CONFIG_FILE"
    
    echo -e "${GREEN}规则 $choice 已删除。${PLAIN}"
    echo -e "${YELLOW}注意：请重启服务 (选项 11) 使配置生效。${PLAIN}"
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
                # Nftables 推荐使用 reload 重新加载配置，但也支持 restart
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
    echo -e " 2. 添加转发规则"
    echo -e " 3. 查看现有转发规则"
    echo -e " 4. 快速修改转发规则 (向导)"
    echo -e " 5. 修改配置文件 (nano)"
    echo -e " 6. 删除转发规则"
    echo -e "------------------------------------------------"
    echo -e " 7. 设置开机自启 (enable)"
    echo -e " 8. 取消开机自启 (disable)"
    echo -e " 9. 启动服务 (start)"
    echo -e " 10. 停止服务 (stop)"
    echo -e " 11. 重启服务 (restart - 应用配置)"
    echo -e "------------------------------------------------"
    echo -e " 12. 清空所有规则 (重置配置)"
    echo -e " 99. 更新本脚本"
    echo -e " 0. 退出脚本"
    echo -e "################################################"
    read -p "请输入数字: " num

    case "$num" in
        1) install_nftables ;;
        2) add_rule ;;
        3) view_rules ;;
        4) quick_edit_rule ;;
        5) edit_rule_nano ;;
        6) delete_rule ;;
        7) manage_service enable ;;
        8) manage_service disable ;;
        9) manage_service start ;;
        10) manage_service stop ;;
        11) manage_service restart ;;
        12) clear_config ;;
        99) update_script ;;
        0) echo -e "${GREEN}谢谢使用本脚本，再见。${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}请输入正确的数字！${PLAIN}"; sleep 1; main_menu ;;
    esac
}

# 脚本入口
check_dependencies
check_shortcut
main_menu
