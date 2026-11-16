# All-in-One Linux Command

在 Linux 服务器上运行 `ops`，从终端菜单排障、管理系统和运行本机项目操作。执行页显示实际运行的命令、输出和退出码。

## 一键安装

在目标服务器上执行。需要 Bash、curl 和 tar，安装到当前用户目录，无需 sudo。

```bash
bash -c 'installer=$(curl -fsSL https://raw.githubusercontent.com/CNTWDev/all-in-one-linux-command/main/install.sh) && bash -c "$installer"'
```

安装后运行 `ops`。如果 `~/.local/bin` 尚未加入 `PATH`，可先运行 `~/.local/bin/ops`，也可以将 `export PATH="$HOME/.local/bin:$PATH"` 写入自己的 shell 启动文件。

从源码目录执行 `bash install.sh` 可安装当前目录里的版本。也可以直接运行 `./ops.sh`，旧入口 `./server-ops-menu.sh` 仍可用。只复制 `ops.sh` 就能运行通用菜单。

## 升级

```bash
ops update
```

也可以打开 `ops`，选择系统工具里的 **35 升级运维工作台**。升级会下载 GitHub `main` 的最新版本，复用当前安装位置并保留本机扩展。升级后重新打开 `ops` 即可使用新版。

早期版本需要先重新执行一次上方的一键安装命令，之后就可以直接用 `ops update`。

## 主菜单

终端足够宽时，菜单以等宽双栏按组编排。窄窗口自动改为单栏，重定向输出时使用纯文本。主机名显示在页头，输入编号即可直达对应操作。

| 入口 | 能做什么 |
| --- | --- |
| **40 Linux 排障** | 查机器负载、磁盘、网络、服务、容器和启动日志 |
| **41 防火墙** | 查看和修改 UFW、firewalld 或 nftables 规则 |
| **42 服务管理** | 查 systemd 服务和日志，启动、停止、重启、重载或调整开机启动 |
| **43 Docker 容器** | 查容器状态、资源和日志，启动、停止或重启指定容器 |
| **44 系统设置** | 改主机名和时区、切换 NTP、查看日志占用并按天数清理已归档的日志 |
| **45 软件包** | 用 APT 或 DNF 查看、安装和卸载指定包，以及刷新索引 |
| **46 计划任务** | 查看或编辑当前用户的 crontab，查看 systemd 定时器 |

入口按本机命令可用性显示。如果扩展已占用 `35` 或 `41`–`46` 中的编号，新通用入口会使用其他空闲编号。服务、容器、系统设置和防火墙变更会先显示完整命令，输入 `y` 执行。需要管理员权限的通用操作在非 root 账户下使用本机的 `sudo`。容器操作和 crontab 操作使用启动 `ops` 的账户。

VPN 的 `1`–`8` 继续直达对应升级操作。HushClaw 和 AIStudy 入口由随仓库分发的扩展提供。AIStudy 的 `24` 可编辑和备份配置，`25` 安装主题，`26` 查看服务状态。

### 防火墙

- **UFW** 可查看状态，按 `端口/协议` 和可选的来源 IP/CIDR 放行或撤销入站规则。
- **firewalld** 可查看活动区域和永久配置。修改端口时可指定区域以及来源 IP/CIDR，并选择修改当前规则或永久配置。永久配置在重载或服务重启后生效。重载会用永久配置替换当前配置。
- **nftables** 可查看当前规则集、检查规则文件，或检查通过后应用该文件。

### Linux 排障

进入 **40 Linux 排障**，按现场问题选择操作。

| 现场问题 | 菜单 | 可以查看 |
| --- | --- | --- |
| 机器卡 | 1 机器概览 | `uptime`、`free -h`、`vmstat 1 5` |
| 机器卡 | 2 进程排行 | 按 CPU 和内存占用分别列出前 10 个进程 |
| 磁盘满或读写慢 | 3 磁盘与目录 | 分区空间、inode、目录用量、设备挂载点、已删除但仍占空间的文件、磁盘 I/O |
| 端口不通 | 4 网络与监听 | 本机 IP、路由、监听进程，从本机测试指定 TCP 端口 |
| 域名或接口访问失败 | 5 DNS / HTTP 检测 | 域名解析、HTTP 状态码、对端 IP、DNS 和首字节耗时、重定向地址 |
| 服务挂了 | 6 服务与日志 | 失败服务、指定服务的状态及最近 100 行日志 |
| 容器异常 | 7 Docker 排障 | 容器列表、资源占用、日志、磁盘用量、退出码、OOM 和健康状态 |
| 突然重启或进程消失 | 8 内核与启动日志 | 启动历史、本次和上次启动的错误、内核告警、近 24 小时 OOM 记录 |
| 时间不准 | 9 时间与同步 | 系统时间、时区和 NTP 状态 |

Docker、systemd、DNS / HTTP 和 `nc`、`lsof`、`iostat` 等工具的入口随本机命令可用性显示。排障命令以当前用户权限运行，因此进程信息、日志和容器信息取决于账户权限。查询上次启动错误需要系统保留上一次启动的日志。

在交互终端里，进程排行的条形长度相对各榜首位，磁盘空间和 inode 的条形表示实际使用率。磁盘使用率达到 75% 显示黄色，达到 90% 显示红色。可用 `NO_COLOR=1 ops` 查看无颜色的条形图。重定向输出时仅保留纯文本。

## 给不同服务器加菜单

本机扩展默认放在 `~/.config/all-in-one-linux-command/ops.d/`。如果设置了 `XDG_CONFIG_HOME`，则使用其中的 `all-in-one-linux-command/ops.d/`。也可以通过 `OPS_EXTENSION_DIR` 指定整套本机扩展的位置。将自己维护的 `.sh` 文件放进去，重开 `ops` 即生效。

随仓库分发的项目扩展放在 `ops.d/`。启动时先登记通用菜单，再按文件名顺序加载随仓库分发的扩展，最后加载本机扩展。用 `OPS_LOAD_PROJECTS=0 ops` 可以只加载通用菜单和本机扩展。扩展会以运行 `ops` 的账户权限执行，请使用你信任的脚本。

下面的示例可保存为本机扩展目录下的 `50-example.sh`。把 Compose 目录和健康检查 URL 换成这台服务器的部署参数。

```bash
EXAMPLE_COMPOSE_DIR=/srv/example
EXAMPLE_HEALTH_URL=http://127.0.0.1:8080/health

example_ops_menu() {
    open_menu example '示例项目' '返回主菜单'
}

example_ops_status() {
    run_cmd docker compose --project-directory "$EXAMPLE_COMPOSE_DIR" \
        -f "$EXAMPLE_COMPOSE_DIR/compose.yaml" ps
}

example_ops_health() {
    run_cmd curl -fsS --max-time 10 -- "$EXAMPLE_HEALTH_URL"
}

register_menu_item main '本机项目' 50 '示例项目' example_ops_menu
if command -v docker >/dev/null 2>&1; then
    register_menu_item example '' 1 'Compose 状态' example_ops_status
fi
if command -v curl >/dev/null 2>&1; then
    register_menu_item example '' 2 '健康检查' example_ops_health
fi
```

- `register_menu_item 菜单 分组 编号 名称 函数 [说明] [函数参数]` 登记菜单项。主菜单名为 `main`，子菜单使用项目自己的名称。同一层的编号必须唯一，`0` 留给返回或退出。分组留空时不显示分组标题。
- `open_menu 菜单 标题 返回文案` 打开子菜单。`run_cmd 命令 参数...` 按独立参数执行并显示执行记录。用 `run_change 命令 参数...` 可以让操作者先看命令并确认变更。需要管道或命令组合时，扩展可以用 `run_shell` 执行固定的 Bash 命令。
- 项目扩展维护自己的安装路径、服务名、升级命令和检查地址。例如用 `VPN_UPDATE` 覆盖 VPN 升级脚本，用 `AISTUDY_DIR`、`AISTUDY_SERVICE`、`AISTUDY_WORKER_SERVICE` 和 `AISTUDY_DOMAIN` 适配 AIStudy 部署。
