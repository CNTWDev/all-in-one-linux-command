#!/bin/bash
# Linux 服务器运维菜单。单独复制本文件即可运行通用菜单。
# 可将可信的 Bash 扩展放在同目录的 ops.d/ 或本机扩展目录下。

BOLD='' CYAN='' DIM='' GREEN='' AMBER='' RED='' RESET=''
interactive=false
color=false
if [[ -t 0 && -t 1 && -n "$TERM" && "$TERM" != dumb ]]; then
    interactive=true
    if [[ -z "${NO_COLOR:-}" ]]; then
        color=true
        BOLD=$'\033[1m'
        CYAN=$'\033[96m'
        DIM=$'\033[90m'
        GREEN=$'\033[92m'
        AMBER=$'\033[93m'
        RED=$'\033[91m'
        RESET=$'\033[0m'
    fi
fi
host=$(hostname -s 2>/dev/null) || host='local'
terminal_width=0

menu_items=()

# register_menu_item <菜单> <分组或空串> <编号> <名称> <函数> [说明]
# 主菜单使用 main。扩展可用自己的菜单名登记子项，再用 open_menu 打开。
register_menu_item() {
    local menu="$1" group="$2" number="$3" name="$4" handler="$5" detail="${6:-}"
    local item registered_menu registered_group registered_number unused
    if [[ ! "$number" =~ ^[1-9][0-9]*$ ]] || ! declare -F "$handler" >/dev/null; then
        printf '菜单项无效 %s / %s / %s\n' "$menu" "$number" "$handler" >&2
        return 1
    fi
    for item in "${menu_items[@]}"; do
        IFS='|' read -r registered_menu registered_group registered_number unused <<< "$item"
        if [[ "$registered_menu" == "$menu" && "$registered_number" == "$number" ]]; then
            printf '菜单编号重复 %s / %s\n' "$menu" "$number" >&2
            return 1
        fi
    done
    menu_items+=("$menu|$group|$number|$name|$handler|$detail")
}

menu_rows() {
    local item menu group number name handler detail previous_group=''
    for item in "${menu_items[@]}"; do
        IFS='|' read -r menu group number name handler detail <<< "$item"
        [[ "$menu" == "$1" ]] || continue
        if [[ -n "$group" && "$group" != "$previous_group" ]]; then
            printf '%s\n' "$group"
        fi
        printf '%s|%s|%s\n' "$number" "$name" "$detail"
        previous_group=$group
    done
}

dispatch_menu() {
    local item menu group number name handler detail
    for item in "${menu_items[@]}"; do
        IFS='|' read -r menu group number name handler detail <<< "$item"
        if [[ "$menu" == "$1" && "$number" == "$2" ]]; then
            "$handler"
            return 0
        fi
    done
    return 1
}

# ---------- 终端界面 ----------
rule() {
    local width=72 line
    if ((terminal_width > 2 && terminal_width < 74)); then
        width=$((terminal_width - 2))
    fi
    printf -v line '%*s' "$width" ''
    printf '  %s%s%s\n' "$DIM" "${line// /-}" "$RESET"
}

screen() {
    if $interactive; then
        tput clear 2>/dev/null || true
    fi
    printf '\n  %s%sOPS / CONSOLE%s  %s%s%s\n' "$BOLD" "$CYAN" "$RESET" "$DIM" "$host" "$RESET"
    printf '  %s%s%s\n' "$BOLD" "$1" "$RESET"
    rule
}

row() {
    local number name detail
    IFS='|' read -r number name detail <<< "$1"
    if [[ -z "$name" ]]; then
        printf '  %s%s%s%s' "$BOLD" "$CYAN" "$number" "$RESET"
    else
        printf '  %s[%2s]%s  %s' "$CYAN" "$number" "$RESET" "$name"
        if [[ -n "$detail" ]]; then
            printf '  %s%s%s' "$DIM" "$detail" "$RESET"
        fi
    fi
}

rows() {
    local item
    for item in "$@"; do
        row "$item"
        printf '\n'
    done
}

prompt() {
    printf '  %s%s%s ' "$CYAN" "$1" "$RESET"
}

status() {
    printf '  %s%s%s%s  %s\n' "$BOLD" "$1" "$2" "$RESET" "$3"
}

pause() {
    printf '\n'
    prompt '回车返回 >'
    IFS= read -r
}

show_main() {
    local i size cols right_column='' item in_first_group=true
    local left_rows=() right_rows=()
    if $interactive; then
        size=$(stty size 2>/dev/null)
        cols=${size##* }
        if [[ "$cols" =~ ^[0-9]+$ ]]; then
            terminal_width=$cols
            if $color && ((terminal_width >= 80)); then
                right_column=$(tput hpa 43 2>/dev/null) || right_column=''
            fi
        fi
    fi

    while IFS= read -r item; do
        if [[ "$item" != *'|'* && ${#left_rows[@]} -gt 0 ]]; then
            in_first_group=false
        fi
        if $in_first_group; then
            left_rows+=("$item")
        else
            right_rows+=("$item")
        fi
    done < <(menu_rows main)

    screen '服务器运维'
    if [[ -n "$right_column" && ${#right_rows[@]} -gt 0 ]]; then
        for ((i = 0; i < ${#left_rows[@]} || i < ${#right_rows[@]}; i++)); do
            [[ -z "${left_rows[i]}" ]] || row "${left_rows[i]}"
            if [[ -n "${right_rows[i]}" ]]; then
                printf '%s' "$right_column"
                row "${right_rows[i]}"
            fi
            printf '\n'
        done
    else
        rows "${left_rows[@]}"
        if ((${#right_rows[@]} > 0)); then
            printf '\n'
            rows "${right_rows[@]}"
        fi
    fi

    printf '\n'
    rows '0|退出'
    rule
}

open_menu() {
    local menu="$1" title="$2" back_label="$3" input_prompt="${4:-ops >}"
    local item choice
    while true; do
        screen "$title"
        while IFS= read -r item; do
            rows "$item"
        done < <(menu_rows "$menu")
        printf '\n'
        rows "0|$back_label"
        rule
        prompt "$input_prompt"
        IFS= read -r choice || return 0
        [[ "$choice" != 0 ]] || return 0
        if ! dispatch_menu "$menu" "$choice"; then
            status "$AMBER" 'INPUT' '请选择菜单中显示的编号'
            pause || return 0
        fi
    done
}

# ---------- 命令执行 ----------
run_task() {
    local command="$1" code line
    shift
    screen '执行记录'
    while IFS= read -r line; do
        printf '  %s$%s %s\n' "$CYAN" "$RESET" "$line"
    done <<< "$command"
    printf '\n'
    "$@"
    code=$?
    printf '\n'
    rule
    if ((code == 0)); then
        status "$GREEN" 'OK' '执行完成 · exit 0'
    else
        status "$RED" 'FAIL' "命令退出 · exit $code"
    fi
    pause
}

format_command() {
    local LC_ALL=C
    printf -v "$@"
}

run_cmd() {
    local command
    format_command command '%q ' "$@"
    run_task "${command% }" "$@"
}

run_shell() {
    run_task "$1" bash -o pipefail -c "$1"
}

# 每条诊断命令都执行，执行页显示最后一个非零退出码。
# 参数是 Shell 命令。动态参数由调用者用 format_command 和 %q 转义。
run_checks() {
    local command display='' script='code=0'
    for command; do
        display+="${display:+$'\n'}$command"
        script+=$'\n'"{ $command; } || code=\$?"
    done
    run_task "$display" bash -o pipefail -c "$script"$'\n''exit "$code"'
}

usage_table() {
    awk -v mode="$1" -v column="$2" -v label="$3" -v graphical="$interactive" \
        -v cyan="$CYAN" -v green="$GREEN" -v amber="$AMBER" -v red="$RED" \
        -v dim="$DIM" -v reset="$RESET" '
        function bar(value, maximum, shade, filled, i) {
            filled = maximum > 0 ? int(10 * value / maximum + 0.5) : 0
            printf "%s", shade
            for (i = 0; i < filled && i < 10; i++) printf "█"
            printf "%s%s", reset, dim
            for (; i < 10; i++) printf "░"
            printf "%s  ", reset
        }
        mode == "process" && NR > 11 { next }
        graphical != "true" { print; next }
        NR == 1 { printf "%-10s  %s\n", label, $0; next }
        mode == "process" {
            if (NR == 2) highest = $column + 0
            bar($column + 0, highest, cyan)
        }
        mode == "disk" {
            if ($column ~ /^[0-9]+%$/) {
                percent = $column + 0
                shade = percent >= 90 ? red : (percent >= 75 ? amber : green)
                bar(percent > 100 ? 100 : percent, 100, shade)
            } else {
                printf "%-10s  ", "-"
            }
        }
        { print }
    '
}

usage_report() (
    set -o pipefail
    local mode="$1" code=0 first_column=3 second_column=4
    local first_label='CPU / TOP' second_label='MEM / TOP'
    if [[ "$mode" == disk ]]; then
        first_column=6
        second_column=5
        first_label='SPACE'
        second_label='INODES'
    fi
    bash -o pipefail -c "$2" | usage_table "$mode" "$first_column" "$first_label" || code=$?
    printf '\n'
    bash -o pipefail -c "$3" | usage_table "$mode" "$second_column" "$second_label" || code=$?
    return "$code"
)

run_usage_report() {
    local mode="$1" first="$2" second="$3"
    run_task "$first"$'\n'"$second" usage_report "$mode" "$first" "$second"
}

# ---------- Linux 排障 ----------
linux_menu() {
    open_menu linux 'Linux 排障' '返回主菜单' 'linux >'
}

linux_overview() {
    run_checks 'uptime' 'free -h' 'vmstat 1 5'
}

linux_processes() {
    local fields='pid,user,pcpu,pmem,stat,comm'
    run_usage_report process "ps -eo $fields --sort=-pcpu" "ps -eo $fields --sort=-pmem"
}

linux_disk_menu() {
    open_menu linux-disk 'Linux 排障 / 磁盘与目录' '返回 Linux 排障' 'linux >'
}

linux_disk_usage() {
    run_usage_report disk 'df -hT' 'df -ih'
}

linux_directory_usage() {
    local directory
    prompt '目录路径（例如 /var，直接回车取消） >'
    IFS= read -r directory || return
    [[ -n "$directory" ]] || return
    run_cmd du -xhd1 -- "$directory"
}

linux_block_devices() {
    run_cmd lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
}

linux_deleted_files() {
    run_cmd lsof -nP +L1
}

linux_disk_io() {
    run_cmd iostat -x -y -z 1 3
}

linux_network_menu() {
    open_menu linux-network 'Linux 排障 / 网络与监听' '返回 Linux 排障' 'linux >'
}

linux_network() {
    run_checks 'ip -br addr' 'ip route' 'ss -lntup'
}

linux_tcp() {
    local target port
    prompt '目标域名或 IP（直接回车取消） >'
    IFS= read -r target || return
    [[ -n "$target" ]] || return
    prompt 'TCP 端口（直接回车取消） >'
    IFS= read -r port || return
    [[ -n "$port" ]] || return
    if [[ ! "$target" =~ ^[[:alnum:]_.:%-]+$ || "$target" == -* ||
          ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || ((port > 65535)); then
        status "$AMBER" 'INPUT' '请输入有效域名或 IP，以及 1–65535 的端口'
        pause
        return
    fi
    run_cmd nc -vz -w 5 "$target" "$port"
}

linux_dns_http_menu() {
    open_menu linux-dns-http 'Linux 排障 / DNS / HTTP 检测' '返回 Linux 排障' 'linux >'
}

linux_dns() {
    local target
    prompt '域名（直接回车取消） >'
    IFS= read -r target || return
    [[ -n "$target" ]] || return
    run_cmd getent -- ahosts "$target"
}

linux_http() {
    local url output_format
    prompt 'HTTP(S) URL（直接回车取消） >'
    IFS= read -r url || return
    [[ -n "$url" ]] || return
    output_format='HTTP 状态码 %{http_code}  对端 IP %{remote_ip}\n'
    output_format+='DNS %{time_namelookup} 秒  首字节 %{time_starttransfer} 秒  总耗时 %{time_total} 秒\n'
    output_format+='重定向地址 %{redirect_url}\n'
    run_cmd curl -q --globoff --silent --show-error --output /dev/null \
        --proto '=http,https' --connect-timeout 5 --max-time 15 \
        --write-out "$output_format" -- "$url"
}

linux_service_menu() {
    open_menu linux-services 'Linux 排障 / 服务与日志' '返回 Linux 排障' 'linux >'
}

linux_failed_services() {
    run_cmd systemctl --no-pager --failed
}

linux_service_details() {
    local unit status_command log_command
    prompt 'systemd 服务名（直接回车取消） >'
    IFS= read -r unit || return
    [[ -n "$unit" ]] || return
    if command -v journalctl >/dev/null 2>&1; then
        format_command status_command 'systemctl --no-pager status -- %q' "$unit"
        format_command log_command 'journalctl --no-pager -n 100 -u %q' "$unit"
        run_checks "$status_command" "$log_command"
    else
        run_cmd systemctl --no-pager status -- "$unit"
    fi
}

linux_docker_menu() {
    open_menu linux-docker 'Linux 排障 / Docker 排障' '返回 Linux 排障' 'linux >'
}

linux_docker_ps() {
    run_cmd docker ps -a
}

linux_docker_stats() {
    run_cmd docker stats --no-stream
}

linux_docker_logs() {
    local container
    prompt '容器名或 ID（直接回车取消） >'
    IFS= read -r container || return
    [[ -n "$container" ]] || return
    run_cmd docker logs --tail 100 -- "$container"
}

linux_docker_disk() {
    run_cmd docker system df
}

linux_docker_state() {
    local container output_format
    prompt '容器名或 ID（直接回车取消） >'
    IFS= read -r container || return
    [[ -n "$container" ]] || return
    output_format='{{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}'
    output_format+=' restarts={{.RestartCount}}{{with .State.Health}} health={{.Status}}{{end}}'
    run_cmd docker inspect --type container --format "$output_format" -- "$container"
}

linux_boot_menu() {
    open_menu linux-boot 'Linux 排障 / 内核与启动日志' '返回 Linux 排障' 'linux >'
}

linux_boot_history() {
    run_cmd journalctl --no-pager --list-boots
}

linux_current_boot_errors() {
    run_checks 'journalctl --no-pager -b -p err -n 100' 'journalctl --no-pager -k -b -p warning -n 100'
}

linux_previous_boot_errors() {
    run_cmd journalctl --no-pager -b -1 -p err -n 100
}

linux_oom_events() {
    run_shell "journalctl --no-pager -k -b all --since '24 hours ago' | awk 'tolower(\$0) ~ /out of memory|oom[-_ ]kill|killed process/' | tail -n 50"
}

linux_time_status() {
    run_cmd timedatectl --no-pager status
}

# ---------- 系统 / 基础工具 ----------
install_bt_panel() {
    run_shell 'wget -O install_panel.sh https://download.bt.cn/install/install_panel.sh && sudo bash install_panel.sh ed8484bec'
}

update_system_packages() {
    run_cmd sudo apt-get update
}

install_compose_plugin() {
    run_cmd sudo apt-get install -y docker-compose-plugin
}

update_npm() {
    run_cmd npm install -g npm@12.0.1
}

register_builtin_menus() {
    local system_group='系统 / 基础工具'
    register_menu_item main "$system_group" 31 '安装宝塔面板' install_bt_panel
    register_menu_item main "$system_group" 32 '更新系统包索引' update_system_packages 'apt-get update'
    register_menu_item main "$system_group" 33 '安装 docker-compose-plugin' install_compose_plugin
    register_menu_item main "$system_group" 34 '升级全局 npm' update_npm '12.0.1'
    register_menu_item main "$system_group" 40 'Linux 排障' linux_menu

    register_menu_item linux '' 1 '机器概览' linux_overview '看负载、内存和 I/O 等待'
    register_menu_item linux '' 2 '进程排行' linux_processes '找出 CPU 和内存占用最高的进程'
    register_menu_item linux '' 3 '磁盘与目录' linux_disk_menu '查空间、inode 和大目录'
    register_menu_item linux '' 4 '网络与监听' linux_network_menu '查本机端口与 TCP 连通性'
    register_menu_item linux-disk '' 1 '文件系统空间与 inode' linux_disk_usage
    register_menu_item linux-disk '' 2 '扫描指定目录' linux_directory_usage
    if command -v lsblk >/dev/null 2>&1; then
        register_menu_item linux-disk '' 3 '块设备与挂载点' linux_block_devices
    fi
    if command -v lsof >/dev/null 2>&1; then
        register_menu_item linux-disk '' 4 '已删除但仍被进程占用的文件' linux_deleted_files
    fi
    if command -v iostat >/dev/null 2>&1; then
        register_menu_item linux-disk '' 5 '磁盘 I/O 延迟与吞吐' linux_disk_io
    fi
    register_menu_item linux-network '' 1 '本机 IP、路由与监听端口' linux_network
    if command -v nc >/dev/null 2>&1; then
        register_menu_item linux-network '' 2 '测试指定 TCP 端口' linux_tcp
    fi

    if command -v getent >/dev/null 2>&1; then
        register_menu_item linux-dns-http '' 1 'DNS 解析' linux_dns
    fi
    if command -v curl >/dev/null 2>&1; then
        register_menu_item linux-dns-http '' 2 'HTTP 状态码与耗时' linux_http
    fi
    if command -v getent >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
        register_menu_item linux '' 5 'DNS / HTTP 检测' linux_dns_http_menu '查域名解析和 HTTP 响应'
    fi

    if command -v systemctl >/dev/null 2>&1; then
        register_menu_item linux '' 6 '服务与日志' linux_service_menu '查失败服务、状态和日志'
        register_menu_item linux-services '' 1 '列出失败服务' linux_failed_services
        if command -v journalctl >/dev/null 2>&1; then
            register_menu_item linux-services '' 2 '查看服务状态与最近 100 行日志' linux_service_details
        else
            register_menu_item linux-services '' 2 '查看服务状态' linux_service_details
        fi
    fi

    if command -v docker >/dev/null 2>&1; then
        register_menu_item linux '' 7 'Docker 排障' linux_docker_menu '查容器、资源、日志和磁盘用量'
        register_menu_item linux-docker '' 1 '列出所有容器' linux_docker_ps
        register_menu_item linux-docker '' 2 '查看容器资源占用' linux_docker_stats
        register_menu_item linux-docker '' 3 '查看容器最近 100 行日志' linux_docker_logs
        register_menu_item linux-docker '' 4 '查看 Docker 磁盘用量' linux_docker_disk
        register_menu_item linux-docker '' 5 '容器退出码、OOM 与健康状态' linux_docker_state
    fi
    if command -v journalctl >/dev/null 2>&1; then
        register_menu_item linux '' 8 '内核与启动日志' linux_boot_menu '查重启、内核告警和 OOM'
        register_menu_item linux-boot '' 1 '查看启动历史' linux_boot_history
        register_menu_item linux-boot '' 2 '本次启动的错误与内核告警' linux_current_boot_errors
        register_menu_item linux-boot '' 3 '上次启动的错误' linux_previous_boot_errors
        register_menu_item linux-boot '' 4 '最近 24 小时的内核 OOM 记录' linux_oom_events
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        register_menu_item linux '' 9 '时间与同步' linux_time_status '检查时区和 NTP 状态'
    fi
}

load_extensions() {
    local extension
    for extension in "$1"/*.sh; do
        [[ -f "$extension" ]] || continue
        if ! source "$extension"; then
            printf '加载菜单扩展失败 %s\n' "$extension" >&2
            return 1
        fi
    done
    return 0
}

main() {
    local script_dir choice extension_dir
    script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1
    extension_dir=${OPS_EXTENSION_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/all-in-one-linux-command/ops.d}
    if [[ "${OPS_LOAD_PROJECTS:-1}" != 0 ]]; then
        load_extensions "$script_dir/ops.d" || return 1
    fi
    register_builtin_menus
    load_extensions "$extension_dir" || return 1

    while true; do
        show_main
        prompt 'ops >'
        IFS= read -r choice || break
        if [[ "$choice" == 0 ]]; then
            printf '\n  已退出运维控制台。\n'
            break
        fi
        if ! dispatch_menu main "$choice"; then
            status "$AMBER" 'INPUT' '请选择菜单中显示的编号'
            pause || break
        fi
    done
}

main "$@"
