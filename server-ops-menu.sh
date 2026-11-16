#!/bin/bash
# 兼容原服务器运维菜单入口。
exec "$(dirname -- "${BASH_SOURCE[0]}")/ops.sh" "$@"
