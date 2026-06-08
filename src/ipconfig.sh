#!/bin/bash

# 出入站 IP 配置管理

# IP 配置文件
is_ip_config_file=$is_core_dir/ip_config.conf

# IP 配置变量
SERVER_IP=""
SERVER_IPV6=""
INBOUND_IP_MODE="dual"
OUTBOUND_IP_MODE="dual"

# 保存 IP 配置到文件
save_ip_config() {
    mkdir -p "$(dirname "${is_ip_config_file}")"
    cat > "${is_ip_config_file}" << EOF
# Sing-box IP 配置
SERVER_IP="${SERVER_IP}"
SERVER_IPV6="${SERVER_IPV6}"
INBOUND_IP_MODE="${INBOUND_IP_MODE}"
OUTBOUND_IP_MODE="${OUTBOUND_IP_MODE}"
EOF
}

# 从文件加载 IP 配置
load_ip_config() {
    if [[ -f "${is_ip_config_file}" ]] && [[ -r "${is_ip_config_file}" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            value="${value#\"}"
            value="${value%\"}"
            case "$key" in
                SERVER_IP) SERVER_IP="$value" ;;
                SERVER_IPV6) SERVER_IPV6="$value" ;;
                INBOUND_IP_MODE) INBOUND_IP_MODE="$value" ;;
                OUTBOUND_IP_MODE) OUTBOUND_IP_MODE="$value" ;;
            esac
        done < "${is_ip_config_file}"
    fi
}

# 获取监听地址
get_listen_address() {
    case "${INBOUND_IP_MODE}" in
        "ipv4")
            echo "0.0.0.0"
            ;;
        "ipv6")
            echo "::"
            ;;
        "dual"|*)
            echo "::"
            ;;
    esac
}

# 获取服务器 IP
get_server_ip() {
    [[ -n "$SERVER_IP" ]] && return

    local ipv4=""
    local ipv6=""

    ipv4=$(_wget -4 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep ip= | cut -d= -f2)
    [[ -z "$ipv4" ]] && ipv4=$(_wget -4 -qO- https://api.ipify.org 2>/dev/null)

    ipv6=$(_wget -6 -qO- https://one.one.one.one/cdn-cgi/trace 2>/dev/null | grep ip= | cut -d= -f2)
    [[ -z "$ipv6" ]] && ipv6=$(_wget -6 -qO- https://api6.ipify.org 2>/dev/null)

    if [[ -n "$ipv4" ]]; then
        SERVER_IP="$ipv4"
    fi
    if [[ -n "$ipv6" ]]; then
        SERVER_IPV6="$ipv6"
    fi

    if [[ -n "$ipv4" || -n "$ipv6" ]]; then
        save_ip_config
    fi
}

# 更新 config.json 中的出站 IP 配置
update_outbound_ip_config() {
    if [[ ! -f $is_config_json ]]; then
        return
    fi

    local tmp_config=$(mktemp)

    # 更新 direct outbound 的绑定地址
    if [[ "$OUTBOUND_IP_MODE" == "ipv6" ]]; then
        if [[ -n "${SERVER_IPV6}" ]]; then
            jq --arg ipv6 "${SERVER_IPV6}" '
                (.outbounds[] | select(.tag == "direct")) |= . + {"inet6_bind_address": $ipv6, "domain_resolver": {"server": "remote", "strategy": "prefer_ipv6"}}
            ' $is_config_json > "$tmp_config"
        else
            jq '(.outbounds[] | select(.tag == "direct")) |= . + {"domain_resolver": {"server": "remote", "strategy": "prefer_ipv6"}}' $is_config_json > "$tmp_config"
        fi
    elif [[ "$OUTBOUND_IP_MODE" == "ipv6_only" ]]; then
        if [[ -n "${SERVER_IPV6}" ]]; then
            jq --arg ipv6 "${SERVER_IPV6}" '
                (.outbounds[] | select(.tag == "direct")) |= . + {"inet6_bind_address": $ipv6, "domain_resolver": {"server": "remote", "strategy": "ipv6_only"}}
            ' $is_config_json > "$tmp_config"
        else
            jq '(.outbounds[] | select(.tag == "direct")) |= . + {"domain_resolver": {"server": "remote", "strategy": "ipv6_only"}}' $is_config_json > "$tmp_config"
        fi
    elif [[ "$OUTBOUND_IP_MODE" == "ipv4" ]]; then
        if [[ -n "${SERVER_IP}" ]]; then
            jq --arg ipv4 "${SERVER_IP}" '
                (.outbounds[] | select(.tag == "direct")) |= . + {"inet4_bind_address": $ipv4, "domain_resolver": {"server": "remote", "strategy": "ipv4_only"}}
            ' $is_config_json > "$tmp_config"
        else
            jq '(.outbounds[] | select(.tag == "direct")) |= . + {"domain_resolver": {"server": "remote", "strategy": "ipv4_only"}}' $is_config_json > "$tmp_config"
        fi
    else
        # dual 模式，不修改
        rm -f "$tmp_config"
        return
    fi

    mv "$tmp_config" $is_config_json
    manage restart &
}

# ==================== 出入站 IP 配置菜单 ====================

ip_config_menu() {
    load_ip_config
    get_server_ip

    while true; do
        echo
        msg "------------- 出入站 IP 配置 -------------"
        echo
        msg "${yellow}当前配置:${none}"
        [[ -n "$SERVER_IP" ]] && echo -e "  IPv4 地址: ${green}${SERVER_IP}${none}"
        [[ -n "$SERVER_IPV6" ]] && echo -e "  IPv6 地址: ${green}${SERVER_IPV6}${none}"
        echo -e "  入站模式: ${green}${INBOUND_IP_MODE}${none}     出站模式: ${green}${OUTBOUND_IP_MODE}${none}"
        echo
        msg "${cyan}说明:${none}"
        echo -e "  ${yellow}入站${none}: 控制节点监听的 IP 版本"
        echo -e "  ${yellow}出站${none}: 控制服务器对外连接的 IP 版本"
        echo
        echo -e "  ${green}[1]${none} 设置入站为 IPv4"
        echo -e "  ${green}[2]${none} 设置入站为 IPv6"
        echo -e "  ${green}[3]${none} 设置入站为双栈 (IPv4+IPv6)"
        echo -e "  ${green}[4]${none} 设置出站为 IPv4"
        echo -e "  ${green}[5]${none} 设置出站为 IPv6 (优先)"
        echo -e "  ${green}[6]${none} 设置出站为仅 IPv6"
        echo -e "  ${green}[7]${none} 设置出站为双栈 (IPv4+IPv6)"
        echo -e "  ${green}[8]${none} 手动修改 IPv4 地址"
        echo -e "  ${green}[9]${none} 手动修改 IPv6 地址"
        echo -e "  ${green}[0]${none} 返回主菜单"
        echo
        echo -ne "请选择 [0-9]: "
        read ip_choice

        case $ip_choice in
            1)
                INBOUND_IP_MODE="ipv4"
                save_ip_config
                _green "\n入站已设置为 IPv4\n"
                ;;
            2)
                [[ -z "$SERVER_IPV6" ]] && { warn "未检测到 IPv6 地址"; continue; }
                INBOUND_IP_MODE="ipv6"
                save_ip_config
                _green "\n入站已设置为 IPv6\n"
                ;;
            3)
                INBOUND_IP_MODE="dual"
                save_ip_config
                _green "\n入站已设置为双栈\n"
                ;;
            4)
                OUTBOUND_IP_MODE="ipv4"
                save_ip_config
                _green "\n出站已设置为 IPv4\n"
                update_outbound_ip_config
                ;;
            5)
                [[ -z "$SERVER_IPV6" ]] && { warn "未检测到 IPv6 地址"; continue; }
                OUTBOUND_IP_MODE="ipv6"
                save_ip_config
                _green "\n出站已设置为 IPv6 优先\n"
                update_outbound_ip_config
                ;;
            6)
                [[ -z "$SERVER_IPV6" ]] && { warn "未检测到 IPv6 地址"; continue; }
                OUTBOUND_IP_MODE="ipv6_only"
                save_ip_config
                _green "\n出站已设置为仅 IPv6\n"
                update_outbound_ip_config
                ;;
            7)
                OUTBOUND_IP_MODE="dual"
                save_ip_config
                _green "\n出站已设置为双栈\n"
                update_outbound_ip_config
                ;;
            8)
                echo -ne "请输入 IPv4 地址: "
                read new_ipv4
                if [[ -n "$new_ipv4" ]]; then
                    SERVER_IP="$new_ipv4"
                    save_ip_config
                    _green "\nIPv4 地址已更新: ${SERVER_IP}\n"
                fi
                ;;
            9)
                echo -ne "请输入 IPv6 地址: "
                read new_ipv6
                if [[ -n "$new_ipv6" ]]; then
                    SERVER_IPV6="$new_ipv6"
                    save_ip_config
                    _green "\nIPv6 地址已更新: ${SERVER_IPV6}\n"
                fi
                ;;
            0)
                break
                ;;
            *)
                msg "$is_err 无效选项"
                ;;
        esac
    done
}
