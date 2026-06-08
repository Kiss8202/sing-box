#!/bin/bash

# 中转配置管理

# 中转配置文件
is_relay_file=$is_core_dir/relays.conf

# 中转配置数组
RELAY_TAGS=()
RELAY_JSONS=()
RELAY_DESCS=()

# 保存中转配置到文件
save_relays_to_file() {
    mkdir -p "$(dirname "${is_relay_file}")"

    cat > "${is_relay_file}" << EOF
# Sing-box 中转配置文件
# 格式: TAG|DESCRIPTION|JSON_CONFIG
EOF

    for i in "${!RELAY_TAGS[@]}"; do
        local tag="${RELAY_TAGS[$i]}"
        local desc="${RELAY_DESCS[$i]}"
        local json="${RELAY_JSONS[$i]}"
        local json_base64=$(echo "$json" | base64 -w0)
        echo "${tag}|${desc}|${json_base64}" >> "${is_relay_file}"
    done
}

# 从文件加载中转配置
load_relays_from_file() {
    RELAY_TAGS=()
    RELAY_JSONS=()
    RELAY_DESCS=()

    if [[ ! -f "${is_relay_file}" ]]; then
        return 0
    fi

    while IFS='|' read -r tag desc json_base64; do
        [[ "$tag" =~ ^#.*$ || -z "$tag" ]] && continue

        local json=$(echo "$json_base64" | base64 -d 2>/dev/null)
        if [[ -n "$json" ]]; then
            RELAY_TAGS+=("$tag")
            RELAY_DESCS+=("$desc")
            RELAY_JSONS+=("$json")
        fi
    done < "${is_relay_file}"
}

# ==================== 中转链接解析 ====================

parse_socks_link() {
    local link="$1"
    local custom_desc="$2"

    if [[ "$link" =~ ^socks://([A-Za-z0-9+/=]+) ]]; then
        local base64_part="${BASH_REMATCH[1]}"
        local decoded=$(echo "$base64_part" | base64 -d 2>/dev/null)
        [[ -z "$decoded" ]] && { msg "$is_err base64 解码失败"; return 1; }
        link="socks5://${decoded}"
    fi

    local data=$(echo "$link" | sed 's|socks5\?://||')
    data=$(echo "$data" | cut -d'?' -f1 | cut -d'#' -f1)

    local relay_json=""
    local relay_desc=""

    if [[ "$data" =~ @ ]]; then
        local userpass=$(echo "$data" | cut -d'@' -f1)
        local username=$(echo "$userpass" | cut -d':' -f1)
        local password=$(echo "$userpass" | cut -d':' -f2-)
        local server_port=$(echo "$data" | cut -d'@' -f2)
        local server=$(echo "$server_port" | cut -d':' -f1)
        local port=$(echo "$server_port" | cut -d':' -f2)

        [[ ! "$port" =~ ^[0-9]+$ ]] && { msg "$is_err 端口无效: ${port}"; return 1; }

        local tag="relay-socks5-${#RELAY_TAGS[@]}"
        relay_json="{
  \"type\": \"socks\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"version\": \"5\",
  \"username\": \"${username}\",
  \"password\": \"${password}\"
}"
        [[ -n "$custom_desc" ]] && relay_desc="$custom_desc" || relay_desc="SOCKS5 ${server}:${port} (认证)"
    else
        local server=$(echo "$data" | cut -d':' -f1)
        local port=$(echo "$data" | cut -d':' -f2)

        [[ ! "$port" =~ ^[0-9]+$ ]] && { msg "$is_err 端口无效: ${port}"; return 1; }

        local tag="relay-socks5-${#RELAY_TAGS[@]}"
        relay_json="{
  \"type\": \"socks\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"version\": \"5\"
}"
        [[ -n "$custom_desc" ]] && relay_desc="$custom_desc" || relay_desc="SOCKS5 ${server}:${port}"
    fi

    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")

    save_relays_to_file
    msg "\n$(_green "已添加 SOCKS5 中转: ${relay_desc}")\n"
}

parse_http_link() {
    local link="$1"
    local custom_desc="$2"
    local protocol=$(echo "$link" | cut -d':' -f1)
    local data=$(echo "$link" | sed 's|https\?://||')

    local tls="false"
    [[ "$protocol" == "https" ]] && tls="true"

    local relay_json=""
    local relay_desc=""
    local tag="relay-http-${#RELAY_TAGS[@]}"

    if [[ "$data" =~ @ ]]; then
        local userpass=$(echo "$data" | cut -d'@' -f1)
        local username=$(echo "$userpass" | cut -d':' -f1)
        local password=$(echo "$userpass" | cut -d':' -f2)
        local server_port=$(echo "$data" | cut -d'@' -f2)
        local server=$(echo "$server_port" | cut -d':' -f1)
        local port=$(echo "$server_port" | cut -d':' -f2 | cut -d'/' -f1 | cut -d'#' -f1 | cut -d'?' -f1)

        relay_json="{
  \"type\": \"http\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"username\": \"${username}\",
  \"password\": \"${password}\",
  \"tls\": {\"enabled\": ${tls}}
}"
        [[ -n "$custom_desc" ]] && relay_desc="$custom_desc" || relay_desc="${protocol^^} ${server}:${port} (认证)"
    else
        local server=$(echo "$data" | cut -d':' -f1)
        local port=$(echo "$data" | cut -d':' -f2 | cut -d'/' -f1 | cut -d'#' -f1 | cut -d'?' -f1)

        relay_json="{
  \"type\": \"http\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"tls\": {\"enabled\": ${tls}}
}"
        [[ -n "$custom_desc" ]] && relay_desc="$custom_desc" || relay_desc="${protocol^^} ${server}:${port}"
    fi

    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")

    save_relays_to_file
    msg "\n$(_green "已添加 HTTP(S) 中转: ${relay_desc}")\n"
}

parse_ss_link() {
    local link="$1"
    local custom_desc="$2"
    local data=$(echo "$link" | sed 's|ss://||' | cut -d'#' -f1)

    if [[ "$data" =~ @ ]]; then
        local userinfo=$(echo "$data" | cut -d'@' -f1)
        local server_port=$(echo "$data" | cut -d'@' -f2 | cut -d'?' -f1)
        local server=$(echo "$server_port" | cut -d':' -f1)
        local port=$(echo "$server_port" | cut -d':' -f2)

        local decoded=$(echo "$userinfo" | base64 -d 2>/dev/null)
        [[ -z "$decoded" ]] && { msg "$is_err Shadowsocks 链接解码失败"; return 1; }

        local method=$(echo "$decoded" | cut -d':' -f1)
        local password=$(echo "$decoded" | cut -d':' -f2-)

        local tag="relay-ss-${#RELAY_TAGS[@]}"
        local relay_json="{
  \"type\": \"shadowsocks\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"method\": \"${method}\",
  \"password\": \"${password}\"
}"
        local relay_desc
        [[ -n "$custom_desc" ]] && relay_desc="$custom_desc" || relay_desc="Shadowsocks ${server}:${port}"

        RELAY_TAGS+=("$tag")
        RELAY_JSONS+=("$relay_json")
        RELAY_DESCS+=("$relay_desc")

        save_relays_to_file
        msg "\n$(_green "已添加 Shadowsocks 中转: ${relay_desc}")\n"
    else
        msg "$is_err Shadowsocks 链接格式错误"
        return 1
    fi
}

parse_vmess_link() {
    local link="$1"
    local custom_desc="$2"
    local base64_data=$(echo "$link" | sed 's|vmess://||')
    local json=$(echo "$base64_data" | base64 -d 2>/dev/null)

    [[ -z "$json" ]] && { msg "$is_err VMess 链接解码失败"; return 1; }
    [[ ! $(type -P jq) ]] && { msg "$is_err 需要 jq 工具来解析 VMess 链接"; return 1; }

    local server=$(echo "$json" | jq -r '.add // .address')
    local port=$(echo "$json" | jq -r '.port')
    local uuid=$(echo "$json" | jq -r '.id')
    local alterId=$(echo "$json" | jq -r '.aid // 0')
    local security=$(echo "$json" | jq -r '.scy // "auto"')

    local tag="relay-vmess-${#RELAY_TAGS[@]}"
    local relay_json="{
  \"type\": \"vmess\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"uuid\": \"${uuid}\",
  \"alter_id\": ${alterId},
  \"security\": \"${security}\"
}"
    local relay_desc
    [[ -n "$custom_desc" ]] && relay_desc="$custom_desc" || relay_desc="VMess ${server}:${port}"

    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")

    save_relays_to_file
    msg "\n$(_green "已添加 VMess 中转: ${relay_desc}")\n"
}

parse_vless_link() {
    local link="$1"
    local custom_desc="$2"
    local data=$(echo "$link" | sed 's|vless://||')
    local uuid=$(echo "$data" | cut -d'@' -f1)
    local server_port_params=$(echo "$data" | cut -d'@' -f2)
    local server=$(echo "$server_port_params" | cut -d':' -f1)
    local port_params=$(echo "$server_port_params" | cut -d':' -f2)
    local port=$(echo "$port_params" | cut -d'?' -f1 | sed 's|/.*||')

    [[ ! "$port" =~ ^[0-9]+$ ]] && { msg "$is_err 端口无效: ${port}"; return 1; }

    local params=$(echo "$server_port_params" | grep -o '?.*' | sed 's|?||' | cut -d'#' -f1)

    local security="none" sni="" flow="" pbk="" sid="" encryption="none"

    if [[ -n "$params" ]]; then
        IFS='&' read -ra param_pairs <<< "$params"
        for pair in "${param_pairs[@]}"; do
            key="${pair%%=*}"
            value="${pair#*=}"
            case "$key" in
                security) security="$value" ;;
                sni) sni="$value" ;;
                flow) flow="$value" ;;
                pbk) pbk="$value" ;;
                sid) sid="$value" ;;
                encryption) encryption="$value" ;;
            esac
        done
    fi

    local tls_config="" reality_config=""
    if [[ "$security" == "tls" ]]; then
        tls_config=",
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"${sni}\",
    \"utls\": {\"enabled\": true, \"fingerprint\": \"chrome\"}
  }"
    elif [[ "$security" == "reality" ]]; then
        [[ -z "$pbk" ]] && { msg "$is_err REALITY 链接缺少公钥 (pbk)"; return 1; }
        reality_config=",
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"${sni}\",
    \"utls\": {\"enabled\": true, \"fingerprint\": \"chrome\"},
    \"reality\": {
      \"enabled\": true,
      \"public_key\": \"${pbk}\",
      \"short_id\": \"${sid}\"
    }
  }"
    fi

    local flow_config=""
    [[ -n "$flow" ]] && flow_config=",
  \"flow\": \"${flow}\""

    local encryption_config=""
    [[ "$encryption" != "none" ]] && encryption_config=",
  \"encryption\": \"${encryption}\""

    local tag="relay-vless-${#RELAY_TAGS[@]}"
    local relay_json="{
  \"type\": \"vless\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"uuid\": \"${uuid}\"${encryption_config}${flow_config}${tls_config}${reality_config}
}"

    local relay_desc
    if [[ -n "$custom_desc" ]]; then
        relay_desc="$custom_desc"
    else
        if [[ "$security" == "reality" ]]; then
            relay_desc="VLESS+REALITY ${server}:${port} (SNI: ${sni})"
        else
            relay_desc="VLESS ${server}:${port}"
        fi
    fi

    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")

    save_relays_to_file
    msg "\n$(_green "已添加 VLESS 中转: ${relay_desc}")\n"
}

parse_trojan_link() {
    local link="$1"
    local custom_desc="$2"
    local data=$(echo "$link" | sed 's|trojan://||')
    local password=$(echo "$data" | cut -d'@' -f1)
    local server_port_params=$(echo "$data" | cut -d'@' -f2)
    local server=$(echo "$server_port_params" | cut -d':' -f1)
    local port_params=$(echo "$server_port_params" | cut -d':' -f2)
    local port=$(echo "$port_params" | cut -d'?' -f1)

    local params=$(echo "$port_params" | grep -o '?.*' | sed 's|?||' | cut -d'#' -f1)

    local sni=""
    [[ "$params" =~ sni=([^&]+) ]] && sni="${BASH_REMATCH[1]}"

    local tag="relay-trojan-${#RELAY_TAGS[@]}"
    local relay_json="{
  \"type\": \"trojan\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"password\": \"${password}\",
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"${sni}\"
  }
}"
    local relay_desc
    [[ -n "$custom_desc" ]] && relay_desc="$custom_desc" || relay_desc="Trojan ${server}:${port}"

    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")

    save_relays_to_file
    msg "\n$(_green "已添加 Trojan 中转: ${relay_desc}")\n"
}

parse_hysteria2_link() {
    local link="$1"
    local custom_desc="$2"

    local data="${link#*://}"
    local userinfo="${data%%@*}"
    local rest="${data#*@}"
    local server="${rest%%:*}"
    local port_and_params="${rest#*:}"
    local port="${port_and_params%%[?/]*}"

    [[ ! "$port" =~ ^[0-9]+$ ]] && { msg "$is_err 端口无效: ${port}"; return 1; }

    local params=""
    if [[ "$port_and_params" == *"?"* ]]; then
        params="${port_and_params#*?}"
        params="${params%%#*}"
    fi

    local password="$userinfo" sni="" insecure="false" obfs_type="" obfs_password=""

    if [[ -n "$params" ]]; then
        IFS='&' read -ra param_pairs <<< "$params"
        for pair in "${param_pairs[@]}"; do
            key="${pair%%=*}"
            value="${pair#*=}"
            case "$key" in
                sni) sni="$value" ;;
                insecure) insecure="$value" ;;
                obfs) obfs_type="$value" ;;
                obfs-password) obfs_password="$value" ;;
            esac
        done
    fi

    local insecure_bool="false"
    [[ "$insecure" == "1" || "$insecure" == "true" ]] && insecure_bool="true"

    local tls_config="{
    \"enabled\": true,
    \"server_name\": \"${sni}\",
    \"insecure\": ${insecure_bool}
  }"
    local obfs_config=""
    if [[ "$obfs_type" == "salamander" && -n "$obfs_password" ]]; then
        obfs_config=",
  \"obfs\": {
    \"type\": \"salamander\",
    \"password\": \"${obfs_password}\"
  }"
    fi

    local tag="relay-hysteria2-${#RELAY_TAGS[@]}"
    local relay_json="{
  \"type\": \"hysteria2\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"password\": \"${password}\",
  \"tls\": ${tls_config}${obfs_config}
}"

    local relay_desc
    [[ -n "$custom_desc" ]] && relay_desc="$custom_desc" || relay_desc="Hysteria2 ${server}:${port} (SNI: ${sni})"

    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")

    save_relays_to_file
    msg "\n$(_green "已添加 Hysteria2 中转: ${relay_desc}")\n"
}

parse_anytls_link() {
    local link="$1"
    local custom_desc="$2"
    local data=$(echo "$link" | sed 's|anytls://||')
    local userinfo=$(echo "$data" | cut -d'@' -f1)
    local server_port_params=$(echo "$data" | cut -d'@' -f2)
    local server=$(echo "$server_port_params" | cut -d':' -f1)
    local port_params=$(echo "$server_port_params" | cut -d':' -f2)
    local port=$(echo "$port_params" | cut -d'?' -f1 | sed 's|/.*||')

    [[ ! "$port" =~ ^[0-9]+$ ]] && { msg "$is_err 端口无效: ${port}"; return 1; }

    local params=$(echo "$server_port_params" | grep -o '?.*' | sed 's|?||' | cut -d'#' -f1)
    local password="$userinfo" sni="" insecure="false"

    if [[ -n "$params" ]]; then
        IFS='&' read -ra param_pairs <<< "$params"
        for pair in "${param_pairs[@]}"; do
            key="${pair%%=*}"
            value="${pair#*=}"
            case "$key" in
                sni) sni="$value" ;;
                insecure) insecure="$value" ;;
            esac
        done
    fi

    local insecure_bool="false"
    [[ "$insecure" == "1" || "$insecure" == "true" ]] && insecure_bool="true"

    local tag="relay-anytls-${#RELAY_TAGS[@]}"
    local relay_json="{
  \"type\": \"anytls\",
  \"tag\": \"${tag}\",
  \"server\": \"${server}\",
  \"server_port\": ${port},
  \"password\": \"${password}\",
  \"tls\": {
    \"enabled\": true,
    \"server_name\": \"${sni}\",
    \"insecure\": ${insecure_bool}
  }
}"

    local relay_desc
    [[ -n "$custom_desc" ]] && relay_desc="$custom_desc" || relay_desc="AnyTLS ${server}:${port} (SNI: ${sni})"

    RELAY_TAGS+=("$tag")
    RELAY_JSONS+=("$relay_json")
    RELAY_DESCS+=("$relay_desc")

    save_relays_to_file
    msg "\n$(_green "已添加 AnyTLS 中转: ${relay_desc}")\n"
}

# ==================== 中转菜单 ====================

setup_relay() {
    load_relays_from_file
    load route.sh
    load_domain_routes_from_file_init

    while true; do
        echo
        msg "------------- 中转配置菜单 -------------"
        echo

        if [[ ${#RELAY_TAGS[@]} -gt 0 ]]; then
            msg "${yellow}当前中转列表:${none}"
            for i in "${!RELAY_TAGS[@]}"; do
                idx=$((i+1))
                echo -e "  ${green}[${idx}]${none} ${RELAY_DESCS[$i]}"
            done
            echo
        else
            msg "${yellow}当前没有配置中转${none}"
            echo
        fi

        echo -e "  ${green}[1]${none} 添加新的中转链接"
        echo -e "  ${green}[2]${none} 为节点配置中转"
        echo -e "  ${green}[3]${none} 删除中转链接"
        echo -e "  ${green}[4]${none} 域名分流配置"
        echo -e "  ${green}[5]${none} 修改中转链接"
        echo -e "  ${green}[0]${none} 返回主菜单"
        echo
        echo -ne "请选择 [0-5]: "
        read r_choice

        case $r_choice in
            1)
                echo
                msg "${cyan}支持的中转协议格式:${none}"
                echo
                echo -e "  ${green}1.${none} SOCKS5: socks5://[用户名:密码@]服务器:端口"
                echo -e "  ${green}2.${none} HTTP(S): http(s)://[用户名:密码@]服务器:端口"
                echo -e "  ${green}3.${none} Shadowsocks: ss://base64(加密方式:密码)@服务器:端口"
                echo -e "  ${green}4.${none} VMess: vmess://base64(JSON配置)"
                echo -e "  ${green}5.${none} VLESS: vless://UUID@服务器:端口?参数#备注"
                echo -e "  ${green}6.${none} Trojan: trojan://密码@服务器:端口?参数#备注"
                echo -e "  ${green}7.${none} Hysteria2: hysteria2://密码@服务器:端口?参数"
                echo -e "  ${green}8.${none} AnyTLS: anytls://密码@服务器:端口?参数"
                echo
                echo -ne "粘贴中转链接: "
                read RELAY_LINK

                if [[ -z "$RELAY_LINK" ]]; then
                    warn "未提供链接，中转配置保持不变"
                else
                    echo
                    echo -ne "请输入描述信息 (留空自动生成): "
                    read custom_desc

                    if [[ "$RELAY_LINK" =~ ^socks ]]; then
                        parse_socks_link "$RELAY_LINK" "$custom_desc"
                    elif [[ "$RELAY_LINK" =~ ^https? ]]; then
                        parse_http_link "$RELAY_LINK" "$custom_desc"
                    elif [[ "$RELAY_LINK" =~ ^ss:// ]]; then
                        parse_ss_link "$RELAY_LINK" "$custom_desc"
                    elif [[ "$RELAY_LINK" =~ ^vmess:// ]]; then
                        parse_vmess_link "$RELAY_LINK" "$custom_desc"
                    elif [[ "$RELAY_LINK" =~ ^vless:// ]]; then
                        parse_vless_link "$RELAY_LINK" "$custom_desc"
                    elif [[ "$RELAY_LINK" =~ ^trojan:// ]]; then
                        parse_trojan_link "$RELAY_LINK" "$custom_desc"
                    elif [[ "$RELAY_LINK" =~ ^(hy2|hysteria2):// ]]; then
                        parse_hysteria2_link "$RELAY_LINK" "$custom_desc"
                    elif [[ "$RELAY_LINK" =~ ^anytls:// ]]; then
                        parse_anytls_link "$RELAY_LINK" "$custom_desc"
                    else
                        msg "$is_err 不支持的链接格式"
                    fi
                fi
                ;;
            2)
                relay_bind_node
                ;;
            3)
                relay_delete
                ;;
            4)
                domain_route_menu
                ;;
            5)
                relay_edit
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

# 为节点配置中转
relay_bind_node() {
    if [[ ! -d $is_conf_dir ]]; then
        warn "配置目录不存在"
        return
    fi

    # 从 conf 目录下的独立 JSON 文件获取所有入站节点
    local inbound_tags=()
    local inbound_ports=()
    local inbound_protos=()
    local inbound_relays=()

    local conf_files=$(ls $is_conf_dir | grep -E -i '\.json$' | sed '/dynamic-port-.*-link/d')
    if [[ -z "$conf_files" ]]; then
        warn "没有找到入站节点"
        return
    fi

    while IFS= read -r conf_file; do
        [[ -z "$conf_file" ]] && continue
        local tag=$(jq -r '.inbounds[0].tag' $is_conf_dir/"$conf_file" 2>/dev/null)
        local port=$(jq -r '.inbounds[0].listen_port' $is_conf_dir/"$conf_file" 2>/dev/null)
        local type=$(jq -r '.inbounds[0].type' $is_conf_dir/"$conf_file" 2>/dev/null)
        [[ -z "$tag" || "$tag" == "null" ]] && continue
        inbound_tags+=("$tag")
        inbound_ports+=("$port")
        inbound_protos+=("$type")
        inbound_relays+=("direct")
    done <<< "$conf_files"

    # 从路由规则中恢复中转配置
    local route_rules=$(jq -c '.route.rules[]? // empty' $is_config_json 2>/dev/null)
    if [[ -n "$route_rules" ]]; then
        while IFS= read -r rule; do
            local has_inbound=$(echo "$rule" | jq -e '.inbound // empty' 2>/dev/null)
            [[ -z "$has_inbound" ]] && continue
            local has_domain=$(echo "$rule" | jq -e '.domain // .domain_suffix // .domain_keyword // .domain_regex // empty' 2>/dev/null)
            local has_ip=$(echo "$rule" | jq -e '.ip_cidr // .ip // empty' 2>/dev/null)
            [[ -n "$has_domain" || -n "$has_ip" ]] && continue
            local inbound_array=$(echo "$rule" | jq -r '.inbound[]? // empty' 2>/dev/null)
            local outbound=$(echo "$rule" | jq -r '.outbound // ""' 2>/dev/null)
            if [[ -n "$outbound" && "$outbound" != "direct" ]]; then
                while IFS= read -r ib_tag; do
                    for idx in "${!inbound_tags[@]}"; do
                        if [[ "${inbound_tags[$idx]}" == "$ib_tag" ]]; then
                            inbound_relays[$idx]="$outbound"
                        fi
                    done
                done <<< "$inbound_array"
            fi
        done <<< "$route_rules"
    fi

    if [[ ${#inbound_tags[@]} -eq 0 ]]; then
        warn "当前没有入站节点"
        return
    fi

    if [[ ${#RELAY_TAGS[@]} -eq 0 ]]; then
        warn "尚未添加任何中转链接，请先添加中转"
        return
    fi

    echo
    msg "${cyan}选择要配置中转的节点:${none}"
    for i in "${!inbound_tags[@]}"; do
        idx=$((i+1))
        local relay_status="${inbound_relays[$i]}"
        local relay_desc="直连"
        if [[ "$relay_status" != "direct" ]]; then
            for j in "${!RELAY_TAGS[@]}"; do
                if [[ "${RELAY_TAGS[$j]}" == "$relay_status" ]]; then
                    relay_desc="中转: ${RELAY_DESCS[$j]}"
                    break
                fi
            done
        fi
        echo -e "  ${green}[${idx}]${none} ${inbound_protos[$i]}:${inbound_ports[$i]} → ${yellow}${relay_desc}${none}"
    done
    echo
    echo -ne "请输入节点序号 (输入 0 返回): "
    read node_idx

    [[ "$node_idx" == "0" ]] && return

    if ! [[ "$node_idx" =~ ^[0-9]+$ ]] || (( node_idx < 1 || node_idx > ${#inbound_tags[@]} )); then
        msg "$is_err 无效的节点序号"
        return
    fi

    local n=$((node_idx-1))
    local selected_tag="${inbound_tags[$n]}"

    echo
    msg "${cyan}选择中转方式:${none}"
    echo -e "  ${green}[0]${none} 直连 (不使用中转)"
    for i in "${!RELAY_TAGS[@]}"; do
        idx=$((i+1))
        echo -e "  ${green}[${idx}]${none} ${RELAY_DESCS[$i]}"
    done
    echo
    echo -ne "请选择: "
    read relay_idx

    local new_outbound="direct"
    if [[ "$relay_idx" == "0" ]]; then
        new_outbound="direct"
        _green "\n节点已设置为直连\n"
    elif [[ "$relay_idx" =~ ^[0-9]+$ ]] && (( relay_idx >= 1 && relay_idx <= ${#RELAY_TAGS[@]} )); then
        local r=$((relay_idx-1))
        new_outbound="${RELAY_TAGS[$r]}"
        _green "\n节点已设置为: ${RELAY_DESCS[$r]}\n"
    else
        msg "$is_err 无效选择"
        return
    fi

    # 更新 config.json 中的路由规则
    update_relay_route "$selected_tag" "$new_outbound"
}

# 更新路由规则中的中转配置
update_relay_route() {
    local inbound_tag="$1"
    local outbound_tag="$2"

    if [[ ! -f $is_config_json ]]; then
        warn "配置文件不存在"
        return
    fi

    local tmp_config=$(mktemp)

    if [[ "$outbound_tag" == "direct" ]]; then
        # 删除该入站的非分流路由规则
        jq --arg ib "$inbound_tag" '
            .route.rules = [.route.rules[] | select(
                (.inbound // []) | index($ib) | not
                or (.domain // .domain_suffix // .domain_keyword // .domain_regex // .ip_cidr // .ip // null) != null
            )]
        ' $is_config_json > "$tmp_config"
    else
        # 先删除该入站的旧默认路由规则
        local tmp_config2=$(mktemp)
        jq --arg ib "$inbound_tag" '
            .route.rules = [.route.rules[] | select(
                (.inbound // []) | index($ib) | not
                or (.domain // .domain_suffix // .domain_keyword // .domain_regex // .ip_cidr // .ip // null) != null
            )]
        ' $is_config_json > "$tmp_config2"

        # 添加新的路由规则
        jq --arg ib "$inbound_tag" --arg ob "$outbound_tag" '
            .route.rules += [{"inbound": [$ib], "outbound": $ob}]
        ' "$tmp_config2" > "$tmp_config"
        rm -f "$tmp_config2"
    fi

    # 确保中转 outbound 存在于 outbounds 中
    if [[ "$outbound_tag" != "direct" ]]; then
        local relay_json=""
        for i in "${!RELAY_TAGS[@]}"; do
            if [[ "${RELAY_TAGS[$i]}" == "$outbound_tag" ]]; then
                relay_json="${RELAY_JSONS[$i]}"
                break
            fi
        done

        if [[ -n "$relay_json" ]]; then
            local tmp_config3=$(mktemp)
            # 检查 outbound 是否已存在
            local exists=$(jq --arg tag "$outbound_tag" '.outbounds[] | select(.tag == $tag)' "$tmp_config")
            if [[ -z "$exists" ]]; then
                jq --argjson rj "$relay_json" '.outbounds += [$rj]' "$tmp_config" > "$tmp_config3"
                mv "$tmp_config3" "$tmp_config"
            else
                rm -f "$tmp_config3"
            fi
        fi
    fi

    mv "$tmp_config" $is_config_json
    manage restart &
    msg "\n$(_green "中转配置已更新并重启服务")\n"
}

# 删除中转链接
relay_delete() {
    if [[ ${#RELAY_TAGS[@]} -eq 0 ]]; then
        warn "当前没有中转链接"
        return
    fi

    echo
    msg "${cyan}删除中转链接:${none}"
    echo -e "  ${green}[0]${none} 删除全部中转"
    for i in "${!RELAY_TAGS[@]}"; do
        idx=$((i+1))
        echo -e "  ${green}[${idx}]${none} ${RELAY_DESCS[$i]}"
    done
    echo
    echo -ne "请选择要删除的中转 (输入 0 删除全部, 输入 -1 取消): "
    read del_idx

    [[ "$del_idx" == "-1" ]] && return

    if [[ "$del_idx" == "0" ]]; then
        echo
        echo -ne "确认删除全部中转? (y/N): "
        read confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            RELAY_TAGS=()
            RELAY_JSONS=()
            RELAY_DESCS=()
            rm -f "${is_relay_file}"
            _green "\n已删除全部中转配置\n"
        fi
    elif [[ "$del_idx" =~ ^[0-9]+$ ]] && (( del_idx >= 1 && del_idx <= ${#RELAY_TAGS[@]} )); then
        local d=$((del_idx-1))
        local del_tag="${RELAY_TAGS[$d]}"
        local del_desc="${RELAY_DESCS[$d]}"

        echo
        echo -ne "确认删除中转: ${del_desc}? (y/N): "
        read confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            unset RELAY_TAGS[$d]
            unset RELAY_JSONS[$d]
            unset RELAY_DESCS[$d]
            RELAY_TAGS=("${RELAY_TAGS[@]}")
            RELAY_JSONS=("${RELAY_JSONS[@]}")
            RELAY_DESCS=("${RELAY_DESCS[@]}")
            save_relays_to_file
            _green "\n已删除中转: ${del_desc}\n"
        fi
    else
        msg "$is_err 无效选择"
    fi
}

# 修改中转链接
relay_edit() {
    if [[ ${#RELAY_TAGS[@]} -eq 0 ]]; then
        warn "当前没有中转链接"
        return
    fi

    echo
    msg "${cyan}修改中转链接:${none}"
    for i in "${!RELAY_TAGS[@]}"; do
        idx=$((i+1))
        echo -e "  ${green}[${idx}]${none} ${RELAY_DESCS[$i]}"
    done
    echo
    echo -ne "请选择要修改的中转 (输入 -1 取消): "
    read edit_idx

    [[ "$edit_idx" == "-1" ]] && return

    if ! [[ "$edit_idx" =~ ^[0-9]+$ ]] || (( edit_idx < 1 || edit_idx > ${#RELAY_TAGS[@]} )); then
        msg "$is_err 无效选择"
        return
    fi

    local e=$((edit_idx-1))
    local old_tag="${RELAY_TAGS[$e]}"
    local old_desc="${RELAY_DESCS[$e]}"

    echo
    msg "${yellow}当前中转: ${old_desc}${none}"
    msg "${cyan}请输入新的中转链接:${none}"
    echo
    echo -ne "粘贴新的中转链接: "
    read NEW_RELAY_LINK

    [[ -z "$NEW_RELAY_LINK" ]] && { warn "未提供链接，修改取消"; return; }

    echo
    echo -ne "请输入新的描述信息 (留空自动生成): "
    read new_custom_desc

    # 临时保存当前数组状态
    local saved_tags=("${RELAY_TAGS[@]}")
    local saved_jsons=("${RELAY_JSONS[@]}")
    local saved_descs=("${RELAY_DESCS[@]}")
    local tmp_tags=("${RELAY_TAGS[@]}")
    local tmp_jsons=("${RELAY_JSONS[@]}")
    local tmp_descs=("${RELAY_DESCS[@]}")
    RELAY_TAGS=()
    RELAY_JSONS=()
    RELAY_DESCS=()

    local parse_ok=0
    if [[ "$NEW_RELAY_LINK" =~ ^socks ]]; then
        parse_socks_link "$NEW_RELAY_LINK" "$new_custom_desc" && parse_ok=1
    elif [[ "$NEW_RELAY_LINK" =~ ^https? ]]; then
        parse_http_link "$NEW_RELAY_LINK" "$new_custom_desc" && parse_ok=1
    elif [[ "$NEW_RELAY_LINK" =~ ^ss:// ]]; then
        parse_ss_link "$NEW_RELAY_LINK" "$new_custom_desc" && parse_ok=1
    elif [[ "$NEW_RELAY_LINK" =~ ^vmess:// ]]; then
        parse_vmess_link "$NEW_RELAY_LINK" "$new_custom_desc" && parse_ok=1
    elif [[ "$NEW_RELAY_LINK" =~ ^vless:// ]]; then
        parse_vless_link "$NEW_RELAY_LINK" "$new_custom_desc" && parse_ok=1
    elif [[ "$NEW_RELAY_LINK" =~ ^trojan:// ]]; then
        parse_trojan_link "$NEW_RELAY_LINK" "$new_custom_desc" && parse_ok=1
    elif [[ "$NEW_RELAY_LINK" =~ ^(hy2|hysteria2):// ]]; then
        parse_hysteria2_link "$NEW_RELAY_LINK" "$new_custom_desc" && parse_ok=1
    elif [[ "$NEW_RELAY_LINK" =~ ^anytls:// ]]; then
        parse_anytls_link "$NEW_RELAY_LINK" "$new_custom_desc" && parse_ok=1
    else
        msg "$is_err 不支持的链接格式"
    fi

    if [[ $parse_ok -eq 1 ]]; then
        local new_json="${RELAY_JSONS[0]}"
        local new_desc="${RELAY_DESCS[0]}"
        local new_tag="${RELAY_TAGS[0]}"
        new_json=$(echo "$new_json" | sed "s/\"${new_tag}\"/\"${old_tag}\"/g")

        RELAY_TAGS=("${tmp_tags[@]}")
        RELAY_JSONS=("${tmp_jsons[@]}")
        RELAY_DESCS=("${tmp_descs[@]}")

        RELAY_JSONS[$e]="$new_json"
        RELAY_DESCS[$e]="$new_desc"

        save_relays_to_file
        _green "\n中转已修改: ${old_desc} → ${new_desc}\n"
    else
        RELAY_TAGS=("${saved_tags[@]}")
        RELAY_JSONS=("${saved_jsons[@]}")
        RELAY_DESCS=("${saved_descs[@]}")
        msg "$is_err 新链接解析失败，中转配置未修改"
    fi
}

# 将中转和分流规则应用到 config.json
# 在 create config.json 时调用
apply_relay_and_routes_to_config() {
    if [[ ! -f $is_config_json ]]; then
        return
    fi

    # 如果没有中转和分流规则，直接返回
    if [[ ${#RELAY_TAGS[@]} -eq 0 && ${#DOMAIN_ROUTES[@]} -eq 0 ]]; then
        return
    fi

    local tmp_config=$(mktemp)

    # 添加中转 outbound 到 config.json
    for i in "${!RELAY_TAGS[@]}"; do
        local relay_json="${RELAY_JSONS[$i]}"
        local relay_tag="${RELAY_TAGS[$i]}"

        if [[ -n "$relay_json" ]]; then
            local exists=$(jq --arg tag "$relay_tag" '.outbounds[] | select(.tag == $tag)' $is_config_json 2>/dev/null)
            if [[ -z "$exists" ]]; then
                local tmp_config2=$(mktemp)
                jq --argjson rj "$relay_json" '.outbounds += [$rj]' $is_config_json > "$tmp_config2"
                mv "$tmp_config2" "$tmp_config"
            else
                cp $is_config_json "$tmp_config"
            fi
        fi
    done

    # 添加分流路由规则
    for route in "${DOMAIN_ROUTES[@]}"; do
        IFS='|' read -r inbound_tag match_type match_value relay_tag desc <<< "$route"
        [[ -z "$inbound_tag" || -z "$match_type" || -z "$match_value" || -z "$relay_tag" ]] && continue

        # 检查中转是否存在
        local relay_exists=0
        for rt in "${RELAY_TAGS[@]}"; do
            [[ "$rt" == "$relay_tag" ]] && relay_exists=1 && break
        done
        [[ $relay_exists -eq 0 ]] && continue

        local match_key=""
        case "$match_type" in
            domain_suffix) match_key="domain_suffix" ;;
            domain) match_key="domain" ;;
            domain_keyword) match_key="domain_keyword" ;;
            ip_cidr) match_key="ip_cidr" ;;
            *) continue ;;
        esac

        local tmp_config2=$(mktemp)
        jq --arg ib "$inbound_tag" --arg ob "$relay_tag" --arg mk "$match_key" --arg mv "$match_value" '
            .route.rules = [{"inbound": [$ib], ($mk): [$mv], "outbound": $ob}] + .route.rules
        ' "$tmp_config" > "$tmp_config2"
        mv "$tmp_config2" "$tmp_config"

        # 确保中转 outbound 存在
        local relay_json=""
        for j in "${!RELAY_TAGS[@]}"; do
            if [[ "${RELAY_TAGS[$j]}" == "$relay_tag" ]]; then
                relay_json="${RELAY_JSONS[$j]}"
                break
            fi
        done
        if [[ -n "$relay_json" ]]; then
            local exists=$(jq --arg tag "$relay_tag" '.outbounds[] | select(.tag == $tag)' "$tmp_config" 2>/dev/null)
            if [[ -z "$exists" ]]; then
                local tmp_config3=$(mktemp)
                jq --argjson rj "$relay_json" '.outbounds += [$rj]' "$tmp_config" > "$tmp_config3"
                mv "$tmp_config3" "$tmp_config"
            fi
        fi
    done

    mv "$tmp_config" $is_config_json
}
