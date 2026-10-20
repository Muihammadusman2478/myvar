appcount() {
    local python_bin="" candidate

    for candidate in python3 python python3.{20..0}; do
        if command -v "$candidate" >/dev/null 2>&1 &&
            "$candidate" -c \
                'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' \
                >/dev/null 2>&1; then
            python_bin="$candidate"
            break
        fi
    done

    if [[ -z "$python_bin" ]]; then
        echo "Python 3.6 or newer was not found in PATH."
        return 1
    fi

    "$python_bin" - <<'PY'
import configparser
import pathlib
import re
import subprocess
from collections import defaultdict

facts_dir = pathlib.Path("/etc/ansible/facts.d")
hostname = subprocess.check_output(
    ["hostname", "-s"], universal_newlines=True
).strip()

base = pathlib.Path("/home") / "{}.cloudwaysapps.com".format(hostname)

if not base.is_dir():
    print("Applications directory not found: {}".format(base))
    raise SystemExit(1)

base = base.resolve()

def read_facts(path):
    parser = configparser.ConfigParser(
        interpolation=None,
        strict=False,
        default_section="__APP_REPORT_DEFAULTS__"
    )
    try:
        content = path.read_text()
        parser.read_string("[__APP_REPORT_DEFAULTS__]\n" + content)
    except (OSError, configparser.Error) as error:
        print("Cannot read {}: {}".format(path, error))
        raise SystemExit(1)
    return parser

apps_facts = read_facts(facts_dir / "applications.fact")
server_facts = read_facts(facts_dir / "server_settings.fact")

def server_value(key, default=""):
    if key in server_facts.defaults():
        return server_facts.defaults()[key].strip()

    for section in server_facts.sections():
        if server_facts.has_option(section, key):
            return server_facts.get(section, key).strip()

    return default

def app_value(section, key):
    value = apps_facts.get(section, key, fallback="Unknown")
    return value.strip() or "Unknown"

multi_php_value = server_value("multi_app_php")
multi_php = multi_php_value.lower() == "yes"
server_stack = server_value("stack_version", "Unknown")

try:
    result = subprocess.run(
        ["php", "--version"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        timeout=15
    )
    php_version = (
        result.stdout.splitlines()[0]
        if result.returncode == 0 and result.stdout.strip()
        else "Unavailable"
    )
except (OSError, subprocess.TimeoutExpired):
    php_version = "Unavailable"

stack_names = {
    "v1": "Hybrid Stack",
    "v2": "Lightning Stack",
}

type_names = {
    "phpstack": "Custom PHP",
    "wordpress": "WordPress",
    "woocommerce": "woocommerce",
    "laravel": "Laravel",
    "magento": "Magento",
}

groups = defaultdict(list)
seen = set()

for entry in sorted(base.iterdir()):
    try:
        if not entry.is_dir():
            continue

        target = entry.resolve()

        # Restrict results to apps directly inside this server directory.
        if target.parent != base:
            continue

        # Count an original folder and its symlink aliases only once.
        if target in seen:
            continue

        if not (
            (target / "conf").is_dir()
            or (target / "public_html").is_dir()
        ):
            continue

        seen.add(target)
    except (OSError, RuntimeError):
        continue

    app_name = target.name
    default_url = "Unknown"
    app_type = "Unknown"

    try:
        nginx = (target / "conf/server.nginx").read_text()
        match = re.search(
            r"^\s*server_name\s+([^;]+);",
            nginx,
            flags=re.MULTILINE
        )

        if match:
            default_host = next(
                (
                    host for host in match.group(1).split()
                    if host.lower().endswith(".cloudwaysapps.com")
                ),
                None
            )

            if default_host:
                default_url = "https://{}".format(default_host)
                prefix = default_host.split("-", 1)[0].lower()
                app_type = type_names.get(prefix, prefix)

    except (OSError, UnicodeError):
        pass

    stack = app_value("stack", "stack_{}".format(app_name))

    if stack == "Unknown" and server_stack != "Unknown":
        stack = "{} (server default)".format(
            stack_names.get(server_stack, server_stack)
        )
    else:
        stack = stack_names.get(stack, stack)

    row = [
        app_name,
        default_url,
        app_value("ssh_status", "ssh_{}".format(app_name)),
        app_value("app_state", "state_{}".format(app_name)),
        stack,
    ]

    if multi_php:
        row.append(app_value("app_php_version", app_name))

    groups[app_type].append(row)

print("Total applications: {}".format(
    sum(len(rows) for rows in groups.values())
))

print("\nApplication count by type:")
for app_type in sorted(groups, key=str.casefold):
    print("{}: {}".format(app_type, len(groups[app_type])))

print("\nServer PHP: {}".format(php_version))
print("multi_app_php: {}".format(multi_php_value or "not set"))

headers = [
    "app_name",
    "Default URL",
    "ssh_status",
    "app_state",
    "stack",
]

if multi_php:
    headers.append("app_php_version")

for app_type in sorted(groups, key=str.casefold):
    rows = sorted(groups[app_type])

    print("\n=== {} ({} applications) ===\n".format(
        app_type, len(rows)
    ))

    widths = [
        max(len(str(row[i])) for row in [headers] + rows)
        for i in range(len(headers))
    ]

    def print_row(row):
        print(" | ".join(
            str(value).ljust(widths[i])
            for i, value in enumerate(row)
        ))

    print_row(headers)
    print("-+-".join("-" * width for width in widths))

    for row in rows:
        print_row(row)
PY
}
