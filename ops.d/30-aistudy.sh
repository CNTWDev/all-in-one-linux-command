# AIStudy 部署参数与项目菜单。
AISTUDY_DIR="${AISTUDY_DIR:-/opt/aistudy}"
AISTUDY_CONFIG_DIR="${AISTUDY_CONFIG_DIR:-$AISTUDY_DIR/config}"
AISTUDY_BACKUP_DIR="${AISTUDY_BACKUP_DIR:-$AISTUDY_CONFIG_DIR/backups}"
AISTUDY_THEMES_DIR="${AISTUDY_THEMES_DIR:-$AISTUDY_DIR/data/themes}"
AISTUDY_SERVICE="${AISTUDY_SERVICE:-aistudy}"
AISTUDY_WORKER_SERVICE="${AISTUDY_WORKER_SERVICE:-aistudy-worker}"
AISTUDY_DOMAIN="${AISTUDY_DOMAIN:-study.oiihub.com}"

# ---------- 配置项定义（数据驱动核心）----------
# 格式: "显示名|toml_key|文件"
AISTUDY_LLM_ITEMS=(
    "默认提供方|default|llm.toml"
    "每日调用上限|daily_limit_per_kid|llm.toml"
    "缓存开关|cache|llm.toml"
    "Claude API Key|providers.claude.api_key|llm.toml"
    "Claude Model|providers.claude.model|llm.toml"
    "Claude Timeout|providers.claude.timeout|llm.toml"
    "DeepSeek API Key|providers.deepseek.api_key|llm.toml"
    "DeepSeek Model|providers.deepseek.model|llm.toml"
    "DeepSeek Base URL|providers.deepseek.base_url|llm.toml"
)
AISTUDY_MAIL_ITEMS=(
    "发信提供方|provider|mail.toml"
    "发件人|from|mail.toml"
    "每日发送上限|daily_limit|mail.toml"
    "SMTP Host|smtp.host|mail.toml"
    "SMTP Port|smtp.port|mail.toml"
    "SMTP Security|smtp.security|mail.toml"
    "SMTP Username|smtp.username|mail.toml"
    "SMTP Password|smtp.password|mail.toml"
    "周报星期|weekly.weekday|mail.toml"
    "周报时间|weekly.hour|mail.toml"
)
AISTUDY_TTS_ITEMS=(
    "TTS 提供方|provider|tts.toml"
    "最大字符数|max_chars|tts.toml"
    "用户日限额|daily_chars_per_user|tts.toml"
    "全站日限额|daily_chars_total|tts.toml"
    "Cartesia API Key|cartesia.api_key|tts.toml"
    "Cartesia Model|cartesia.model|tts.toml"
    "英文声音ID|voices.en|tts.toml"
    "中文声音ID|voices.zh|tts.toml"
    "查词语速|speed.word|tts.toml"
    "例句语速|speed.sentence|tts.toml"
    "阅读语速|speed.passage|tts.toml"
)

aistudy_do_backup() {
    local ts stamp file count=0
    stamp=$(date +%Y%m%d_%H%M%S) || return 1
    mkdir -p "$AISTUDY_BACKUP_DIR" || return 1
    ts=$stamp
    while compgen -G "$AISTUDY_BACKUP_DIR/*_$ts.toml" >/dev/null; do
        ((count += 1))
        ts="${stamp}_$count"
    done
    for file in llm.toml mail.toml tts.toml; do
        if [[ -f "$AISTUDY_CONFIG_DIR/$file" ]]; then
            cp "$AISTUDY_CONFIG_DIR/$file" "$AISTUDY_BACKUP_DIR/${file%.toml}_${ts}.toml" || return 1
        fi
    done
    status "$GREEN" 'OK' "备份目录 $AISTUDY_BACKUP_DIR/  ·  *_${ts}.toml"
}

aistudy_toml_entry() {
    local file="$1" key="${2##*.}" section=''
    if [[ "$2" == *.* ]]; then
        section="${2%.*}"
    fi
    [[ -f "$file" ]] || return 1
    awk -v section="$section" -v key="$key" '
        BEGIN { in_section = section == "" }
        /^[[:space:]]*\[/ {
            header = $0
            sub(/^[[:space:]]*\[[[:space:]]*/, "", header)
            sub(/[[:space:]]*\].*$/, "", header)
            in_section = header == section
        }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub(/^[^=]*=[[:space:]]*/, "")
            print NR "|" $0
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$file"
}

aistudy_toml_set() {
    local file="$1" value="$3" line="${2%%|*}" raw="${2#*|}"
    # 保留现有字符串与数值、布尔等字面量的区别。
    case "$raw" in
        \"*|\'*)
            value=${value//\\/\\\\}
            value=${value//\"/\\\"}
            value="\"$value\""
            ;;
    esac
    value=${value//\\/\\\\}
    value=${value//&/\\&}
    value=${value//|/\\|}
    sed -i "${line}s|=.*|= $value|" "$file"
}

aistudy_is_secret() {
    [[ "$1" == *.api_key || "$1" == *.password ]]
}

aistudy_config_submenu() {
    local title="$1"
    shift
    local items=("$@") i name key file entry value choice new_value
    local entries=()
    while true; do
        screen "AIStudy / $title"
        for i in "${!items[@]}"; do
            IFS='|' read -r name key file <<< "${items[$i]}"
            if entry=$(aistudy_toml_entry "$AISTUDY_CONFIG_DIR/$file" "$key"); then
                value="${entry#*|}"
                if aistudy_is_secret "$key"; then
                    value='******'
                else
                    case "$value" in
                        \"*\") value="${value:1:${#value}-2}" ;;
                        \'*\') value="${value:1:${#value}-2}" ;;
                    esac
                    value=${value//[[:cntrl:]]/?}
                fi
            else
                value='未配置'
            fi
            entries[$i]="$entry"
            printf '  %s[%2d]%s  %s  %s|%s  %s\n' "$CYAN" "$((i + 1))" "$RESET" "$name" "$DIM" "$RESET" "$value"
        done
        printf '\n'
        rows '0|返回配置管理'
        rule
        prompt 'config >'
        IFS= read -r choice || return
        case "$choice" in
            0) return ;;
            [1-9]|1[01]) ;;
            *) choice=0 ;;
        esac
        if ((choice < 1 || choice > ${#items[@]})); then
            status "$AMBER" 'INPUT' '请选择菜单中显示的编号'
            pause || return
            continue
        fi

        i=$((choice - 1))
        IFS='|' read -r name key file <<< "${items[$i]}"
        if [[ -z "${entries[$i]}" ]]; then
            status "$AMBER" 'INPUT' "找不到 $file 中的 $key"
            pause || return
            continue
        fi
        printf '\n'
        prompt "$name 的新值（直接回车取消） >"
        if aistudy_is_secret "$key"; then
            IFS= read -rs new_value || return
            printf '\n'
        else
            IFS= read -r new_value || return
        fi
        [[ -n "$new_value" ]] || continue

        if aistudy_do_backup && aistudy_toml_set "$AISTUDY_CONFIG_DIR/$file" "${entries[$i]}" "$new_value"; then
            status "$GREEN" 'OK' "已更新 $file / $key"
        else
            status "$RED" 'FAIL' "更新失败 $file / $key"
        fi
        pause || return
    done
}

aistudy_install() {
    local command
    format_command command 'curl -fsSL https://raw.githubusercontent.com/CNTWDev/AIStudy/main/install.sh | sudo bash -s -- install --domain %q' "$AISTUDY_DOMAIN"
    run_shell "$command"
}

aistudy_upgrade() {
    run_cmd sudo "$AISTUDY_DIR/install.sh" upgrade
}

aistudy_restart() {
    run_cmd sudo systemctl restart -- "$AISTUDY_SERVICE" "$AISTUDY_WORKER_SERVICE"
}

aistudy_service_status() {
    run_cmd systemctl --no-pager status -- "$AISTUDY_SERVICE" "$AISTUDY_WORKER_SERVICE"
}

aistudy_config_menu() {
    open_menu aistudy-config 'AIStudy / 配置管理' '返回主菜单' 'config >'
}

aistudy_config_llm() {
    aistudy_config_submenu 'LLM 大模型配置' "${AISTUDY_LLM_ITEMS[@]}"
}

aistudy_config_mail() {
    aistudy_config_submenu 'Mail 邮件配置' "${AISTUDY_MAIL_ITEMS[@]}"
}

aistudy_config_tts() {
    aistudy_config_submenu 'TTS 朗读配置' "${AISTUDY_TTS_ITEMS[@]}"
}

aistudy_backup_config() {
    run_task 'aistudy_do_backup' aistudy_do_backup
}

aistudy_list_backups() {
    if [[ -d "$AISTUDY_BACKUP_DIR" ]]; then
        run_cmd ls -lh -- "$AISTUDY_BACKUP_DIR/"
    else
        screen 'AIStudy / 配置备份'
        printf '  暂无备份\n'
        pause
    fi
}

aistudy_install_theme() {
    local path command
    screen 'AIStudy / 安装主题'
    printf '  先上传主题压缩包（.tgz 或 .tar.gz）。\n'
    prompt '主题包完整路径（直接回车取消） >'
    IFS= read -r path || return
    [[ -n "$path" ]] || return
    if [[ ! -f "$path" ]]; then
        status "$RED" 'FAIL' "文件不存在 $path"
        pause
        return
    fi
    format_command command 'sudo mkdir -p -- %q && sudo tar xzf %q -C %q && sudo chown -R aistudy:aistudy -- %q && sudo systemctl restart -- %q' \
        "$AISTUDY_THEMES_DIR" "$path" "$AISTUDY_THEMES_DIR" "$AISTUDY_THEMES_DIR" "$AISTUDY_SERVICE"
    run_shell "$command"
}

register_menu_item main AIStudy 121 '安装' aistudy_install
register_menu_item main AIStudy 122 '升级' aistudy_upgrade
if command -v systemctl >/dev/null 2>&1; then
    register_menu_item main AIStudy 123 '重启' aistudy_restart
fi
register_menu_item main AIStudy 124 '配置管理' aistudy_config_menu
if command -v systemctl >/dev/null 2>&1; then
    register_menu_item main AIStudy 125 '安装主题' aistudy_install_theme
    register_menu_item main AIStudy 126 '服务状态' aistudy_service_status
fi

register_menu_item aistudy-config '' 1 'LLM 大模型配置' aistudy_config_llm
register_menu_item aistudy-config '' 2 'Mail 邮件配置' aistudy_config_mail
register_menu_item aistudy-config '' 3 'TTS 朗读配置' aistudy_config_tts
register_menu_item aistudy-config '' 4 '手动备份全部配置' aistudy_backup_config
register_menu_item aistudy-config '' 5 '查看备份列表' aistudy_list_backups
