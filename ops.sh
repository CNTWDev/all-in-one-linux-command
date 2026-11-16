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
screen_width=72
screen_indent='  '
admin_prefix=()
if ((EUID != 0)) && command -v sudo >/dev/null 2>&1; then
    admin_prefix=(sudo)
fi

menu_items=()
movable_menu_items=()

find_menu_item() {
    local position registered_menu registered_group registered_number unused
    for position in "${!menu_items[@]}"; do
        IFS='|' read -r registered_menu registered_group registered_number unused <<< "${menu_items[position]}"
        if [[ "$registered_menu" == "$1" && "$registered_number" == "$2" ]]; then
            printf -v "$3" '%s' "$position"
            return 0
        fi
    done
    return 1
}

move_main_tool() {
    local item_index="$1" fallback=70 in_use current_menu group old_number rest
    while find_menu_item main "$fallback" in_use; do
        ((fallback += 1))
    done
    IFS='|' read -r current_menu group old_number rest <<< "${menu_items[item_index]}"
    menu_items[item_index]="$current_menu|$group|$fallback|$rest"
}

# register_menu_item <菜单> <分组或空串> <编号> <名称> <函数> [说明] [函数参数]
# 主菜单使用 main。扩展可用自己的菜单名登记子项，再用 open_menu 打开。
register_menu_item() {
    local menu="$1" group="$2" number="$3" name="$4" handler="$5" detail="${6:-}" argument="${7:-}"
    local existing_index
    if [[ ! "$number" =~ ^[1-9][0-9]*$ ]] || ! declare -F "$handler" >/dev/null; then
        printf '菜单项无效 %s / %s / %s\n' "$menu" "$number" "$handler" >&2
        return 1
    fi
    if find_menu_item "$menu" "$number" existing_index; then
        if [[ "${movable_menu_items[existing_index]:-}" == true ]]; then
            move_main_tool "$existing_index"
        else
            printf '菜单编号重复 %s / %s\n' "$menu" "$number" >&2
            return 1
        fi
    fi
    menu_items+=("$menu|$group|$number|$name|$handler|$argument|$detail")
}

register_main_tool() {
    local new_index=${#menu_items[@]}
    register_menu_item main "$@" || return 1
    movable_menu_items[new_index]=true
}

menu_rows() {
    local item menu group number name handler argument detail previous_group=''
    for item in "${menu_items[@]}"; do
        IFS='|' read -r menu group number name handler argument detail <<< "$item"
        [[ "$menu" == "$1" ]] || continue
        if [[ -n "$group" && "$group" != "$previous_group" ]]; then
            printf '%s\n' "$group"
        fi
        printf '%s|%s|%s\n' "$number" "$name" "$detail"
        previous_group=$group
    done
}

dispatch_menu() {
    local index menu group number name handler argument detail
    find_menu_item "$1" "$2" index || return 1
    IFS='|' read -r menu group number name handler argument detail <<< "${menu_items[index]}"
    if [[ -n "$argument" ]]; then
        "$handler" "$argument"
    else
        "$handler"
    fi
    return 0
}

# ---------- 终端界面 ----------
refresh_layout() {
    local size columns
    size=$(stty size 2>/dev/null) || return 0
    columns=${size##* }
    if [[ "$columns" =~ ^[0-9]+$ ]] && ((columns > 12)); then
        screen_width=$((columns - 4))
        ((screen_width < 111)) || screen_width=111
        if ((screen_width >= 76 && screen_width % 2 == 0)); then
            ((screen_width -= 1))
        fi
        printf -v screen_indent '%*s' "$(((columns - screen_width) / 2))" ''
    fi
}

rule() {
    local line
    printf -v line '%*s' "$screen_width" ''
    printf '%s%s%s%s\n' "$screen_indent" "$DIM" "${line// /-}" "$RESET"
}

screen() {
    local host_gap=2
    if $interactive; then
        refresh_layout
        tput clear 2>/dev/null || true
        if ((screen_width > ${#host} + 15)); then
            host_gap=$((screen_width - ${#host} - 13))
        fi
    fi
    printf '\n%s%s%sOPS / CONSOLE%s%*s%s%s%s\n' \
        "$screen_indent" "$BOLD" "$CYAN" "$RESET" "$host_gap" '' "$DIM" "$host" "$RESET"
    printf '%s%s%s%s\n' "$screen_indent" "$BOLD" "$1" "$RESET"
    [[ "${2:-}" == menu ]] || rule
}

row() {
    local number name detail limit="${2:-0}"
    IFS='|' read -r number name detail <<< "$1"
    if [[ -z "$name" ]]; then
        printf '  %s%s%s%s' "$BOLD" "$CYAN" "$number" "$RESET"
    else
        printf '  %s[%2s]%s  %s' "$CYAN" "$number" "$RESET" "$name"
        if [[ -n "$detail" ]] && { ((limit == 0)) || fits_cell "$number$name$detail" "$((limit - 10))"; }; then
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

fits_cell() {
    local LC_ALL=C text="$1" characters wide
    # 去掉 UTF-8 续字节，按 ASCII 一格、非 ASCII 最多两格预留宽度。
    characters=${text//[$'\200'-$'\277']/}
    wide=${characters//[!$'\300'-$'\377']/}
    (("${#characters}" + "${#wide}" <= $2))
}

grid_row() {
    local left="$1" right="$2" divider="$3" edge="$4" capacity="$5"
    printf '%s%s|%s' "$screen_indent" "$DIM" "$RESET"
    [[ -z "$left" ]] || row "$left" "$capacity"
    if [[ -n "$divider" ]]; then
        printf '%s%s|%s' "$divider" "$DIM" "$RESET"
        [[ -z "$right" ]] || row "$right" "$capacity"
    fi
    printf '%s%s|%s\n' "$edge" "$DIM" "$RESET"
}

menu_grid() {
    local edge="$1" divider="$2" capacity="$3" item pending=''
    local line section_started=false
    shift 3
    printf -v line '%*s' "$((screen_width - 2))" ''
    line="$screen_indent$DIM+${line// /-}+$RESET"
    printf '%s\n' "$line"
    for item; do
        if [[ "$item" != *'|'* ]]; then
            if [[ -n "$pending" ]]; then
                grid_row "$pending" '' "$divider" "$edge" "$capacity"
                pending=''
            fi
            if $section_started; then
                printf '%s\n' "$line"
            fi
            printf '%s%s|%s  %s%s%s%s%s|%s\n' \
                "$screen_indent" "$DIM" "$RESET" "$BOLD" "$item" "$RESET" "$edge" "$DIM" "$RESET"
        elif [[ -z "$divider" ]]; then
            grid_row "$item" '' '' "$edge" "$capacity"
        elif [[ -z "$pending" ]]; then
            pending=$item
        else
            grid_row "$pending" "$item" "$divider" "$edge" "$capacity"
            pending=''
        fi
        section_started=true
    done
    if [[ -n "$pending" ]]; then
        grid_row "$pending" '' "$divider" "$edge" "$capacity"
    fi
    printf '%s\n' "$line"
}

render_menu() {
    local entries=() item number name detail edge divider='' capacity
    local half_width=$(((screen_width - 3) / 2)) margin=${#screen_indent}
    while IFS= read -r item; do
        entries+=("$item")
    done < <(menu_rows "$1")

    if ! $interactive || ((screen_width < 36)) ||
        ! edge=$(tput hpa "$((margin + screen_width - 1))" 2>/dev/null) || [[ -z "$edge" ]]; then
        rule
        rows "${entries[@]}"
        return
    fi

    if ((screen_width >= 75)); then
        divider=$(tput hpa "$((margin + half_width + 1))" 2>/dev/null) || divider=''
    fi
    for item in "${entries[@]}"; do
        IFS='|' read -r number name detail <<< "$item"
        if [[ -z "$name" ]]; then
            if ! fits_cell "$number" "$((screen_width - 5))"; then
                rule
                rows "${entries[@]}"
                return
            fi
            continue
        fi
        if ! fits_cell "$number$name" "$((screen_width - 9))"; then
            rule
            rows "${entries[@]}"
            return
        fi
        if ! fits_cell "$number$name" "$((half_width - 7))"; then
            divider=''
        fi
    done
    capacity=$((screen_width - 2))
    [[ -z "$divider" ]] || capacity=$half_width
    menu_grid "$edge" "$divider" "$capacity" "${entries[@]}"
}

prompt() {
    printf '%s%s%s%s ' "$screen_indent" "$CYAN" "$1" "$RESET"
}

status() {
    printf '%s%s%s%s%s  %s\n' "$screen_indent" "$BOLD" "$1" "$2" "$RESET" "$3"
}

pause() {
    printf '\n'
    prompt '回车返回 >'
    IFS= read -r
}

show_main() {
    screen '服务器运维' menu
    render_menu main

    printf '\n'
    printf '%s' "$screen_indent"
    rows '0|退出'
    rule
}

open_menu() {
    local menu="$1" title="$2" back_label="$3" input_prompt="${4:-ops >}"
    local choice
    while true; do
        screen "$title" menu
        render_menu "$menu"
        printf '\n'
        printf '%s' "$screen_indent"
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
    execute_task false "$@"
}

execute_task() {
    local change="$1" command="$2" code line answer
    shift 2
    if $change; then
        screen '执行变更'
    else
        screen '执行记录'
    fi
    while IFS= read -r line; do
        printf '%s%s$%s %s\n' "$screen_indent" "$CYAN" "$RESET" "$line"
    done <<< "$command"
    printf '\n'
    if $change; then
        prompt '执行上面的变更？[y/N] >'
        IFS= read -r answer || return 0
        [[ "$answer" == [yY] ]] || return 0
        printf '\n'
    fi
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

run_change() {
    local command
    format_command command '%q ' "$@"
    execute_task true "${command% }" "$@"
}

run_admin() {
    run_cmd "${admin_prefix[@]}" "$@"
}

run_admin_change() {
    run_change "${admin_prefix[@]}" "$@"
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
    if [[ ! "$target" =~ ^[[:alnum:]_.:%-]+$ || "$target" == -* ]] || ! valid_port "$port"; then
        status "$AMBER" 'INPUT' '请输入有效域名或 IP，以及 1–65535 的端口'
        pause
        return
    fi
    run_cmd nc -vz -w 5 "$target" "$port"
}

valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (($1 <= 65535))
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
    open_menu linux-services '服务与日志' "${1:-返回 Linux 排障}"
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
    open_menu linux-docker 'Docker 容器' "${1:-返回 Linux 排障}"
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

# ---------- 通用变更 ----------
read_field() {
    prompt "$2"
    IFS= read -r "$1"
}

input_error() {
    status "$AMBER" INPUT "$1"
    pause
    return 1
}

linux_list_services() {
    run_cmd systemctl --no-pager list-units --type=service --all
}

linux_service_change() {
    local unit
    read_field unit '服务名（例如 nginx.service，回车取消） >' || return
    [[ -n "$unit" ]] || return
    if [[ ! "$unit" =~ ^[[:alnum:]_.@:-]+$ || "$unit" == -* || "$unit" == *.* && "$unit" != *.service ]]; then
        input_error '请输入单个服务名或 .service 单元名'
        return
    fi
    run_admin_change systemctl "$1" -- "$unit"
}

linux_docker_change() {
    local container
    read_field container '容器名或 ID（回车取消） >' || return
    [[ -n "$container" ]] || return
    if [[ ! "$container" =~ ^[[:alnum:]][[:alnum:]_.-]*$ ]]; then
        input_error '请输入单个容器名或 ID'
        return
    fi
    run_change docker "$1" -- "$container"
}

system_settings_menu() {
    open_menu system-settings '系统设置' '返回主菜单'
}

system_hostname_status() {
    run_cmd hostnamectl status
}

system_set_hostname() {
    local name
    read_field name '新主机名（回车取消） >' || return
    [[ -n "$name" ]] || return
    if [[ ! "$name" =~ ^[[:alnum:]][[:alnum:].-]*$ ]]; then
        input_error '请输入有效主机名'
        return
    fi
    run_admin_change hostnamectl set-hostname "$name"
}

system_timezones() {
    run_cmd timedatectl --no-pager list-timezones
}

system_set_timezone() {
    local zone
    read_field zone 'IANA 时区（例如 Asia/Shanghai，回车取消） >' || return
    [[ -n "$zone" ]] || return
    if [[ ! "$zone" =~ ^[[:alnum:]][[:alnum:]_/+-]*$ ]]; then
        input_error '请输入有效的 IANA 时区名'
        return
    fi
    run_admin_change timedatectl set-timezone "$zone"
}

system_set_ntp() {
    run_admin_change timedatectl set-ntp "$1"
}

system_journal_usage() {
    run_admin journalctl --disk-usage
}

system_journal_vacuum() {
    local days
    read_field days '删除早于多少天的归档日志？（回车取消） >' || return
    [[ -n "$days" ]] || return
    if [[ ! "$days" =~ ^[1-9][0-9]{0,3}$ ]]; then
        input_error '请输入 1–9999 之间的整数天数'
        return
    fi
    run_admin_change journalctl "--vacuum-time=${days}d"
}

package_manager=''

system_packages_menu() {
    open_menu packages "软件包 / $package_manager" '返回主菜单'
}

system_package_refresh() {
    if [[ "$package_manager" == apt-get ]]; then
        run_admin apt-get update
    else
        run_admin "$package_manager" makecache
    fi
}

system_package_action() {
    local operation="$1" package
    read_field package '包名（回车取消） >' || return
    [[ -n "$package" ]] || return
    if [[ ! "$package" =~ ^[[:alnum:]][[:alnum:].+_:-]*$ ]]; then
        input_error '请输入单个软件包名'
        return
    fi
    if [[ "$package_manager" == apt-get ]]; then
        if [[ "$operation" == info ]]; then
            run_cmd apt-cache policy "$package"
            return
        fi
        # APT 允许 +/- 操作后缀，只有名称完全匹配时才执行。
        if ! apt-cache show "$package" 2>/dev/null |
            awk -v package="${package%%:*}" '$1 == "Package:" && $2 == package { found = 1 } END { exit !found }'; then
            input_error '找不到该包，可先刷新软件包索引'
            return
        fi
    elif [[ "$operation" == info ]]; then
        run_cmd "$package_manager" info "$package"
        return
    fi
    run_admin_change "$package_manager" "$operation" "$package"
}

system_cron_menu() {
    open_menu cron '计划任务' '返回主菜单'
}

system_crontab_list() {
    run_cmd crontab -l
}

system_crontab_edit() {
    run_cmd crontab -e
}

system_timers() {
    run_cmd systemctl --no-pager list-timers --all
}

# ---------- 防火墙 ----------
firewall_menu() {
    open_menu firewall '防火墙' "${1:-返回}"
}

firewall_backend_menu() {
    open_menu "firewall-$1" "防火墙 / $1" '返回防火墙'
}

firewall_port_input() {
    local entry
    read_field entry '端口/协议（例如 443/tcp 或 53/udp，回车取消） >' || return 1
    [[ -n "$entry" ]] || return 1
    if [[ ! "$entry" =~ ^[0-9]+/(tcp|udp)$ ]] || ! valid_port "${entry%/*}"; then
        input_error '请输入 1–65535 内的端口和 tcp 或 udp 协议'
        return 1
    fi
    printf -v "$1" '%s' "$entry"
}

firewall_source_input() {
    local entry
    read_field entry '来源 IP/CIDR（回车表示任意来源） >' || return 1
    if [[ -n "$entry" ]] && { [[ ! "$entry" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] ||
        [[ "$entry" != *.* && "$entry" != *:* ]]; }; then
        input_error '请输入 IP 或 CIDR（例如 192.0.2.0/24）'
        return 1
    fi
    printf -v "$1" '%s' "$entry"
}

ufw_status() {
    run_admin ufw status verbose
}

ufw_port_change() {
    local spec source
    local action=(allow)
    [[ "$1" != remove ]] || action=(delete allow)
    firewall_port_input spec && firewall_source_input source || return
    if [[ -n "$source" ]]; then
        run_admin_change ufw "${action[@]}" in proto "${spec##*/}" from "$source" to any port "${spec%/*}"
    else
        run_admin_change ufw "${action[@]}" "$spec"
    fi
}

firewalld_status() {
    run_checks 'firewall-cmd --get-active-zones' 'firewall-cmd --list-all-zones'
}

firewalld_port_change() {
    local spec source zone scope family rich_rule
    local options=()
    firewall_port_input spec && firewall_source_input source || return
    read_field zone '区域（回车使用默认区域） >' || return
    if [[ -z "$zone" ]] && ! zone=$(firewall-cmd --get-default-zone); then
        input_error '读取默认区域失败，请确认 firewalld 正在运行'
        return
    fi
    if [[ ! "$zone" =~ ^[[:alnum:]_][[:alnum:]_.-]*$ ]]; then
        input_error '请输入有效的 firewalld 区域名'
        return
    fi
    read_field scope '生效范围（1 当前，2 永久配置；回车选 1） >' || return
    case "$scope" in
        ''|1) ;;
        2) options+=(--permanent) ;;
        *) input_error '请输入 1 或 2'; return ;;
    esac
    options+=("--zone=$zone")
    if [[ -n "$source" ]]; then
        family=ipv4
        [[ "$source" != *:* ]] || family=ipv6
        rich_rule="rule family=\"$family\" source address=\"$source\" port port=\"${spec%/*}\" protocol=\"${spec##*/}\" accept"
        options+=("--$1-rich-rule=$rich_rule")
    else
        options+=("--$1-port=$spec")
    fi
    run_admin_change firewall-cmd "${options[@]}"
}

firewalld_permanent_status() {
    run_cmd firewall-cmd --permanent --list-all-zones
}

firewalld_reload() {
    run_admin_change firewall-cmd --reload
}

nft_status() {
    run_admin nft -a list ruleset
}

nft_rules_file() {
    local file check apply script
    read_field file '规则文件的绝对路径（回车取消） >' || return
    [[ -n "$file" ]] || return
    if [[ "$file" != /* || ! -f "$file" ]]; then
        input_error '请输入现有规则文件的绝对路径'
        return
    fi
    if [[ "$1" == check ]]; then
        run_admin nft -c -f "$file"
    else
        format_command check '%q ' "${admin_prefix[@]}" nft -c -f "$file"
        format_command apply '%q ' "${admin_prefix[@]}" nft -f "$file"
        script="${check% } && ${apply% }"
        execute_task true "$script" bash -o pipefail -c "$script"
    fi
}

# ---------- 系统 / 基础工具 ----------
install_bt_panel() {
    local installer command
    format_command installer '%q ' "${admin_prefix[@]}" bash install_panel.sh ed8484bec
    command="wget -O install_panel.sh https://download.bt.cn/install/install_panel.sh && ${installer% }"
    execute_task true "$command" bash -o pipefail -c "$command"
}

update_system_packages() {
    run_admin apt-get update
}

install_compose_plugin() {
    run_admin_change apt-get install -y docker-compose-plugin
}

update_npm() {
    run_change npm install -g npm@12.0.1
}

register_firewall_menus() {
    local available=false
    if command -v ufw >/dev/null 2>&1; then
        available=true
        register_menu_item firewall '' 1 'UFW' firewall_backend_menu '' ufw
        register_menu_item firewall-ufw '' 1 '查看状态和规则' ufw_status
        register_menu_item firewall-ufw '' 2 '放行入站端口' ufw_port_change '' add
        register_menu_item firewall-ufw '' 3 '撤销端口放行' ufw_port_change '' remove
    fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        available=true
        register_menu_item firewall '' 2 'firewalld' firewall_backend_menu '' firewalld
        register_menu_item firewall-firewalld '规则' 1 '查看活动区域和当前规则' firewalld_status
        register_menu_item firewall-firewalld '规则' 2 '查看永久配置' firewalld_permanent_status
        register_menu_item firewall-firewalld '操作' 3 '放行入站端口' firewalld_port_change '' add
        register_menu_item firewall-firewalld '操作' 4 '撤销端口放行' firewalld_port_change '' remove
        register_menu_item firewall-firewalld '操作' 5 '重载永久配置' firewalld_reload
    fi
    if command -v nft >/dev/null 2>&1; then
        available=true
        register_menu_item firewall '' 3 'nftables' firewall_backend_menu '' nftables
        register_menu_item firewall-nftables '' 1 '查看当前规则集' nft_status
        register_menu_item firewall-nftables '' 2 '检查规则文件' nft_rules_file '' check
        register_menu_item firewall-nftables '' 3 '检查并应用规则文件' nft_rules_file '' apply
    fi
    if $available; then
        register_main_tool "$1" 41 '防火墙' firewall_menu '规则与端口' '返回主菜单'
        register_menu_item linux-network '' 3 '防火墙' firewall_menu '' '返回网络与监听'
    fi
}

register_system_settings() {
    local available=false
    if command -v hostnamectl >/dev/null 2>&1; then
        available=true
        register_menu_item system-settings '主机名' 1 '查看主机名' system_hostname_status
        register_menu_item system-settings '主机名' 2 '修改主机名' system_set_hostname
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        available=true
        register_menu_item system-settings '时间和时区' 3 '查看时间与同步状态' linux_time_status
        register_menu_item system-settings '时间和时区' 4 '列出可用时区' system_timezones
        register_menu_item system-settings '时间和时区' 5 '设置时区' system_set_timezone
        register_menu_item system-settings '时间和时区' 6 '启用 NTP' system_set_ntp '' true
        register_menu_item system-settings '时间和时区' 7 '停用 NTP' system_set_ntp '' false
    fi
    if command -v journalctl >/dev/null 2>&1; then
        available=true
        register_menu_item system-settings '系统日志' 8 '查看日志磁盘占用' system_journal_usage
        register_menu_item system-settings '系统日志' 9 '按天数清理归档日志' system_journal_vacuum
    fi
    if $available; then
        register_main_tool "$1" 44 '系统设置' system_settings_menu '主机名、时区与日志'
    fi
}

register_package_menus() {
    if command -v apt-get >/dev/null 2>&1 && command -v apt-cache >/dev/null 2>&1; then
        package_manager=apt-get
    elif command -v dnf >/dev/null 2>&1; then
        package_manager=dnf
    else
        return 0
    fi
    register_main_tool "$1" 45 '软件包' system_packages_menu "$package_manager"
    register_menu_item packages '' 1 '查看指定软件包' system_package_action '' info
    register_menu_item packages '' 2 '刷新软件包索引' system_package_refresh
    register_menu_item packages '' 3 '安装指定软件包' system_package_action '' install
    register_menu_item packages '' 4 '卸载指定软件包' system_package_action '' remove
}

register_management_menus() {
    local group='通用运维' has_cron=false
    register_menu_item main "$group" 40 'Linux 排障' linux_menu
    register_firewall_menus "$group"
    if command -v systemctl >/dev/null 2>&1; then
        register_main_tool "$group" 42 '服务管理' linux_service_menu 'systemd' '返回主菜单'
        register_menu_item linux-services '状态与日志' 3 '列出已加载的服务' linux_list_services
        register_menu_item linux-services '服务操作' 4 '启动服务' linux_service_change '' start
        register_menu_item linux-services '服务操作' 5 '停止服务' linux_service_change '' stop
        register_menu_item linux-services '服务操作' 6 '重启服务' linux_service_change '' restart
        register_menu_item linux-services '服务操作' 7 '重载服务配置' linux_service_change '' reload
        register_menu_item linux-services '服务操作' 8 '设置开机启动' linux_service_change '' enable
        register_menu_item linux-services '服务操作' 9 '取消开机启动' linux_service_change '' disable
    fi
    if command -v docker >/dev/null 2>&1; then
        register_main_tool "$group" 43 'Docker 容器' linux_docker_menu '' '返回主菜单'
        register_menu_item linux-docker '容器操作' 6 '启动容器' linux_docker_change '' start
        register_menu_item linux-docker '容器操作' 7 '停止容器' linux_docker_change '' stop
        register_menu_item linux-docker '容器操作' 8 '重启容器' linux_docker_change '' restart
    fi
    register_system_settings "$group"
    register_package_menus "$group"
    if command -v crontab >/dev/null 2>&1; then
        has_cron=true
        register_menu_item cron '' 1 '查看当前用户的 crontab' system_crontab_list
        register_menu_item cron '' 2 '编辑当前用户的 crontab' system_crontab_edit
    fi
    if command -v systemctl >/dev/null 2>&1; then
        has_cron=true
        register_menu_item cron '' 3 '查看 systemd 定时器' system_timers
    fi
    if $has_cron; then
        register_main_tool "$group" 46 '计划任务' system_cron_menu
    fi
}

register_builtin_menus() {
    local system_group='系统工具'

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
        register_menu_item linux-services '状态与日志' 1 '列出失败服务' linux_failed_services
        if command -v journalctl >/dev/null 2>&1; then
            register_menu_item linux-services '状态与日志' 2 '服务状态与最近 100 行日志' linux_service_details
        else
            register_menu_item linux-services '状态与日志' 2 '查看服务状态' linux_service_details
        fi
    fi

    if command -v docker >/dev/null 2>&1; then
        register_menu_item linux '' 7 'Docker 排障' linux_docker_menu '查容器、资源、日志和磁盘用量'
        register_menu_item linux-docker '状态与日志' 1 '列出所有容器' linux_docker_ps
        register_menu_item linux-docker '状态与日志' 2 '查看容器资源占用' linux_docker_stats
        register_menu_item linux-docker '状态与日志' 3 '查看容器最近 100 行日志' linux_docker_logs
        register_menu_item linux-docker '状态与日志' 4 '查看 Docker 磁盘用量' linux_docker_disk
        register_menu_item linux-docker '状态与日志' 5 '容器退出码、OOM 与健康状态' linux_docker_state
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

    register_management_menus
    if command -v wget >/dev/null 2>&1; then
        register_menu_item main "$system_group" 31 '安装宝塔面板' install_bt_panel
    fi
    if command -v apt-get >/dev/null 2>&1; then
        register_menu_item main "$system_group" 32 '更新系统包索引' update_system_packages 'apt-get update'
        register_menu_item main "$system_group" 33 '安装 docker-compose-plugin' install_compose_plugin
    fi
    if command -v npm >/dev/null 2>&1; then
        register_menu_item main "$system_group" 34 '升级全局 npm' update_npm '12.0.1'
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
    register_builtin_menus
    if [[ "${OPS_LOAD_PROJECTS:-1}" != 0 ]]; then
        load_extensions "$script_dir/ops.d" || return 1
    fi
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
