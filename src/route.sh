#!/bin/bash

# 域名分流配置管理

# 分流规则配置文件
is_domain_route_file=$is_core_dir/domain_routes.conf

# 分流规则数组: 入站标签|匹配类型|匹配值|中转标签|描述
DOMAIN_ROUTES=()

# 保存分流规则到文件
save_domain_routes_to_file() {
    mkdir -p "$(dirname "${is_domain_route_file}")"

    cat > "${is_domain_route_file}" << EOF
# Sing-box 分流规则配置文件
# 格式: INBOUND_TAG|MATCH_TYPE|MATCH_VALUE|RELAY_TAG|DESCRIPTION
# MATCH_TYPE: domain_suffix(域名后缀), domain(完整域名), domain_keyword(关键词), ip_cidr(IP/CIDR)
EOF

    for route in "${DOMAIN_ROUTES[@]}"; do
        echo "$route" >> "${is_domain_route_file}"
    done
}

# 从文件加载分流规则（内部初始化用）
load_domain_routes_from_file_init() {
    DOMAIN_ROUTES=()

    if [[ ! -f "${is_domain_route_file}" ]]; then
        return 0
    fi

    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        DOMAIN_ROUTES+=("$line")
    done < "${is_domain_route_file}"
}

# 从文件加载分流规则（外部调用）
load_domain_routes() {
    load_domain_routes_from_file_init
}

# ==================== 域名分流配置菜单 ====================

domain_route_menu() {
    load_domain_routes_from_file_init
    load relay.sh
    load_relays_from_file

    while true; do
        echo
        msg "------------- 域名分流配置菜单 -------------"
        echo

        msg "${yellow}当前分流规则 (共 ${#DOMAIN_ROUTES[@]} 条):${none}"
        if [[ ${#DOMAIN_ROUTES[@]} -eq 0 ]]; then
            echo "  (暂无分流规则)"
        else
            local global_idx=1
            for route in "${DOMAIN_ROUTES[@]}"; do
                IFS='|' read -r inbound_tag match_type match_value relay_tag desc <<< "$route"
                local relay_node_desc="$relay_tag"
                for j in "${!RELAY_TAGS[@]}"; do
                    if [[ "${RELAY_TAGS[$j]}" == "$relay_tag" ]]; then
                        relay_node_desc="${RELAY_DESCS[$j]}"
                        break
                    fi
                done

                local match_display=""
                case "$match_type" in
                    domain_suffix) match_display="域名后缀" ;;
                    domain) match_display="完整域名" ;;
                    domain_keyword) match_display="关键词" ;;
                    ip_cidr) match_display="IP/CIDR" ;;
                    *) match_display="$match_type" ;;
                esac

                echo -e "  ${green}[${global_idx}]${none} ${inbound_tag} | ${match_display}: ${match_value} -> ${relay_node_desc}"
                ((global_idx++))
            done
        fi
        echo

        echo -e "  ${green}[1]${none} 添加分流规则"
        echo -e "  ${green}[2]${none} 删除单个分流规则"
        echo -e "  ${green}[3]${none} 清空所有分流规则"
        echo -e "  ${green}[0]${none} 返回"
        echo
        echo -ne "请选择 [0-3]: "
        read dr_choice

        case $dr_choice in
            1)
                add_domain_route
                ;;
            2)
                delete_domain_route
                ;;
            3)
                echo
                echo -ne "确认清空所有分流规则？(y/N): "
                read confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    DOMAIN_ROUTES=()
                    save_domain_routes_to_file
                    _green "\n已清空所有分流规则\n"
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

# 添加分流规则
add_domain_route() {
    if [[ ! -f $is_config_json ]]; then
        warn "配置文件不存在"
        return
    fi

    # 获取入站节点列表
    local inbound_tags=()
    local inbound_ports=()
    local inbound_protos=()

    local inbounds_count=$(jq '.inbounds | length' $is_config_json 2>/dev/null || echo "0")
    if [[ "$inbounds_count" -eq 0 ]]; then
        warn "没有找到入站节点"
        return
    fi

    for ((i=0; i<inbounds_count; i++)); do
        local tag=$(jq -r ".inbounds[${i}].tag" $is_config_json 2>/dev/null)
        local port=$(jq -r ".inbounds[${i}].listen_port" $is_config_json 2>/dev/null)
        local type=$(jq -r ".inbounds[${i}].type" $is_config_json 2>/dev/null)
        [[ -z "$tag" || "$tag" == "null" ]] && continue
        inbound_tags+=("$tag")
        inbound_ports+=("$port")
        inbound_protos+=("$type")
    done

    if [[ ${#inbound_tags[@]} -eq 0 ]]; then
        warn "没有可用的入站节点"
        return
    fi

    if [[ ${#RELAY_TAGS[@]} -eq 0 ]]; then
        warn "没有可用的中转节点，请先添加中转"
        return
    fi

    echo
    msg "${cyan}选择要配置分流的入站节点:${none}"
    local idx=1
    for i in "${!inbound_tags[@]}"; do
        echo -e "  ${green}[${idx}]${none} ${inbound_protos[$i]}:${inbound_ports[$i]} (${inbound_tags[$i]})"
        ((idx++))
    done
    echo
    echo -ne "请选择 [1-$((idx-1))]: "
    read inbound_idx

    if ! [[ "$inbound_idx" =~ ^[0-9]+$ ]] || [[ "$inbound_idx" -lt 1 ]] || [[ "$inbound_idx" -ge "$idx" ]]; then
        msg "$is_err 无效选项"
        return
    fi
    ((inbound_idx--))
    local selected_inbound="${inbound_tags[$inbound_idx]}"

    echo
    msg "${cyan}选择匹配类型:${none}"
    echo -e "  ${green}[1]${none} domain_suffix - 域名后缀匹配 (推荐)"
    echo -e "  ${green}[2]${none} domain - 完整域名匹配"
    echo -e "  ${green}[3]${none} domain_keyword - 关键词匹配"
    echo -e "  ${green}[4]${none} ip_cidr - IP/CIDR 匹配"
    echo
    echo -ne "请选择 [1-4]: "
    read type_idx

    local match_type=""
    case $type_idx in
        1) match_type="domain_suffix" ;;
        2) match_type="domain" ;;
        3) match_type="domain_keyword" ;;
        4) match_type="ip_cidr" ;;
        *) msg "$is_err 无效选项"; return ;;
    esac

    echo
    msg "${cyan}输入要分流的域名或IP (支持多个，用英文逗号分隔):${none}"
    echo -ne "请输入: "
    read match_input

    match_input=$(echo "$match_input" | sed 's/，/,/g' | tr -d ' ')
    [[ -z "$match_input" ]] && { msg "$is_err 输入不能为空"; return; }

    echo
    msg "${cyan}选择要使用的中转节点:${none}"
    idx=1
    for i in "${!RELAY_TAGS[@]}"; do
        echo -e "  ${green}[${idx}]${none} ${RELAY_DESCS[$i]}"
        ((idx++))
    done
    echo
    echo -ne "请选择 [1-$((idx-1))]: "
    read relay_idx

    if ! [[ "$relay_idx" =~ ^[0-9]+$ ]] || [[ "$relay_idx" -lt 1 ]] || [[ "$relay_idx" -ge "$idx" ]]; then
        msg "$is_err 无效选项"
        return
    fi
    ((relay_idx--))
    local selected_relay="${RELAY_TAGS[$relay_idx]}"
    local selected_relay_desc="${RELAY_DESCS[$relay_idx]}"

    echo
    echo -ne "请输入描述 (可选): "
    read desc
    [[ -z "$desc" ]] && desc="分流规则"

    # 批量添加分流规则
    if [[ "$match_input" == *,* ]]; then
        IFS=',' read -ra MATCH_VALUES <<< "$match_input"
        local added_count=0
        for match_value in "${MATCH_VALUES[@]}"; do
            match_value=$(echo "$match_value" | xargs)
            if [[ -n "$match_value" ]]; then
                local route_str="${selected_inbound}|${match_type}|${match_value}|${selected_relay}|${desc}"
                DOMAIN_ROUTES+=("$route_str")
                ((added_count++))
            fi
        done
        [[ $added_count -gt 0 ]] && save_domain_routes_to_file && _green "\n已添加 ${added_count} 条分流规则\n"
    else
        local route_str="${selected_inbound}|${match_type}|${match_input}|${selected_relay}|${desc}"
        DOMAIN_ROUTES+=("$route_str")
        save_domain_routes_to_file
        _green "\n分流规则已添加: ${match_input} -> ${selected_relay_desc}\n"
    fi

    # 应用分流规则到 config.json
    apply_domain_routes
}

# 删除分流规则
delete_domain_route() {
    if [[ ${#DOMAIN_ROUTES[@]} -eq 0 ]]; then
        warn "没有可删除的分流规则"
        return
    fi

    echo
    msg "${cyan}选择要删除的分流规则:${none}"
    echo
    for i in "${!DOMAIN_ROUTES[@]}"; do
        idx=$((i+1))
        IFS='|' read -r inbound_tag match_type match_value relay_tag desc <<< "${DOMAIN_ROUTES[$i]}"
        local relay_node_desc="$relay_tag"
        for j in "${!RELAY_TAGS[@]}"; do
            if [[ "${RELAY_TAGS[$j]}" == "$relay_tag" ]]; then
                relay_node_desc="${RELAY_DESCS[$j]}"
                break
            fi
        done
        echo -e "  ${green}[${idx}]${none} ${inbound_tag} | ${match_type}: ${match_value} -> ${relay_node_desc}"
    done
    echo
    echo -ne "请选择要删除的规则编号: "
    read delete_idx

    if ! [[ "$delete_idx" =~ ^[0-9]+$ ]] || [[ "$delete_idx" -lt 1 ]] || [[ "$delete_idx" -gt ${#DOMAIN_ROUTES[@]} ]]; then
        msg "$is_err 无效选项"
        return
    fi

    local d=$((delete_idx-1))
    local del_route="${DOMAIN_ROUTES[$d]}"
    IFS='|' read -r del_inbound del_type del_value del_relay del_desc <<< "$del_route"

    local new_routes=()
    for i in "${!DOMAIN_ROUTES[@]}"; do
        [[ "$i" -ne "$d" ]] && new_routes+=("${DOMAIN_ROUTES[$i]}")
    done
    DOMAIN_ROUTES=("${new_routes[@]}")
    save_domain_routes_to_file
    _green "\n已删除分流规则: ${del_type}:${del_value}\n"

    apply_domain_routes
}

# 应用分流规则到 config.json
apply_domain_routes() {
    if [[ ! -f $is_config_json ]]; then
        return
    fi

    load_relays_from_file

    local tmp_config=$(mktemp)

    # 先移除所有分流域名规则（包含 domain/domain_suffix/domain_keyword/ip_cidr 且有 inbound 的规则）
    jq '.route.rules = [.route.rules[] | select(
        (.domain // .domain_suffix // .domain_keyword // .domain_regex // .ip_cidr // .ip // null) == null
    )]' $is_config_json > "$tmp_config"

    # 添加分流规则
    for route in "${DOMAIN_ROUTES[@]}"; do
        IFS='|' read -r inbound_tag match_type match_value relay_tag desc <<< "$route"
        [[ -z "$inbound_tag" || -z "$match_type" || -z "$match_value" || -z "$relay_tag" ]] && continue

        # 检查中转是否存在
        local relay_exists=0
        for rt in "${RELAY_TAGS[@]}"; do
            [[ "$rt" == "$relay_tag" ]] && relay_exists=1 && break
        done
        [[ $relay_exists -eq 0 ]] && continue

        local rule_part=""
        case "$match_type" in
            domain_suffix) rule_part="\"domain_suffix\":[\"${match_value}\"]" ;;
            domain) rule_part="\"domain\":[\"${match_value}\"]" ;;
            domain_keyword) rule_part="\"domain_keyword\":[\"${match_value}\"]" ;;
            ip_cidr) rule_part="\"ip_cidr\":[\"${match_value}\"]" ;;
            *) continue ;;
        esac

        local tmp_config2=$(mktemp)
        jq --arg ib "$inbound_tag" --arg ob "$relay_tag" --argjson rule "{\"inbound\":[\"$inbound_tag\"],${rule_part},\"outbound\":\"$relay_tag\"}" '
            .route.rules = [$rule] + .route.rules
        ' "$tmp_config" > "$tmp_config2"
        mv "$tmp_config2" "$tmp_config"

        # 确保中转 outbound 存在
        local relay_json=""
        for i in "${!RELAY_TAGS[@]}"; do
            if [[ "${RELAY_TAGS[$i]}" == "$relay_tag" ]]; then
                relay_json="${RELAY_JSONS[$i]}"
                break
            fi
        done
        if [[ -n "$relay_json" ]]; then
            local exists=$(jq --arg tag "$relay_tag" '.outbounds[] | select(.tag == $tag)' "$tmp_config")
            if [[ -z "$exists" ]]; then
                local tmp_config3=$(mktemp)
                jq --argjson rj "$relay_json" '.outbounds += [$rj]' "$tmp_config" > "$tmp_config3"
                mv "$tmp_config3" "$tmp_config"
            fi
        fi
    done

    mv "$tmp_config" $is_config_json
    manage restart &
    msg "\n$(_green "分流规则已应用并重启服务")\n"
}
