# HushClaw 安装与升级。
HUSHCLAW_DIR="${HUSHCLAW_DIR:-$HOME/.hushclaw/repo}"

hushclaw_install() {
    run_shell 'bash <(curl -fsSL https://raw.githubusercontent.com/CNTWDev/hushclaw/master/install.sh)'
}

hushclaw_update() {
    run_cmd bash "$HUSHCLAW_DIR/install.sh" --update
}

hushclaw_install_web() {
    run_shell 'curl -fsSL https://raw.githubusercontent.com/CNTWDev/hushclaw-web/master/install.sh | sudo bash'
}

register_menu_item main HushClaw 111 '安装' hushclaw_install
register_menu_item main HushClaw 112 '更新' hushclaw_update
register_menu_item main HushClaw 113 '安装 HushClaw-Web' hushclaw_install_web
