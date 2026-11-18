"""Local product registry and configuration editor."""
import argparse
from contextlib import contextmanager, nullcontext
import fcntl
import getpass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import time


STATE = Path(os.environ.get("OPS_PRODUCTS_DIR") or
             Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
             / "all-in-one-linux-command" / "products").expanduser().resolve()
MANIFESTS = STATE / "manifests"
MENU_NUMBERS = STATE / "menu-numbers.json"
FIRST_PRODUCT_NUMBER = 100
TYPES = {"string": str, "integer": int, "number": float, "boolean": bool}
ID = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z")
KEY = re.compile(r"[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*\Z")
SECRET = re.compile(r"password|passwd|api[_-]?key|secret|token|credential|private[_-]?key", re.I)
UNIT = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.@:-]*\.service\Z")
RELEASE_MANIFEST = "ops.product.json"
COMPOSE_FILES = {"compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"}
SCAN_SKIP = {"node_modules", "vendor", "venv", "__pycache__", "dist", "build", "logs"}
SCAN_ENTRIES = 2000
SCAN_RESULTS = 60
CONFIG_BYTES = 2 * 1024 * 1024
TOML_WHEEL = "tomlkit-0.13.3-py3-none-any.whl"
TOML_URL = ("https://files.pythonhosted.org/packages/bd/75/"
            "8539d011f6be8e29f339c42e633aae3cb73bffa95dd0f9adec09b9c58e85/" + TOML_WHEEL)
TOML_HASH = "c89c649d79ee40629a9fda55f8ace8c6a1b42deb912b2a8fd8d942ddadb606b0"
MISSING = object()


class OpsError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise OpsError(message)


def valid_id(value):
    require(isinstance(value, str) and ID.fullmatch(value), "ID 必须由小写字母、数字、下划线或连字符组成")
    return value


def good_text(value):
    return isinstance(value, str) and bool(value.strip()) and value.isprintable()


def properties(value, keys, context):
    require(isinstance(value, dict), f"{context} 必须是对象")
    unknown = value.keys() - set(keys.split())
    require(not unknown, f"{context} 包含未知属性 {', '.join(sorted(unknown))}")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"JSON 存在重复属性 {key!r}")
        result[key] = value
    return result


def parse_json(text):
    def invalid_constant(_):
        raise OpsError("JSON 数值必须为有限值")
    return json.loads(text, object_pairs_hook=unique_object, parse_constant=invalid_constant)


def json_text(value):
    return json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n"


def validate(product):
    properties(product, "schema_version id name directory actions configs", "产品清单")
    require(type(product.get("schema_version")) is int and product["schema_version"] == 1, "schema_version 应为 1")
    valid_id(product.get("id"))
    require(good_text(product.get("name")), "请输入产品名称")
    directory = product.get("directory")
    require(good_text(directory) and Path(directory).is_absolute(), "directory 必须是部署目录的绝对路径")
    for section in ("actions", "configs"):
        require(isinstance(product.get(section), dict), f"{section} 必须是对象")
    for name, action in product["actions"].items():
        valid_id(name)
        properties(action, "kind label argv cwd unit change", f"命令 {name}")
        require(good_text(action.get("label")), f"请填写命令 {name} 的名称")
        kind = action.get("kind")
        if kind in ("systemd.status", "systemd.restart"):
            properties(action, "kind label unit", f"命令 {name}")
            require(isinstance(action.get("unit"), str) and
                    UNIT.fullmatch(action["unit"]),
                    f"命令 {name} 需要一个明确的 .service 单元名")
        else:
            require(kind == "command", f"命令 {name} 的 kind 无效")
            properties(action, "kind label argv cwd change", f"命令 {name}")
            argv = action.get("argv")
            require(isinstance(argv, list) and argv and all(
                isinstance(arg, str) and (not arg or arg.isprintable()) for arg in argv
            ) and bool(argv[0]), f"命令 {name} 的 argv 必须是参数数组")
            require("cwd" not in action or good_text(action["cwd"]), f"命令 {name} 的 cwd 无效")
            require(type(action.get("change", True)) is bool, f"命令 {name} 的 change 应为布尔值")
    for name, config in product["configs"].items():
        valid_id(name)
        properties(config, "path format fields", f"配置 {name}")
        require(good_text(config.get("path")), f"请填写配置 {name} 的路径")
        require(config.get("format") in ("json", "toml"), f"配置 {name} 的格式应为 json 或 toml")
        require(isinstance(config.get("fields"), dict), f"配置 {name} 的 fields 必须是对象")
        for key, field in config["fields"].items():
            require(KEY.fullmatch(key), f"字段路径 {key!r} 无效")
            properties(field, "type secret delete", f"字段 {key}")
            require(field.get("type") in tuple(TYPES), f"字段 {key} 的类型应为 {', '.join(TYPES)}")
            for option in ("secret", "delete"):
                require(type(field.get(option, False)) is bool, f"字段 {key} 的 {option} 应为布尔值")
    return product


def atomic_write(path, data, metadata=None):
    fd, temporary = tempfile.mkstemp(prefix=".ops-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            if metadata:
                current = os.fstat(stream.fileno())
                if (current.st_uid, current.st_gid) != (metadata.st_uid, metadata.st_gid):
                    os.fchown(stream.fileno(), metadata.st_uid, metadata.st_gid)
                if hasattr(os, "listxattr"):
                    for attribute in os.listxattr(path):
                        os.setxattr(temporary, attribute, os.getxattr(path, attribute))
                os.fchmod(stream.fileno(), stat.S_IMODE(metadata.st_mode))
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_manifest(product, *, replace=False):
    validate(product)
    MANIFESTS.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = MANIFESTS / (product["id"] + ".json")
    with locked(path):
        exists = path.exists()
        require(replace or not exists, "产品 ID 已登记。更新清单时请使用 --replace")
        if not exists:
            menu_numbers([*registered_ids(), product["id"]])
        atomic_write(path, json_text(product).encode())


def manifest_path(name):
    return MANIFESTS / (valid_id(name) + ".json")


def load(name):
    path = manifest_path(name)
    require(path.is_file(), f"未登记产品 {name}")
    return validate(parse_json(path.read_text(encoding="utf-8")))


def workspace_path(product, path):
    return Path(product["directory"]).joinpath(path).resolve()


def action_plan(product, name):
    action = product["actions"].get(name)
    require(action, f"未登记命令 {name}")
    kind = action["kind"]
    if kind == "command":
        return action["argv"], workspace_path(product, action.get("cwd", ".")), action.get("change", True)
    if kind == "systemd.status":
        return ["systemctl", "--no-pager", "status", "--", action["unit"]], None, False
    prefix = [] if os.geteuid() == 0 else ["sudo"]
    return prefix + ["systemctl", "restart", "--", action["unit"]], None, True


def show_json(value):
    print(json_text(value), end="")


def confirm(message):
    return input(message + " [y/N] ").strip().lower() == "y"


def run_action(product, name, dry_run=False):
    argv, directory, change = action_plan(product, name)
    if dry_run:
        show_json({"argv": argv, "directory": str(directory) if directory else None, "change": change})
        return 0
    if directory:
        print(f"目录 {directory}", flush=True)
    print("$ " + shlex.join(argv), flush=True)
    if change and (not sys.stdin.isatty() or not confirm("执行这个变更？")):
        require(sys.stdin.isatty(), "请在终端确认变更，或先使用 --dry-run 查看命令")
        return 0
    code = subprocess.run(argv, cwd=directory, check=False).returncode
    code = 128 - code if code < 0 else code
    print(f"退出码 {code}")
    return code


def setup_toml():
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    data = subprocess.check_output(["curl", "-q", "-fsSL", "--max-time", "25", TOML_URL])
    require(hashlib.sha256(data).hexdigest() == TOML_HASH, "TOML 组件校验失败")
    atomic_write(STATE / TOML_WHEEL, data)
    print("已安装 TOML 编辑组件")


def parse_config(raw, fmt):
    try:
        if fmt == "json":
            document = parse_json(raw.decode("utf-8"))
            render = json_text
        else:
            wheel = STATE / TOML_WHEEL
            if wheel.is_file() and str(wheel) not in sys.path:
                require(hashlib.sha256(wheel.read_bytes()).hexdigest() == TOML_HASH, "TOML 组件校验失败，请重新运行 ops product setup")
                sys.path.insert(0, str(wheel))
            try:
                import tomlkit
            except ImportError:
                raise OpsError("请先运行 ops product setup 安装 TOML 编辑组件") from None
            document = tomlkit.parse(raw.decode("utf-8"))
            render = tomlkit.dumps
        require(isinstance(document, dict), "配置根节点必须是对象")
    except OpsError as exc:
        # 解析器报错可能包含配置值。配置文件解析错误只显示概况。
        if str(exc).startswith("JSON"):
            raise OpsError("JSON 配置存在重复属性或无效值") from None
        raise
    except (ValueError, UnicodeError):
        raise OpsError(f"{fmt.upper()} 配置格式无效") from None
    return document, render


def plain(value):
    return value.unwrap() if hasattr(value, "unwrap") else value


def path_value(document, key):
    value = document
    for part in key.split("."):
        if not isinstance(value, dict) or part not in value:
            return MISSING
        value = value[part]
    return plain(value)


def check_value(value, kind):
    valid = type(value) is TYPES[kind] or kind == "number" and type(value) is int
    require(valid, f"配置值必须为 {kind}")
    if kind == "number":
        require(type(value) is int or math.isfinite(value), "数值必须为有限值")


def describe_fields(node, prefix=""):
    for part, raw in node.items():
        if not KEY.fullmatch(part) or "." in part:
            continue
        key = prefix + part
        value = plain(raw)
        if isinstance(value, dict):
            yield from describe_fields(value, key + ".")
        else:
            kind = next((name for name, cls in TYPES.items() if type(value) is cls), None)
            if kind:
                yield key, {"type": kind, **({"secret": True} if SECRET.search(key) else {})}


def inspect(path, fmt):
    require(path.is_file(), f"找不到配置文件 {path}")
    document, _ = parse_config(path.read_bytes(), fmt)
    return dict(describe_fields(document))


def config_entry(product, name):
    config = product["configs"].get(name)
    require(config, f"未登记配置 {name}")
    path = workspace_path(product, config["path"])
    require(path.is_file(), f"找不到配置文件 {path}")
    return config, path


def managed_field(config, key):
    field = config["fields"].get(key)
    require(field, f"未登记字段 {key}")
    return field


def preview_value(key, field, value):
    if value is MISSING:
        return {"present": False}
    masked = field.get("secret") or SECRET.search(key)
    try:
        check_value(value, field["type"])
    except OpsError:
        return {"present": True, "type_mismatch": True, **({"secret": True} if masked else {})}
    return {"present": True, "value": "******" if masked else value}


@contextmanager
def locked(path):
    locks = STATE / "locks"
    locks.mkdir(parents=True, exist_ok=True, mode=0o700)
    digest = hashlib.sha256(os.fsencode(path.resolve())).hexdigest()
    fd = os.open(locks / digest, os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, "rb+") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def backup_dir(path):
    return STATE / "backups" / hashlib.sha256(os.fsencode(path)).hexdigest()


def save_config(path, before, after):
    if before == after:
        print("配置无需变更")
        return
    # 避免覆盖其他程序在预览期间做出的更新。
    metadata = path.stat()
    require(path.read_bytes() == before, "配置已被修改，请重新查看后再保存")
    directory = backup_dir(path)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = directory / f"{time.time_ns()}.bak"
    atomic_write(backup, before)
    atomic_write(path, after, metadata)
    print(f"已保存。备份 {backup}")


def change_config(product, name, key, value=MISSING, *, dry_run=False, prompt=False):
    config, path = config_entry(product, name)
    field = managed_field(config, key)
    if value is MISSING:
        require(field.get("delete") is True, f"字段 {key} 未开放删除")
    else:
        check_value(value, field["type"])
    # 预览不创建锁文件或备份。
    with nullcontext() if dry_run else locked(path):
        before, after, original = prepare_change(path, config, key, value)
        show_json({"path": str(path), "key": key, "before": before, "after": after})
        if not dry_run and (not prompt or confirm("保存这个变更？")):
            save_config(path, *original)


def prepare_change(path, config, key, value):
    raw = path.read_bytes()
    document, render = parse_config(raw, config["format"])
    previous = path_value(document, key)
    if value is MISSING:
        require(previous is not MISSING, f"字段 {key} 不存在")
    container = document
    steps = key.split(".")
    for part in steps[:-1]:
        if part not in container:
            container[part] = {}
        require(isinstance(container[part], dict), f"{part} 不是配置对象")
        container = container[part]
    leaf = steps[-1]
    if previous is not MISSING:
        check_value(previous, config["fields"][key]["type"])
    if value is MISSING:
        del container[leaf]
    else:
        container[leaf] = value
    updated = raw if value is not MISSING and previous == value else render(document).encode("utf-8")
    parse_config(updated, config["format"])
    field = config["fields"][key]
    return preview_value(key, field, previous), preview_value(key, field, value), (raw, updated)


def restore_config(product, name, *, dry_run=False, prompt=False):
    config, path = config_entry(product, name)
    backups = sorted(backup_dir(path).glob("*.bak"), reverse=True)
    require(backups, "没有可恢复的备份")
    data = backups[0].read_bytes()
    parse_config(data, config["format"])
    print(f"恢复 {path} ← {backups[0]}")
    if not dry_run:
        with locked(path):
            previous = path.read_bytes()
            if not prompt or confirm("恢复整份配置？"):
                save_config(path, previous, data)


def config_fields(product, name, key=None):
    config, path = config_entry(product, name)
    document, _ = parse_config(path.read_bytes(), config["format"])
    keys = {key: managed_field(config, key)} if key is not None else config["fields"]
    result = {item: preview_value(item, field, path_value(document, item)) for item, field in keys.items()}
    show_json(result[key] if key is not None else result)


def read_manifest(path, directory=None):
    product = parse_json(path.read_text(encoding="utf-8"))
    if directory is not None:
        require(isinstance(product, dict), "产品清单必须是对象")
        product["directory"] = str(deployment_path(directory))
    return validate(product)


def import_product(path, *, dry_run=False, replace=False, directory=None):
    product = read_manifest(path, directory)
    require(replace or not manifest_path(product["id"]).exists(), "产品 ID 已登记。更新清单时请使用 --replace")
    summary = {"id": product["id"], "name": product["name"], "directory": product["directory"],
               "actions": {}, "configs": {}}
    for name in product["actions"]:
        argv, directory, change = action_plan(product, name)
        summary["actions"][name] = {"argv": argv, "directory": str(directory) if directory else None, "change": change}
    for name in product["configs"]:
        config, target = config_entry(product, name)
        document, _ = parse_config(target.read_bytes(), config["format"])
        for key, field in config["fields"].items():
            value = path_value(document, key)
            if value is not MISSING:
                try:
                    check_value(value, field["type"])
                except OpsError:
                    raise OpsError(f"配置 {name} 的字段 {key} 与登记类型不符") from None
        summary["configs"][name] = {"path": str(target), "fields": list(config["fields"])}
    if dry_run:
        show_json(summary)
    else:
        write_manifest(product, replace=replace)
        print(f"已登记 {product['name']}")


def remove_product(name):
    path = manifest_path(name)
    with locked(path):
        require(path.is_file(), f"未登记产品 {name}")
        path.unlink()
    print(f"已移除产品登记 {name}")


def registered_ids():
    return sorted(path.stem for path in MANIFESTS.glob("*.json") if ID.fullmatch(path.stem))


def products():
    for name in registered_ids():
        try:
            yield load(name)
        except (OpsError, ValueError, OSError) as exc:
            print(f"无法读取产品 {name} 的清单：{exc}", file=sys.stderr)


def menu_numbers(ids):
    if not ids:
        return {}
    with locked(MENU_NUMBERS):
        numbers = parse_json(MENU_NUMBERS.read_text(encoding="utf-8")) if MENU_NUMBERS.exists() else {}
        require(isinstance(numbers, dict) and all(
            ID.fullmatch(key) and type(value) is int and value >= FIRST_PRODUCT_NUMBER
            for key, value in numbers.items()
        ) and len(set(numbers.values())) == len(numbers), "产品菜单编号记录无效")
        next_number = max(numbers.values(), default=FIRST_PRODUCT_NUMBER - 1) + 1
        updated = False
        for name in ids:
            if name not in numbers:
                numbers[name] = next_number
                next_number += 1
                updated = True
        if updated:
            atomic_write(MENU_NUMBERS, json_text(numbers).encode())
    return numbers


def format_for(path, override=None):
    fmt = override or Path(path).suffix[1:].lower()
    require(fmt in ("toml", "json"), "请选择 TOML 或 JSON 配置")
    return fmt


def deployment_path(value):
    path = Path(value).expanduser().resolve()
    require(good_text(str(path)) and path.is_dir(), "请输入服务器上存在的部署目录")
    return path


def probe(argv, failure):
    try:
        result = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, encoding="utf-8",
                                errors="replace", timeout=8, check=True)
    except (OSError, subprocess.SubprocessError):
        raise OpsError(failure) from None
    return result.stdout


def service_names(query):
    output = probe(["systemctl", "--no-pager", "--no-legend", "--type=service", "list-unit-files"],
                   "无法列出 systemd 服务，请检查本机是否使用 systemd")
    names = [line.split()[0] for line in output.splitlines() if line.strip()]
    return sorted({name for name in names if UNIT.fullmatch(name) and query.casefold() in name.casefold()})


def systemd_source(unit):
    if not unit.endswith(".service"):
        unit += ".service"
    require(UNIT.fullmatch(unit), "请输入一个明确的 systemd 服务名")
    output = probe(["systemctl", "--no-pager", "show", "--property",
                    "Id,LoadState,WorkingDirectory,ConfigurationDirectory,RootDirectory,RootImage", "--", unit],
                   "无法读取这个 systemd 服务，请检查服务名和 systemd 是否可用")
    props = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    require(props.get("LoadState") == "loaded", f"未找到可用的 systemd 服务 {unit}")
    canonical = props.get("Id", unit)
    require(UNIT.fullmatch(canonical), "未能识别 systemd 服务的实际名称")
    work = Path(props.get("WorkingDirectory", "").lstrip("-"))
    roots = []
    # A service inside its own root does not see the host's filesystem paths.
    if not props.get("RootImage") and props.get("RootDirectory", "") in ("", "/"):
        if good_text(str(work)) and work.is_absolute() and work != Path("/") and work.is_dir():
            roots.append(work.resolve())
        etc = Path("/etc").resolve()
        configs = props.get("ConfigurationDirectory", "").split()
        for name in configs[:12] + [canonical[:-len(".service")]]:
            if re.fullmatch(r"[A-Za-z0-9_.@-]+(?:/[A-Za-z0-9_.@-]+)*", name) and not set(name.split("/")) & {".", ".."}:
                path = etc / name
                if path.is_dir():
                    target = path.resolve()
                    if etc in target.parents:
                        roots.append(target)
    return canonical, roots


def compose_projects():
    output = probe(["docker", "compose", "ls", "--all", "--format", "json"],
                   "无法列出 Compose 项目，请检查 Docker Compose 和 Docker 访问权限")
    try:
        items = json.loads(output)
    except ValueError:
        raise OpsError("无法识别 Compose 返回的项目列表") from None
    require(isinstance(items, list), "无法识别 Compose 返回的项目列表")
    projects = {}
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("Name"), str):
            continue
        if not ID.fullmatch(item["Name"]):
            continue
        files = item.get("ConfigFiles")
        paths = files.split(",") if isinstance(files, str) and files else []
        projects[item["Name"]] = paths
    return projects


def config_candidate(path):
    suffix = path.suffix.lower()
    if path.name == RELEASE_MANIFEST:
        return None
    if suffix in (".json", ".toml"):
        return suffix[1:]
    if path.name == ".env":
        return "env"
    if suffix in (".env", ".ini", ".conf", ".yaml", ".yml"):
        return suffix[1:]
    return None


def scan_deployments(roots):
    configurations, compose_files, scripts = {}, set(), set()
    scanned, limited = 0, False
    pending = [(root, 0) for root in dict.fromkeys(roots) if root != Path("/")]
    visited = set()
    while pending and scanned < SCAN_ENTRIES:
        folder, depth = pending.pop(0)
        if folder in visited:
            continue
        visited.add(folder)
        try:
            with os.scandir(folder) as entries:
                for entry in entries:
                    scanned += 1
                    if scanned > SCAN_ENTRIES:
                        limited = True
                        break
                    if not good_text(entry.name) or entry.name.startswith(".") and entry.name != ".env":
                        continue
                    path = Path(entry.path)
                    if entry.is_dir(follow_symlinks=False):
                        if depth < 3 and entry.name not in SCAN_SKIP:
                            pending.append((path, depth + 1))
                        continue
                    if not entry.is_file(follow_symlinks=False):
                        continue
                    if path.name in COMPOSE_FILES:
                        compose_files.add(path)
                    elif path.suffix == ".sh":
                        scripts.add(path)
                    else:
                        fmt = config_candidate(path)
                        if fmt:
                            configurations[path] = fmt
        except OSError:
            continue
    return configurations, compose_files, scripts, limited or bool(pending)


def compose_actions(files, project=None):
    cwd = str(Path(files[0]).parent)
    base = ["docker", "compose", "--project-directory", cwd]
    if project:
        base += ["--project-name", project]
    for path in files:
        base += ["-f", str(path)]
    result = {}
    for key, label, suffix in (("status", "状态", ["ps", "--all"]),
                               ("logs", "最近日志", ["logs", "--tail", "100"])):
        result[key] = {"kind": "command", "label": f"Compose {label} / {project or files[0]}",
                       "argv": base + suffix, "cwd": cwd, "change": False}
    return result


def discover(directory=None, *, unit=None, compose=None, configs=(), projects=None):
    require(directory is not None or unit or compose, "请提供部署目录、systemd 服务名或 Compose 项目名")
    require(not (unit and compose), "请只选择一种服务来源")
    roots = []
    warnings = []
    actions = {}
    path = deployment_path(directory) if directory is not None else None
    require(path != Path("/"), "请选择具体的产品目录，避免扫描整个系统")
    if path is not None:
        roots.append(path)
    if unit:
        unit, service_roots = systemd_source(unit)
        roots.extend(service_roots)
        actions.update({
            "status": {"kind": "systemd.status", "label": f"服务状态 / {unit}", "unit": unit},
            "logs": {"kind": "command", "label": f"最近日志 / {unit}",
                     "argv": ["journalctl", "--no-pager", "-u", unit, "-n", "100"],
                     "cwd": "/", "change": False},
            "restart": {"kind": "systemd.restart", "label": f"重启服务 / {unit}", "unit": unit},
        })
    if compose:
        projects = compose_projects() if projects is None else projects
        require(compose in projects, f"未找到 Compose 项目 {compose!r}")
        files = projects[compose]
        if files and all(good_text(file) and Path(file).is_absolute() and Path(file).is_file()
                         for file in files):
            actions.update(compose_actions(files, compose))
            roots.extend(Path(file).parent.resolve() for file in files[:12])
        else:
            warnings.append("找不到 Compose 登记的本地部署文件。如已迁移，请提供现在的部署目录。")
    path = path or next(iter(roots), Path("/"))
    files, compose_files, scripts, limited = scan_deployments(roots)
    if limited or max(len(files), len(compose_files), len(scripts)) > SCAN_RESULTS:
        warnings.append("发现结果已达到上限，可选择更具体的目录或直接补充绝对路径。")
    if not roots:
        warnings.append("没有可扫描的产品目录，可以添加配置的绝对路径。")
    if not actions and compose_files:
        for index, file in enumerate(sorted(compose_files)[:12], 1):
            for key, action in compose_actions([file]).items():
                actions[f"compose-{index}-{key}"] = action
        warnings.append("目录中发现的 Compose 命令基于单个文件；若上线时用了项目名或覆盖文件，请从 Compose 项目入口发现。")
    candidates = dict(list(sorted(files.items()))[:SCAN_RESULTS])
    for item in configs:
        target = Path(item).expanduser().resolve()
        fmt = config_candidate(target)
        require(good_text(str(target)) and target.is_file() and fmt,
                "补充的配置应为存在的 JSON、TOML、YAML、INI、CONF 或 env 文件")
        candidates[target] = fmt
    release = path / RELEASE_MANIFEST
    return {"directory": str(path), "systemd_unit": unit, "compose_project": compose,
            "release_manifest": str(release) if path != Path("/") and release.is_file() else None,
            "actions": actions,
            "configs": [{"path": str(target), "format": fmt, "editable": fmt in ("json", "toml")}
                        for target, fmt in candidates.items()],
            "scripts": [str(file) for file in sorted(scripts)[:SCAN_RESULTS]], "warnings": warnings}


def ask(label):
    return input(label + " > ").strip()


def choose(title, options, *, numbered=()):
    entries = dict(enumerate(options, start=1))
    entries.update(numbered)
    print(f"\n{title}")
    for index, (label, _) in entries.items():
        print(f"  [{index:2}]  {label}")
    print("  [ 0]  返回")
    choice = ask("选择")
    if choice == "0" or not choice:
        return None
    require(choice.isascii() and choice.isdecimal() and len(choice) <= 9
            and int(choice) in entries, "请选择菜单中的编号")
    return entries[int(choice)][1]


def choose_many(title, entries, default=()):
    print(f"\n{title}")
    for index, (label, key) in enumerate(entries, 1):
        print(f"  [{index:2}]  {'* ' if key in default else '  '}{label}")
    raw = ask("输入编号（逗号分隔）；0 跳过，回车保留默认选择")
    if not raw:
        return list(default)
    if raw == "0":
        return []
    indexes = [item.strip() for item in raw.replace("，", ",").split(",")]
    require(all(item.isascii() and item.isdecimal() and len(item) <= 3 and
                1 <= int(item) <= len(entries) for item in indexes), "请使用显示的编号")
    return [entries[index - 1][1] for index in dict.fromkeys(map(int, indexes))]


def discovery_id(value):
    return re.sub(r"[^a-z0-9_-]+", "-", value.lower()).strip("-_")[:60] or "product"


def discovery_manifest(report, name, label, actions, configs):
    product = {"schema_version": 1, "id": name, "name": label, "directory": report["directory"],
               "actions": {key: report["actions"][key] for key in actions}, "configs": {}}
    for path, fmt, fields in configs:
        base = discovery_id(Path(path).stem)
        key, index = base, 2
        while key in product["configs"]:
            key = f"{base}-{index}"
            index += 1
        product["configs"][key] = {"path": path, "format": fmt, "fields": fields}
    return validate(product)


def discovery_fields(path, fmt):
    with Path(path).open("rb") as stream:
        raw = stream.read(CONFIG_BYTES + 1)
    require(len(raw) <= CONFIG_BYTES, "配置文件超过 2 MiB，请在产品里手动绑定需要管理的字段")
    document, _ = parse_config(raw, fmt)
    return dict(describe_fields(document))


def discovery_menu():
    source = choose("从哪里发现产品？", [("本机 systemd 服务", "systemd"), ("已部署 Compose 项目", "compose"),
                                      ("部署目录 / 产品发布清单", "directory")])
    if not source:
        return
    unit, compose, projects, directory = None, None, None, None
    if source == "systemd":
        query = ask("服务名或关键词（例如 nginx）")
        if not query:
            return
        if UNIT.fullmatch(query):
            unit = query
        else:
            names = service_names(query)
            require(names, "没有匹配的服务")
            unit = choose("选择服务（最多显示 30 项）", [(item, item) for item in names[:30]])
            if not unit:
                return
    elif source == "compose":
        projects = compose_projects()
        require(projects, "没有发现已部署的 Compose 项目")
        names = list(sorted(projects))
        if len(names) > 30:
            query = ask("用项目名关键词筛选")
            names = [name for name in names if query.lower() in name]
        require(names, "没有匹配的 Compose 项目")
        compose = choose("选择 Compose 项目（最多显示 30 项）", [(item, item) for item in names[:30]])
        if not compose:
            return
    else:
        directory = ask("部署目录")
        if not directory:
            return
    report = discover(directory, unit=unit, compose=compose, projects=projects)
    for warning in report["warnings"]:
        print(warning)
    if report["release_manifest"]:
        path = Path(report["release_manifest"])
        print(f"发现产品随包提供的清单：{path}")
        if confirm("查看发布清单的登记预览？"):
            import_product(path, dry_run=True, directory=report["directory"])
            if confirm("登记以上清单？"):
                import_product(path, directory=report["directory"])
            return
    print(f"部署目录：{report['directory']}")
    nice_name = report["systemd_unit"] or report["compose_project"] or Path(report["directory"]).name
    if nice_name.endswith(".service") and unit:
        nice_name = nice_name[:-len(".service")]
    suggested = discovery_id(nice_name)
    name = valid_id(ask(f"产品 ID（默认 {suggested}）") or suggested)
    require(not manifest_path(name).exists(), "产品 ID 已登记，请用另一个 ID")
    label = ask(f"产品名称（默认 {nice_name}）") or nice_name
    action_entries = []
    for key, action in report["actions"].items():
        argv, _, change = action_plan({"actions": report["actions"], "directory": report["directory"]}, key)
        action_entries.append((f"{action['label']} {'[变更] ' if change else ''} $ {shlex.join(argv)}", key))
    selected_actions = choose_many("选择要纳入菜单的命令（* 默认登记）", action_entries,
                                   [key for _, key in action_entries if key != "restart"]) if action_entries else []
    editable = [(entry["path"], entry["format"]) for entry in report["configs"] if entry["editable"]]
    other = [entry["path"] for entry in report["configs"] if not entry["editable"]]
    if other:
        print("发现以下文件（目前只编辑 JSON / TOML）：\n  " + "\n  ".join(other))
    selected = choose_many("选择要绑定的配置文件", [(path, (path, fmt)) for path, fmt in editable]) if editable else []
    seen = {path for path, _ in selected}
    while True:
        extra = ask("补充其他配置的绝对路径（回车完成）")
        if not extra:
            break
        try:
            target = Path(extra).expanduser()
            require(target.is_absolute(), "请输入绝对路径")
            target = target.resolve()
            fmt = format_for(target)
            require(target.is_file(), "找不到该配置文件")
        except (OpsError, OSError, ValueError) as exc:
            print(f"无法绑定：{exc}")
            continue
        if str(target) not in seen:
            selected.append((str(target), fmt))
            seen.add(str(target))
    configs = []
    for path, fmt in selected:
        try:
            fields = discovery_fields(path, fmt)
        except (OpsError, OSError, ValueError, RecursionError) as exc:
            print(f"已跳过 {path}：{exc}")
            continue
        if len(fields) > 100:
            print("先显示前 100 个字段，其余字段可以在产品配置菜单中登记。")
        entries = []
        for key, field in list(fields.items())[:100]:
            sensitivity = " [敏感]" if field.get("secret") else ""
            entries.append((f"{key} ({field['type']}){sensitivity}", key))
        keys = choose_many(f"{path}：选择允许管理的字段", entries) if entries else []
        configs.append((path, fmt, {key: fields[key] for key in keys}))
    product = discovery_manifest(report, name, label, selected_actions, configs)
    if report["scripts"]:
        print("发现的脚本（可在产品菜单用「新增命令」登记）：\n  " + "\n  ".join(report["scripts"]))
    print(f"准备登记 {label}：{len(selected_actions)} 项命令、{len(configs)} 个配置文件")
    if confirm("保存到 ops 产品菜单？"):
        write_manifest(product)
        product_menu(name)


def product_new():
    name = valid_id(ask("产品 ID"))
    product = {"schema_version": 1, "id": name, "name": ask("产品名称"),
               "directory": ask("部署目录的绝对路径"), "actions": {}, "configs": {}}
    write_manifest(product)
    print(f"已登记 {product['name']}，可继续添加命令和配置")


def action_add(product):
    name = valid_id(ask("命令 ID"))
    require(name not in product["actions"], f"命令 {name} 已登记")
    label = ask("显示名称")
    kind = choose("命令类型", [("systemd 服务状态", "systemd.status"),
                             ("systemd 重启服务", "systemd.restart"), ("自定义命令", "command")])
    if not kind:
        return
    action = {"kind": kind, "label": label}
    if kind == "command":
        print("输入程序和参数。可用引号包住带空格的参数，例如 docker compose ps")
        action["argv"] = shlex.split(ask("命令"))
        cwd = ask("工作目录（回车使用部署目录）")
        if cwd:
            action["cwd"] = cwd
        action["change"] = not confirm("这个命令是只读查询？")
    else:
        unit = ask("服务单元名，例如 nginx.service")
        action["unit"] = unit
    product["actions"][name] = action
    write_manifest(product, replace=True)
    print(f"已登记命令 {label}")


def bind_config(product):
    name = valid_id(ask("配置 ID"))
    require(name not in product["configs"], f"配置 {name} 已登记")
    source = ask("已有配置文件路径（相对于部署目录或填写绝对路径）")
    fmt = format_for(source)
    fields = inspect(workspace_path(product, source), fmt)
    selected = {}
    if fields:
        show_json(fields)
        keys = ask("输入要管理的字段，逗号分隔（回车暂不登记）")
        for key in (item.strip() for item in keys.split(",") if item.strip()):
            require(key in fields, f"未识别字段 {key}")
            selected[key] = fields[key]
    product["configs"][name] = {"path": source, "format": fmt, "fields": selected}
    write_manifest(product, replace=True)
    print(f"已绑定配置 {name}")


def add_field(product, name):
    config, path = config_entry(product, name)
    key = ask("字段路径，例如 server.port")
    require(KEY.fullmatch(key), f"字段路径 {key!r} 无效")
    fields = inspect(path, config["format"])
    if key in fields:
        kind = fields[key]["type"]
        print(f"读取到类型 {kind}")
    else:
        kind = choose("新字段类型", [(kind, kind) for kind in TYPES])
        if not kind:
            return
    secret = bool(SECRET.search(key)) or confirm("将值作为机密隐藏？")
    delete = confirm("开放删除此字段？")
    config["fields"][key] = {"type": kind, "secret": secret, "delete": delete}
    write_manifest(product, replace=True)
    print(f"已登记字段 {key}")


def input_secret():
    require(sys.stdin.isatty(), "请在终端输入机密值，或通过 --stdin 传入 JSON")
    return getpass.getpass("输入机密值（JSON，不回显） > ")


def change_field_menu(product, name, delete):
    config, _ = config_entry(product, name)
    key = choose("选择字段", [(key, key) for key, field in config["fields"].items()
                               if not delete or field.get("delete")])
    if not key:
        return
    if delete:
        change_config(product, name, key, prompt=True)
        return
    field = managed_field(config, key)
    if field.get("secret") or SECRET.search(key):
        value = parse_json(input_secret())
    else:
        raw = ask("新值（字符串直接输入，其余类型填写 JSON）")
        value = raw if field["type"] == "string" else parse_json(raw)
    change_config(product, name, key, value, prompt=True)


def unbind(product, section, name):
    if confirm(f"解除登记 {name}？"):
        del product[section][name]
        write_manifest(product, replace=True)
        print("已解除登记")


def config_menu(product_id, name):
    while True:
        product = load(product_id)
        config = product["configs"].get(name)
        require(config, f"未登记配置 {name}")
        path = workspace_path(product, config["path"])
        options = [("查看字段", "get"), ("添加或修改字段的值", "set"), ("删除已开放删除的字段", "delete"),
                   ("恢复最近备份", "restore"), ("登记字段或修改其权限", "field"), ("解除配置登记", "unbind")]
        choice = choose(f"{product['name']} / {name} · {path}", options)
        if choice is None:
            return
        try:
            if choice == "get":
                config_fields(product, name)
            elif choice in ("set", "delete"):
                change_field_menu(product, name, choice == "delete")
            elif choice == "restore":
                restore_config(product, name, prompt=True)
            elif choice == "field":
                add_field(product, name)
            elif choice == "unbind" and confirm(f"解除配置登记 {name}？"):
                del product["configs"][name]
                write_manifest(product, replace=True)
                return
        except (OpsError, OSError, ValueError) as exc:
            print(f"操作失败：{exc}", file=sys.stderr)


def product_menu(product_id):
    while True:
        product = load(product_id)
        options = [("新增命令", ("action", None)), ("绑定已有配置", ("bind", None)),
                   ("导出产品清单", ("export", None)), ("解除命令登记", ("remove-action", None)),
                   ("移除产品登记", ("remove", None))]
        options += [(action["label"], ("run", name)) for name, action in product["actions"].items()]
        options += [(f"配置 / {name}", ("config", name)) for name in product["configs"]]
        choice = choose(product["name"], options)
        if not choice:
            return
        operation, name = choice
        if operation == "action":
            action_add(product)
        elif operation == "bind":
            bind_config(product)
        elif operation == "export":
            destination = Path(ask("导出位置，例如 ./product.json")).expanduser()
            with destination.open("x", encoding="utf-8") as stream:
                stream.write(json_text(product))
            print(f"已导出至 {destination}")
        elif operation == "remove-action":
            name = choose("已登记命令", [(label["label"], key) for key, label in product["actions"].items()])
            if name:
                unbind(product, "actions", name)
        elif operation == "remove":
            if confirm(f"移除 {product['name']} 在 ops 里的登记？"):
                remove_product(product_id)
                return
        elif operation == "run":
            run_action(product, name)
        else:
            config_menu(product_id, name)


def menu():
    while True:
        options = [("发现已部署产品", ("discover", None)), ("导入产品清单", ("import", None)),
                   ("手动新增产品", ("new", None)), ("安装 TOML 编辑组件", ("setup", None))]
        registered = list(products())
        numbers = menu_numbers([item["id"] for item in registered])
        numbered = sorted((numbers[item["id"]], (item["name"], ("open", item["id"])))
                          for item in registered)
        try:
            choice = choose("产品管理", options, numbered=numbered)
            if not choice:
                return
            operation, name = choice
            if operation == "discover":
                discovery_menu()
            elif operation == "new":
                product_new()
            elif operation == "import":
                path = Path(ask("产品清单 JSON 路径")).expanduser()
                directory = ask("覆盖部署目录（回车使用清单中的目录）") if path.name != RELEASE_MANIFEST else (
                    ask(f"部署目录（默认 {path.parent.resolve()}）") or path.parent
                )
                import_product(path, dry_run=True, directory=directory or None)
                if confirm("导入以上产品？"):
                    import_product(path, directory=directory or None)
            elif operation == "setup":
                setup_toml()
            else:
                product_menu(name)
        except (OpsError, OSError, ValueError, subprocess.CalledProcessError) as exc:
            print(f"操作失败：{exc}", file=sys.stderr)


def parser():
    root = argparse.ArgumentParser(prog="ops")
    families = root.add_subparsers(dest="family", required=True)
    product = families.add_parser("product", help="管理产品清单")
    products_cli = product.add_subparsers(dest="operation", required=True)
    for name in ("setup", "list", "menu"):
        products_cli.add_parser(name)
    for name in ("export", "remove"):
        products_cli.add_parser(name).add_argument("id")
    command = products_cli.add_parser("discover", help="从服务器发现产品，输出 JSON")
    command.add_argument("directory", nargs="?", type=Path, help="部署目录")
    source = command.add_mutually_exclusive_group()
    source.add_argument("--unit", metavar="SERVICE", help="已部署的 systemd 服务名")
    source.add_argument("--compose", metavar="PROJECT", help="已部署的 Compose 项目名")
    command.add_argument("--config", type=Path, action="append", default=[],
                         help="补充扫描目录外的配置路径（可多次指定）")
    command.add_argument("--manifest", metavar="ID", help="输出可导入的产品清单草稿")
    command.add_argument("--name", help="草稿中的产品显示名（与 --manifest 一起使用）")
    template = products_cli.add_parser("template")
    template.add_argument("name", choices=["aistudy"])
    for name in ("import", "validate"):
        command = products_cli.add_parser(name)
        command.add_argument("file", type=Path)
        command.add_argument("--directory", type=Path, help="按实际部署目录解析发布清单中的相对路径")
        if name == "import":
            command.add_argument("--dry-run", action="store_true")
            command.add_argument("--replace", action="store_true")
    command = products_cli.add_parser("run")
    command.add_argument("id")
    command.add_argument("action")
    command.add_argument("--dry-run", action="store_true")

    config = families.add_parser("config", help="管理配置字段")
    configs_cli = config.add_subparsers(dest="operation", required=True)
    command = configs_cli.add_parser("inspect")
    command.add_argument("path", type=Path)
    command.add_argument("--format", choices=["json", "toml"])
    command.add_argument("--keys-only", action="store_true", help="只输出字段名和类型（默认）")
    for name in ("list", "get", "set", "delete", "restore"):
        command = configs_cli.add_parser(name)
        command.add_argument("id")
        command.add_argument("config")
        if name in ("get", "set", "delete"):
            command.add_argument("key")
        if name in ("set", "delete", "restore"):
            command.add_argument("--dry-run", action="store_true")
        if name == "set":
            command.add_argument("value", nargs="?", metavar="JSON")
            command.add_argument("--stdin", action="store_true")
    return root


def cli(options):
    operation = options.operation
    if options.family == "product":
        if operation == "menu":
            menu()
        elif operation == "setup":
            setup_toml()
        elif operation == "list":
            show_json([{"id": item["id"], "name": item["name"]} for item in products()])
        elif operation == "template":
            print(Path(__file__).with_name("aistudy.product.json").read_text(encoding="utf-8"), end="")
        elif operation == "discover":
            require(not options.name or options.manifest, "--name 需要同时指定 --manifest")
            report = discover(options.directory, unit=options.unit, compose=options.compose, configs=options.config)
            if options.manifest:
                explicit = {str(path.expanduser().resolve()) for path in options.config}
                configs = [(item["path"], item["format"], {}) for item in report["configs"]
                           if item["editable"] and item["path"] in explicit]
                actions = [key for key in report["actions"] if key != "restart"]
                show_json(discovery_manifest(report, options.manifest, options.name or options.manifest, actions, configs))
            else:
                show_json(report)
        elif operation == "validate":
            read_manifest(options.file, options.directory)
            print("清单结构有效")
        elif operation == "import":
            import_product(options.file, dry_run=options.dry_run, replace=options.replace, directory=options.directory)
        elif operation == "export":
            show_json(load(options.id))
        elif operation == "remove":
            remove_product(options.id)
        else:
            return run_action(load(options.id), options.action, options.dry_run)
        return 0
    if operation == "inspect":
        show_json(inspect(options.path, format_for(options.path, options.format)))
        return 0
    product = load(options.id)
    if operation == "list":
        config_fields(product, options.config)
    elif operation == "get":
        config_fields(product, options.config, options.key)
    elif operation == "restore":
        restore_config(product, options.config, dry_run=options.dry_run)
    elif operation == "delete":
        change_config(product, options.config, options.key, dry_run=options.dry_run)
    else:
        config, _ = config_entry(product, options.config)
        field = managed_field(config, options.key)
        secret = field.get("secret") or SECRET.search(options.key)
        if secret:
            require(options.value is None, "机密值请用 --stdin 或终端隐藏输入")
        require(not options.stdin or options.value is None, "--stdin 和命令行值只能使用其一")
        raw = sys.stdin.read() if options.stdin else options.value
        if raw is None and secret:
            raw = input_secret()
        require(raw is not None, "请提供 JSON 值或 --stdin")
        try:
            value = parse_json(raw)
        except (ValueError, OpsError):
            raise OpsError("请提供有效的 JSON 值") from None
        change_config(product, options.config, options.key, value, dry_run=options.dry_run)
    return 0


if __name__ == "__main__":
    try:
        require(sys.version_info >= (3, 8), "产品管理需要 Python 3.8 或以上版本")
        sys.exit(cli(parser().parse_args()))
    except EOFError:
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
    except (OpsError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"操作失败：{error}", file=sys.stderr)
        sys.exit(1)
