#!/bin/bash
set -e
export LC_ALL=C

source_archive='https://codeload.github.com/CNTWDev/all-in-one-linux-command/tar.gz/refs/heads/main'
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/all-in-one-linux-command"
bin_dir="${OPS_BIN_DIR:-$HOME/.local/bin}"
config_dir="${OPS_EXTENSION_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/all-in-one-linux-command/ops.d}"
launcher_marker='# all-in-one-linux-command launcher'
updating=false
source_dir='' download_dir='' release_dir='' new_launcher=''
keep_release=false

if (($# > 0)); then
    if (($# != 2)) || [[ "$1" != --update || "$2" != /*/ops || ! -f "$2" ]]; then
        printf '请使用已安装的 ops update 升级。\n' >&2
        exit 2
    fi
    current_release=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    if [[ "${current_release%/*}" != */releases || "${current_release##*/}" != ops.* ]]; then
        printf '找不到当前安装的版本目录。\n' >&2
        exit 1
    fi
    updating=true
    data_dir="${current_release%/releases/*}"
    bin_dir="${2%/ops}"
fi

cleanup() {
    [[ -z "$download_dir" ]] || rm -rf -- "$download_dir"
    [[ -z "$new_launcher" ]] || rm -f -- "$new_launcher"
    if ! $keep_release && [[ -n "$release_dir" ]]; then
        rm -rf -- "$release_dir"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p -- "$data_dir/releases" "$bin_dir"
if ! $updating; then
    mkdir -p -- "$config_dir"
fi
data_dir=$(CDPATH='' cd -- "$data_dir" && pwd -P)
bin_dir=$(CDPATH='' cd -- "$bin_dir" && pwd -P)
launcher="$bin_dir/ops"

if [[ -e "$launcher" || -L "$launcher" ]]; then
    if [[ -L "$launcher" || ! -f "$launcher" ]] || ! grep -qxF -- "$launcher_marker" "$launcher"; then
        printf '安装位置已有其他文件 %s\n可用 OPS_BIN_DIR 指定另一个目录。\n' "$launcher" >&2
        exit 1
    fi
fi

if ! $updating && [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    source_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
fi
if [[ -z "$source_dir" || ! -f "$source_dir/ops.sh" || ! -d "$source_dir/ops.d" ]]; then
    download_dir=$(mktemp -d)
    mkdir -- "$download_dir/source"
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 120 \
        -o "$download_dir/source.tar.gz" "$source_archive"
    tar -xzf "$download_dir/source.tar.gz" -C "$download_dir/source" --strip-components=1
    source_dir="$download_dir/source"
fi

# 先准备完整版本，再替换启动器。已启动的会话仍可使用原版本。
release_dir=$(mktemp -d "$data_dir/releases/ops.XXXXXXXX")
cp -- "$source_dir/ops.sh" "$source_dir/install.sh" "$release_dir/"
cp -R -- "$source_dir/ops.d" "$release_dir/"
bash -n "$release_dir/ops.sh"
bash -n "$release_dir/install.sh"
for extension in "$release_dir"/ops.d/*.sh; do
    [[ ! -f "$extension" ]] || bash -n "$extension"
done
chmod 755 "$release_dir/ops.sh"

new_launcher=$(mktemp "$bin_dir/.ops.XXXXXXXX")
printf '#!/bin/bash\n%s\nOPS_INSTALL_LAUNCHER=%q exec %q "$@"\n' \
    "$launcher_marker" "$launcher" "$release_dir/ops.sh" > "$new_launcher"
chmod 755 "$new_launcher"
keep_release=true
if ! mv -f -- "$new_launcher" "$launcher"; then
    keep_release=false
    exit 1
fi

if $updating; then
    printf '已升级运维工作台。重新运行 ops 即可使用新版。\n'
else
    printf '已安装运维工作台。\n启动命令 %q\n本机扩展目录 %s\n' "$launcher" "$config_dir"
    case ":${PATH:-}:" in
        *":$bin_dir:"*) printf '也可以直接输入 ops。\n' ;;
    esac
fi
