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

主菜单按编号排列。系统工具和通用运维在前，产品入口从 `100` 起。本机 Bash 扩展使用 `200` 起的编号。终端足够宽时按组显示双栏，窄窗口使用单栏，重定向输出时使用纯文本。

| 入口 | 能做什么 |
| --- | --- |
| **40 Linux 排障** | 查机器负载、磁盘、网络、服务、容器和启动日志 |
| **41 防火墙** | 查看和修改 UFW、firewalld 或 nftables 规则 |
| **42 服务管理** | 查 systemd 服务和日志，启动、停止、重启、重载或调整开机启动 |
| **43 Docker 容器** | 查容器状态、资源和日志，启动、停止或重启指定容器 |
| **44 系统设置** | 改主机名和时区、切换 NTP、查看日志占用并按天数清理已归档的日志 |
| **45 软件包** | 用 APT 或 DNF 查看、安装和卸载指定包，以及刷新索引 |
| **46 计划任务** | 查看或编辑当前用户的 crontab，查看 systemd 定时器 |
| **47 产品管理** | 发现已部署产品、导入发布清单、管理产品命令和配置 |

入口按本机命令可用性显示。服务、容器、系统设置和防火墙变更会先显示完整命令，输入 `y` 执行。需要管理员权限的通用操作在非 root 账户下使用本机的 `sudo`。容器操作和 crontab 操作使用启动 `ops` 的账户。

VPN 的升级操作改用 `101`–`108`，HushClaw 使用 `111`–`113`，AIStudy 使用 `121`–`126`，宝塔面板安装入口为 `131`。AIStudy 的 `124` 可编辑和备份配置，`125` 安装主题，`126` 查看服务状态。

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

### 已经部署的产品：从服务器发现

在目标服务器打开 **`ops` → 47 产品管理 → 发现已部署产品**。选一个你知道的入口：

| 你知道什么 | 选这个入口 | `ops` 能找到什么 |
| --- | --- | --- |
| 服务名或关键词，比如 `nginx` | 本机 systemd 服务 | 匹配服务、状态和日志命令、可选重启，以及服务声明的工作目录和配置目录 |
| 用 Docker Compose 部署，忘了文件放哪 | 已部署 Compose 项目 | Docker 当前登记的项目名和 Compose 文件，保留多文件顺序，生成状态和日志命令 |
| 安装目录，比如 `/srv/myapp` | 部署目录 / 产品发布清单 | 随包附带的运维清单，或者目录内的配置、Compose 文件和脚本候选 |

选择命令、配置文件和要管理的字段，然后保存。在配置选择阶段可以补充这个产品的其他绝对路径，例如 `/etc/myapp/server.json` 和 `/var/lib/myapp/options.toml`。自定义备份或升级命令可以在产品菜单用「新增命令」登记，每条命令都有自己的工作目录。

在 `47 产品管理` 内，已登记的产品从 `100` 起分配编号，新产品排在已有产品后面。更新产品清单保留原编号，移除产品后，该编号留给原产品 ID。旧版本已登记的产品在第一次分配编号时按 ID 排列。

发现功能在服务器上运行，不需要 AI 或 API Key。它读取部署元数据，在指定目录内有限扫描，输出路径和候选命令，不会执行发现的脚本或修改配置。目录发现不会扫描整个系统，也不跟随目录中的符号链接。扫描结果仅覆盖本机能访问的文件；容器内未挂载到宿主机的文件需要另外处理。YAML、INI、CONF 和 env 可以列为线索，目前只支持编辑 JSON 和 TOML。产品管理需要 Python 3.8 或以上版本，TOML 首次使用时运行 `ops product setup`。

可以给脚本、发布流水线或自己使用的 AI 工具输出发现报告：

```bash
ops product discover --unit myapp.service
ops product discover --compose myapp-prod
ops product discover /srv/myapp --config /etc/myapp/server.json > discovery.json
ops product discover --unit myapp.service --config /etc/myapp/server.json \
  --manifest myapp --name "My App" > myapp.product.json
ops product import myapp.product.json --dry-run
```

普通报告不包含配置值、服务启动参数或环境变量，但会包含服务器路径和服务名。草稿模式登记建议的查询命令和用 `--config` 明确指定的 JSON/TOML 文件，字段权限可随后在菜单中选择。

### 今后发布的产品：随包交付运维清单

在产品发布目录放一份 `ops.product.json`。把备份、升级、健康检查等产品专属命令写进清单，管理员选「部署目录 / 产品发布清单」即可预览和登记，也可在发布流程里调用同一套 CLI：

```bash
ops product validate /srv/myapp/ops.product.json --directory /srv/myapp
ops product import /srv/myapp/ops.product.json --directory /srv/myapp --dry-run
ops product import /srv/myapp/ops.product.json --directory /srv/myapp
```

`--directory` 使用服务器上的实际部署目录解析相对路径。配合这个参数发布时，清单可以省略 `directory`，同一发布包可部署到不同目录。配置文件和每条命令的 `cwd` 都可以独立使用绝对路径，绝对路径在导入时保持原样。服务器特殊路径可使用自己的清单副本。仅导入可信来源的清单，先查看命令和配置路径；导入本身不会执行产品命令。重新导入已登记的 ID 需显式使用 `--replace`，这会替换该产品当前的登记信息。

产品清单登记文件路径、可管理字段和命令，产品继续使用原配置文件。登记字段后可以查看、新增值或修改值。字段显式设置 `"delete": true` 后才可删除。保存前可预览差异，保存时备份原文件，配置菜单可恢复最近备份。密钥和密码字段在查看和预览时脱敏，可通过终端隐藏输入或 `--stdin` 更新。解除配置登记或移除产品登记只删除菜单记录。

### 用 AI 生成产品清单

把服务器上的发现报告、清单示例和需要管理的字段结构交给你已经在用的 AI，让它生成草稿，再回服务器用 `--dry-run` 检查。自己提供产品专属命令的准确用法，例如项目文档或发布脚本；不要让 AI 猜测升级命令。字段检查只输出字段路径和类型。

```bash
ops product template aistudy > aistudy.json
ops config inspect /opt/aistudy/config/llm.toml --keys-only
```

清单的 `schema_version` 为 `1`，包含产品 `id`、`name`、`directory`、`actions` 和 `configs`。字段支持点分隔路径和 `string`、`integer`、`number`、`boolean` 四种类型，可用 `secret` 标记需脱敏的字段。命令支持 `systemd.status`、`systemd.restart` 和 `command`。自定义命令用 `argv` 数组登记参数，例如 `["docker", "compose", "ps"]`。查询命令可显式设置 `"change": false`，其余命令在终端确认后执行。凭据留在服务器配置里，不要写进发布清单。

```bash
ops product validate aistudy.json
ops product import aistudy.json --dry-run
ops product import aistudy.json
ops product export aistudy > aistudy.export.json
ops product run aistudy status --dry-run
ops config get aistudy llm daily_limit_per_kid
ops config set aistudy llm daily_limit_per_kid 30 --dry-run
```

按实际服务器修改示例里的目录和服务名。导入会检查已绑定的文件和现有字段类型，登记后从产品菜单运行命令。更新已有清单时使用 `ops product import 文件 --replace`。配置命令也提供 `list`、`delete` 和 `restore`，可通过 `ops config --help` 查看。

产品清单和备份默认保存在 `${XDG_CONFIG_HOME:-$HOME/.config}/all-in-one-linux-command/products/`，可用 `OPS_PRODUCTS_DIR` 指定其他目录。升级 `ops` 时会保留这些文件。配置编辑使用运行 `ops` 的账户权限。

### Bash 扩展

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

register_menu_item main '本机项目' 200 '示例项目' example_ops_menu
if command -v docker >/dev/null 2>&1; then
    register_menu_item example '' 1 'Compose 状态' example_ops_status
fi
if command -v curl >/dev/null 2>&1; then
    register_menu_item example '' 2 '健康检查' example_ops_health
fi
```

- `register_menu_item 菜单 分组 编号 名称 函数 [说明] [函数参数]` 登记菜单项。主菜单名为 `main`，子菜单使用项目自己的名称。同一层的编号必须唯一，`0` 留给返回或退出。分组留空时不显示分组标题。
- 本机 Bash 扩展向主菜单添加条目时，从 `200` 起选择空闲编号，后续条目使用更大的编号。旧扩展在主菜单使用 `1`–`199` 时，自动迁移到原编号加 `200` 的位置，遇到占用就顺延到空闲位置。项目子菜单可从 `1` 开始编号。
- `open_menu 菜单 标题 返回文案` 打开子菜单。`run_cmd 命令 参数...` 按独立参数执行并显示执行记录。用 `run_change 命令 参数...` 可以让操作者先看命令并确认变更。需要管道或命令组合时，扩展可以用 `run_shell` 执行固定的 Bash 命令。
- 项目扩展维护自己的安装路径、服务名、升级命令和检查地址。例如用 `VPN_UPDATE` 覆盖 VPN 升级脚本，用 `AISTUDY_DIR`、`AISTUDY_SERVICE`、`AISTUDY_WORKER_SERVICE` 和 `AISTUDY_DOMAIN` 适配 AIStudy 部署。
