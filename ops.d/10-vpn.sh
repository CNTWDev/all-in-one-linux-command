# VPN 升级快捷键。可按部署覆盖 VPN_UPDATE。
VPN_UPDATE="${VPN_UPDATE:-/root/one-click-vpn/one-click-update.sh}"

vpn_update() {
    run_cmd sudo "$VPN_UPDATE"
}

vpn_update_all() {
    run_cmd sudo "$VPN_UPDATE" --all
}

vpn_update_console() {
    run_cmd sudo "$VPN_UPDATE" --only console
}

vpn_update_portal() {
    run_cmd sudo "$VPN_UPDATE" --only portal
}

vpn_update_backend() {
    run_cmd sudo "$VPN_UPDATE" --only backend
}

vpn_update_agent() {
    run_cmd sudo "$VPN_UPDATE" --only agent
}

vpn_update_server() {
    run_cmd sudo "$VPN_UPDATE" --no-agent
}

vpn_update_modules() {
    local modules
    prompt '模块组合（逗号分隔，如 backend,console） >'
    IFS= read -r modules || return
    if [[ "$modules" =~ ^(backend|console|portal|agent)(,(backend|console|portal|agent))*$ ]]; then
        run_cmd sudo "$VPN_UPDATE" --only "$modules"
    else
        status "$AMBER" 'INPUT' '可选模块为 backend、console、portal、agent'
        pause
    fi
}

register_menu_item main 'VPN / 升级' 1 '日常升级' vpn_update '智能增量'
register_menu_item main 'VPN / 升级' 2 '全量重建' vpn_update_all '--all'
register_menu_item main 'VPN / 升级' 3 '仅升控制台' vpn_update_console '--only console'
register_menu_item main 'VPN / 升级' 4 '仅升门户' vpn_update_portal '--only portal'
register_menu_item main 'VPN / 升级' 5 '仅升后端' vpn_update_backend '--only backend'
register_menu_item main 'VPN / 升级' 6 '仅升节点 Agent' vpn_update_agent '--only agent'
register_menu_item main 'VPN / 升级' 7 '自定义模块' vpn_update_modules '--only …'
register_menu_item main 'VPN / 升级' 8 '仅升服务器' vpn_update_server '--no-agent'
