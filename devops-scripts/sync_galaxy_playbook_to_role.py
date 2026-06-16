#!/usr/bin/env python3
"""
Sync current Galaxy playbook into reusable galaxy_deployment role.

Source:
  galaxy.yml

Generated:
  roles/galaxy_deployment/tasks/*.yml
  roles/galaxy_deployment/defaults/main.yml
  roles/galaxy_deployment/handlers/main.yml
  playbooks/galaxy-role.yml

Source of truth remains galaxy.yml.

Usage:
  ./devops-scripts/sync_galaxy_playbook_to_role.py

or:
  ./scripts/sync_galaxy_playbook_to_role.py

Then validate:
  ansible-playbook -i hosts playbooks/galaxy-role.yml --syntax-check
"""

from pathlib import Path
import sys
import yaml


PROJECT_ROOT = Path(__file__).resolve().parents[1]

SOURCE_PLAYBOOK = PROJECT_ROOT / "galaxy.yml"
ROLE_DIR = PROJECT_ROOT / "roles" / "galaxy_deployment"
TASKS_DIR = ROLE_DIR / "tasks"
DEFAULTS_DIR = ROLE_DIR / "defaults"
HANDLERS_DIR = ROLE_DIR / "handlers"
PLAYBOOKS_DIR = PROJECT_ROOT / "playbooks"
ROLE_PLAYBOOK = PLAYBOOKS_DIR / "galaxy-role.yml"

GENERATED_HEADER = """---
# =====================================================================
# AUTO-GENERATED FILE
# Source: galaxy.yml
# Do not edit manually unless you disable the sync generator.
# =====================================================================

"""


def fail(message: str):
    print(f"[ERROR] {message}", file=sys.stderr)
    sys.exit(1)


def write_yaml(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)

    with path.open("w", encoding="utf-8") as f:
        f.write(GENERATED_HEADER)
        yaml.safe_dump(
            data,
            f,
            default_flow_style=False,
            sort_keys=False,
            width=1000,
        )

    print(f"[OK] wrote {path.relative_to(PROJECT_ROOT)}")


def write_text(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    print(f"[OK] wrote {path.relative_to(PROJECT_ROOT)}")


def load_playbook():
    if not SOURCE_PLAYBOOK.exists():
        fail(f"Source playbook not found: {SOURCE_PLAYBOOK}")

    with SOURCE_PLAYBOOK.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    if not isinstance(data, list):
        fail("galaxy.yml must be a YAML list of plays")

    return data


def find_play(plays, text):
    text = text.lower()

    for play in plays:
        name = str(play.get("name", "")).lower()
        if text in name:
            return play

    return None


def role_item_to_include_role_task(role_item, play_become=None, play_become_user=None):
    """
    Convert playbook role syntax into an include_role task.

    For include_role, become/become_user/environment must be applied through:
      include_role:
        name: role_name
        apply:
          become: true
          become_user: postgres
          environment: ...

    vars remain at task level.
    """

    if isinstance(role_item, str):
        role_name = role_item
        role_data = {}
    elif isinstance(role_item, dict):
        role_name = role_item.get("role")
        role_data = dict(role_item)
    else:
        fail(f"Unsupported role item: {role_item}")

    if not role_name:
        fail(f"Role item missing role name: {role_item}")

    include_role_data = {
        "name": role_name,
    }

    apply_data = {}

    if "become" in role_data:
        apply_data["become"] = role_data["become"]

    if "become_user" in role_data:
        apply_data["become_user"] = role_data["become_user"]

    if play_become is not None:
        apply_data["become"] = play_become

    if play_become_user is not None:
        apply_data["become_user"] = play_become_user

    if "environment" in role_data:
        apply_data["environment"] = role_data["environment"]

    if apply_data:
        include_role_data["apply"] = apply_data

    task = {
        "name": f"Run role {role_name}",
        "include_role": include_role_data,
    }

    if "vars" in role_data:
        task["vars"] = role_data["vars"]

    if "when" in role_data:
        task["when"] = role_data["when"]

    if "tags" in role_data:
        task["tags"] = role_data["tags"]

    return task


def merge_vars(role_task, play_vars):
    """
    Merge play vars into role task vars.

    Role task vars win if both define the same variable.
    """

    if not play_vars:
        return role_task

    existing_vars = role_task.get("vars", {})

    merged = {}
    merged.update(play_vars)
    merged.update(existing_vars)

    role_task["vars"] = merged
    return role_task


def inject_required_variable_validations(preflight_tasks):
    """
    Add required config validation tasks to generated preflight.yml.

    These checks support the minimal consumer config model:
      galaxy_admin_email
      galaxy_database_password
    """

    validation_tasks = [
        {
            "name": "Validate required database password is set",
            "assert": {
                "that": [
                    "galaxy_database_password is defined",
                    "galaxy_database_password | length > 0",
                ],
                "fail_msg": "galaxy_database_password must be set in group_vars/galaxyservers.yml or Ansible Vault.",
            },
        },
        {
            "name": "Validate admin email is set",
            "assert": {
                "that": [
                    "galaxy_admin_email is defined",
                    "galaxy_admin_email | length > 0",
                ],
                "fail_msg": "galaxy_admin_email must be set in group_vars/galaxyservers.yml.",
            },
        },
    ]

    existing_names = {
        task.get("name")
        for task in preflight_tasks
        if isinstance(task, dict)
    }

    tasks_to_add = [
        task for task in validation_tasks
        if task["name"] not in existing_names
    ]

    return tasks_to_add + preflight_tasks


def classify_post_task(task):
    """
    Decide which role task file each post_task should go to.
    """

    name = str(task.get("name", "")).lower()

    client_keywords = [
        "client",
        "pnpm",
        "node_modules",
        "static dist",
        "static/dist",
        "build galaxy client",
        "build galaxy client production bundle",
        "old client artifacts",
        "sample built client",
        "fix static ownership",
    ]

    nginx_keywords = [
        "nginx",
        "site directories",
        "galaxy nginx site",
        "default nginx",
        "default nginx site",
        "default nginx site layout",
        "welcome.html",
        "welcome.sample.html",
    ]

    health_keywords = [
        "deployment summary",
        "api through nginx",
        "validate galaxy api through nginx",
        "validate built static asset",
        "find one built static asset",
        "convert static asset",
        "health",
    ]

    backend_keywords = [
        "tool-data",
        "tool data",
        "virtualenv ownership",
        "root cache",
        "cache directory",
        "cache ownership",
        "initialize db",
        "reload systemd",
        "start galaxy service",
        "reset gravity",
        "restart galaxy",
        "wait for galaxy process",
        "web port",
        "core api",
        "endpoint response",
        "backend api",
    ]

    if any(keyword in name for keyword in client_keywords):
        return "client_build.yml"

    if any(keyword in name for keyword in nginx_keywords):
        return "nginx.yml"

    if any(keyword in name for keyword in health_keywords):
        return "healthcheck.yml"

    if any(keyword in name for keyword in backend_keywords):
        return "backend_start.yml"

    return "backend_start.yml"


def create_main_tasks():
    main_tasks = [
        {"import_tasks": "preflight.yml"},
        {"import_tasks": "postgresql.yml"},
        {"import_tasks": "db_objects.yml"},
        {"import_tasks": "galaxy_server.yml"},
        {"import_tasks": "backend_start.yml"},
        {
            "import_tasks": "client_build.yml",
            "when": "build_galaxy_client_after_api | default(false)",
        },
        {"import_tasks": "nginx.yml"},
        {
            "name": "Flush Galaxy role handlers before final health checks",
            "meta": "flush_handlers",
        },
        {"import_tasks": "healthcheck.yml"},
    ]

    write_yaml(TASKS_DIR / "main.yml", main_tasks)


def create_defaults():
    """
    Generate readable defaults/main.yml as text.

    We write this file as text instead of using PyYAML so Jinja expressions
    remain readable and important strings remain quoted.
    """

    defaults_content = """---
# =====================================================================
# AUTO-GENERATED FILE
# Source: galaxy.yml
# Do not edit manually unless you disable the sync generator.
# =====================================================================

# ---------------------------------------------------------------------
# Galaxy root paths
# ---------------------------------------------------------------------
galaxy_root: "/srv/galaxy"
galaxy_layout: root-dir

galaxy_server_dir: "{{ galaxy_root }}/server"
galaxy_config_dir: "{{ galaxy_root }}/config"
galaxy_mutable_data_dir: "{{ galaxy_root }}/mutable"
galaxy_mutable_config_dir: "{{ galaxy_mutable_data_dir }}/config"
galaxy_cache_dir: "{{ galaxy_mutable_data_dir }}/cache"
galaxy_shed_tools_dir: "{{ galaxy_mutable_data_dir }}/shed_tools"
galaxy_tool_data_path: "{{ galaxy_mutable_data_dir }}/tool_data"
galaxy_local_tools_dir: "{{ galaxy_root }}/local_tools"
galaxy_virtual_env: "{{ galaxy_root }}/venv"

# ---------------------------------------------------------------------
# Galaxy user/path/systemd behavior
# ---------------------------------------------------------------------
galaxy_user_name: galaxy

galaxy_user:
  name: "{{ galaxy_user_name }}"
  shell: /bin/bash

galaxy_create_user: true
galaxy_manage_paths: true
galaxy_manage_systemd: true
galaxy_separate_privileges: true

# ---------------------------------------------------------------------
# Galaxy repository
# ---------------------------------------------------------------------
galaxy_repo: https://github.com/galaxyproject/galaxy.git
galaxy_commit_id: release_26.0
galaxy_force_checkout: true

# ---------------------------------------------------------------------
# Galaxy backend
# ---------------------------------------------------------------------
galaxy_web_port: 8080

galaxy_systemd_environment:
  HOME: "{{ galaxy_root }}"
  PATH: "{{ galaxy_virtual_env }}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin"

# ---------------------------------------------------------------------
# Gravity config
# ---------------------------------------------------------------------
galaxy_config:
    gravity:
        galaxy_user: "{{ galaxy_user_name }}"
        galaxy_root: "{{ galaxy_server_dir }}"
        virtualenv: "{{ galaxy_virtual_env }}"

    galaxy:
        root: "{{ galaxy_server_dir }}"
        database_connection: "postgresql://{{ database.user }}:{{ database.password }}@{{ database.host }}:{{ database.port }}/{{ database.name }}?client_encoding=utf8"

# ---------------------------------------------------------------------
# Galaxy admin defaults
# ---------------------------------------------------------------------
galaxy_admin_email: ""

admin:
  email: "{{ galaxy_admin_email }}"

# ---------------------------------------------------------------------
# PostgreSQL defaults
# ---------------------------------------------------------------------
galaxy_database_user: "galaxy"
galaxy_database_name: "galaxy"
galaxy_database_host: "localhost"
galaxy_database_port: 5432
galaxy_database_password: ""

database:
  user: "{{ galaxy_database_user }}"
  name: "{{ galaxy_database_name }}"
  host: "{{ galaxy_database_host }}"
  port: "{{ galaxy_database_port }}"
  password: "{{ galaxy_database_password }}"

postgresql_objects_users:
  - name: "{{ database.user }}"
    password: "{{ database.password }}"

postgresql_objects_databases:
  - name: "{{ database.name }}"
    owner: "{{ database.user }}"


# ---------------------------------------------------------------------
# Miniconda / tool dependency defaults
# ---------------------------------------------------------------------
miniconda_prefix: "{{ galaxy_mutable_data_dir }}/dependencies/_conda"
miniconda_version: latest

miniconda_channels:
  - conda-forge
  - bioconda
  - defaults

miniconda_manage_dependencies: true
miniconda_conda_environments: []

# ---------------------------------------------------------------------
# Client build strategy
# ---------------------------------------------------------------------
build_galaxy_client_after_api: true

galaxy_client_use_prebuilt: false
galaxy_build_client: false
galaxy_client_make: false
galaxy_skip_client_build: true
galaxy_manage_node: false
galaxy_create_web_server_config: false

# ---------------------------------------------------------------------
# Galaxy app config
# ---------------------------------------------------------------------
galaxy_app_config:
  galaxy:
    root: "{{ galaxy_server_dir }}"
    database_connection: "postgresql://{{ database.user }}:{{ database.password }}@{{ database.host }}:{{ database.port }}/{{ database.name }}?client_encoding=utf8"

    data_dir: "{{ galaxy_mutable_data_dir }}"
    file_path: "{{ galaxy_mutable_data_dir }}/datasets"
    job_working_directory: "{{ galaxy_mutable_data_dir }}/job_working_directory"

    tool_config_file: "{{ galaxy_mutable_data_dir }}/config/tool_conf.xml"
    tool_dependency_dir: "{{ galaxy_mutable_data_dir }}/dependencies"
    tool_data_path: "{{ galaxy_mutable_data_dir }}/tool_data"

    tool_data_table_config_path: "{{ galaxy_server_dir }}/config/tool_data_table_conf.xml.sample"
    shed_tool_data_table_config: "{{ galaxy_mutable_data_dir }}/config/shed_tool_data_table_conf.xml"
    integrated_tool_panel_config: "{{ galaxy_mutable_data_dir }}/config/integrated_tool_panel.xml"
    migrated_tools_config: "{{ galaxy_mutable_data_dir }}/config/migrated_tools_conf.xml"

    dependency_resolvers_config_file: "{{ galaxy_config_dir }}/dependency_resolvers_conf.xml"
    job_metrics_config_file: "{{ galaxy_config_dir }}/job_metrics_conf.xml"

    datatypes_config_file: "{{ galaxy_server_dir }}/config/datatypes_conf.xml.sample"
    openid_config_file: "{{ galaxy_server_dir }}/config/openid_conf.xml.sample"
    themes_config_file: "{{ galaxy_config_dir }}/themes_conf.yml"

    visualization_plugins_directory: config/plugins/visualizations

    static_enabled: true
    static_dir: "{{ galaxy_server_dir }}/static"
"""

    write_text(DEFAULTS_DIR / "main.yml", defaults_content)


def create_handlers():
    write_text(
        HANDLERS_DIR / "main.yml",
        GENERATED_HEADER + "# No custom handlers currently required.\n",
        )


def ensure_default_nginx_cleanup_task(nginx_tasks):
    cleanup_task = {
        "name": "Remove default Nginx site layout if active",
        "file": {
            "path": "/etc/nginx/sites-enabled/default",
            "state": "absent",
        },
    }

    existing_names = {
        task.get("name")
        for task in nginx_tasks
        if isinstance(task, dict)
    }

    if cleanup_task["name"] not in existing_names:
        return [cleanup_task] + nginx_tasks

    return nginx_tasks


def create_role_playbook():
    playbook = [
        {
            "name": "Deploy Galaxy using galaxy_deployment role",
            "hosts": "galaxyservers",
            "become": True,
            "vars_files": [
                "../group_vars/galaxyservers.yml",
            ],
            "roles": [
                {
                    "role": "galaxy_deployment",
                }
            ],
        }
    ]

    write_yaml(ROLE_PLAYBOOK, playbook)


def force_galaxy_role_stable_vars(task, role_name):
    """
    Force the official galaxyproject.galaxy role to behave like the stable
    monolithic galaxy.yml playbook.

    This prevents the imported role deployment from skipping:
      - Galaxy user creation
      - path management
      - systemd unit management

    It also prevents galaxyproject.galaxy from building the client early.
    """

    if role_name != "galaxyproject.galaxy":
        return task

    forced_vars = {
        # Match stable main playbook behavior
        "galaxy_create_user": True,
        "galaxy_manage_paths": True,
        "galaxy_manage_systemd": True,

        # Keep mutable config path consistent with the working playbook
        "galaxy_mutable_config_dir": "{{ galaxy_mutable_data_dir }}/config",

        # Do not let galaxyproject.galaxy build the client early
        "galaxy_client_use_prebuilt": False,
        "galaxy_build_client": False,
        "galaxy_client_make": False,
        "galaxy_skip_client_build": True,

        # We manage Node and nginx ourselves
        "galaxy_manage_node": False,
        "galaxy_create_web_server_config": False,
    }

    existing_vars = task.get("vars", {})
    merged_vars = {}
    merged_vars.update(existing_vars)
    merged_vars.update(forced_vars)

    task["vars"] = merged_vars
    return task

def miniconda_cleanup_tasks():
    """
    Prepare Miniconda path before running galaxyproject.miniconda.

    This handles the common broken states:
      - /srv/galaxy is not traversable by galaxy user
      - /srv/galaxy/mutable is owned by root or has wrong mode
      - /srv/galaxy/mutable/dependencies is inaccessible
      - _conda exists but is incomplete
      - _conda/bin/conda exists but galaxy user cannot execute it

    If the prefix is incomplete or inaccessible, it is removed so the
    galaxyproject.miniconda role can install cleanly.
    """

    return [
        {
            "name": "Ensure Galaxy root has traversable permissions before Miniconda",
            "file": {
                "path": "{{ galaxy_root }}",
                "state": "directory",
                "owner": "root",
                "group": "root",
                "mode": "0755",
            },
        },
        {
            "name": "Ensure Galaxy mutable directory is accessible before Miniconda",
            "file": {
                "path": "{{ galaxy_mutable_data_dir }}",
                "state": "directory",
                "owner": "{{ galaxy_user_name }}",
                "group": "{{ galaxy_user_name }}",
                "mode": "0755",
            },
        },
        {
            "name": "Ensure Galaxy dependency directory exists before Miniconda",
            "file": {
                "path": "{{ galaxy_mutable_data_dir }}/dependencies",
                "state": "directory",
                "owner": "{{ galaxy_user_name }}",
                "group": "{{ galaxy_user_name }}",
                "mode": "0755",
            },
        },
        {
            "name": "Repair Galaxy dependency directory ownership before Miniconda",
            "file": {
                "path": "{{ galaxy_mutable_data_dir }}/dependencies",
                "owner": "{{ galaxy_user_name }}",
                "group": "{{ galaxy_user_name }}",
                "recurse": True,
            },
            "ignore_errors": True,
        },
        {
            "name": "Check if Miniconda conda executable exists",
            "stat": {
                "path": "{{ miniconda_prefix }}/bin/conda",
            },
            "register": "miniconda_conda_binary",
        },
        {
            "name": "Check if Galaxy user can execute Miniconda conda",
            "command": "test -x {{ miniconda_prefix }}/bin/conda",
            "become": True,
            "become_user": "{{ galaxy_user_name }}",
            "register": "miniconda_conda_access",
            "changed_when": False,
            "failed_when": False,
            "when": [
                "miniconda_prefix is defined",
                "miniconda_conda_binary.stat.exists",
            ],
        },
        {
            "name": "Remove incomplete or inaccessible Miniconda prefix",
            "file": {
                "path": "{{ miniconda_prefix }}",
                "state": "absent",
            },
            "when": [
                "miniconda_prefix is defined",
                "not miniconda_conda_binary.stat.exists or miniconda_conda_access.rc | default(1) != 0",
            ],
        },
        {
            "name": "Ensure Miniconda parent directory exists after cleanup",
            "file": {
                "path": "{{ miniconda_prefix | dirname }}",
                "state": "directory",
                "owner": "{{ galaxy_user_name }}",
                "group": "{{ galaxy_user_name }}",
                "mode": "0755",
            },
        },
    ]
def ensure_backend_permission_tasks(backend_tasks):
    """
    Ensure Galaxy runtime paths are accessible by the galaxy user before
    database initialization and service startup.

    This prevents permission errors like:
      Unable to change directory before execution:
      [Errno 13] Permission denied: b'/srv/galaxy/server'
    """

    permission_tasks = [
        {
            "name": "Ensure Galaxy root has traversable permissions before backend start",
            "file": {
                "path": "{{ galaxy_root }}",
                "state": "directory",
                "owner": "root",
                "group": "root",
                "mode": "0755",
            },
        },
        {
            "name": "Ensure Galaxy server directory is accessible before DB init",
            "file": {
                "path": "{{ galaxy_server_dir }}",
                "state": "directory",
                "owner": "{{ galaxy_user_name }}",
                "group": "{{ galaxy_user_name }}",
                "recurse": True,
            },
        },
        {
            "name": "Ensure Galaxy virtualenv is accessible before DB init",
            "file": {
                "path": "{{ galaxy_virtual_env }}",
                "state": "directory",
                "owner": "{{ galaxy_user_name }}",
                "group": "{{ galaxy_user_name }}",
                "recurse": True,
            },
        },
        {
            "name": "Ensure Galaxy config directory is accessible before DB init",
            "file": {
                "path": "{{ galaxy_config_dir }}",
                "state": "directory",
                "owner": "{{ galaxy_user_name }}",
                "group": "{{ galaxy_user_name }}",
                "recurse": True,
            },
        },
        {
            "name": "Ensure Galaxy mutable directory is accessible before backend start",
            "file": {
                "path": "{{ galaxy_mutable_data_dir }}",
                "state": "directory",
                "owner": "{{ galaxy_user_name }}",
                "group": "{{ galaxy_user_name }}",
                "recurse": True,
            },
        },
    ]

    existing_names = {
        task.get("name")
        for task in backend_tasks
        if isinstance(task, dict)
    }

    tasks_to_add = [
        task for task in permission_tasks
        if task["name"] not in existing_names
    ]

    return tasks_to_add + backend_tasks

def sync():
    plays = load_playbook()

    pg_play = find_play(plays, "install postgresql server")
    db_play = find_play(plays, "setup postgresql database")
    galaxy_play = find_play(plays, "deploy galaxy")

    if not pg_play:
        fail("Could not find play: Install PostgreSQL server")

    if not db_play:
        fail("Could not find play: Setup PostgreSQL database")

    if not galaxy_play:
        fail("Could not find play: Deploy Galaxy")

    TASKS_DIR.mkdir(parents=True, exist_ok=True)
    DEFAULTS_DIR.mkdir(parents=True, exist_ok=True)
    HANDLERS_DIR.mkdir(parents=True, exist_ok=True)
    PLAYBOOKS_DIR.mkdir(parents=True, exist_ok=True)

    # -----------------------------------------------------------------
    # preflight.yml = PLAY 3 pre_tasks + required validations
    # -----------------------------------------------------------------
    preflight_tasks = galaxy_play.get("pre_tasks", [])
    preflight_tasks = inject_required_variable_validations(preflight_tasks)
    write_yaml(TASKS_DIR / "preflight.yml", preflight_tasks)

    # -----------------------------------------------------------------
    # postgresql.yml = PLAY 1 pre_tasks + PLAY 1 roles as include_role
    # -----------------------------------------------------------------
    pg_tasks = []

    for task in pg_play.get("pre_tasks", []):
        pg_tasks.append(task)

    pg_vars = pg_play.get("vars", {})

    for role_item in pg_play.get("roles", []):
        task = role_item_to_include_role_task(role_item)
        task = merge_vars(task, pg_vars)
        pg_tasks.append(task)

    write_yaml(TASKS_DIR / "postgresql.yml", pg_tasks)

    # -----------------------------------------------------------------
    # db_objects.yml = PLAY 2 roles as include_role
    # Preserve become/become_user from PLAY 2 using include_role.apply.
    # Force DB vars so the role does not skip user/database creation.
    # -----------------------------------------------------------------
    db_tasks = []

    db_vars = db_play.get("vars", {})

    forced_db_vars = {
        "postgresql_version": 16,
        "postgresql_objects_users": [
            {
                "name": "{{ database.user }}",
                "password": "{{ database.password }}",
            }
        ],
        "postgresql_objects_databases": [
            {
                "name": "{{ database.name }}",
                "owner": "{{ database.user }}",
            }
        ],
    }

    for role_item in db_play.get("roles", []):
        task = role_item_to_include_role_task(
            role_item,
            play_become=db_play.get("become"),
            play_become_user=db_play.get("become_user"),
        )

        task = merge_vars(task, db_vars)

        existing_vars = task.get("vars", {})
        merged_vars = {}
        merged_vars.update(existing_vars)
        merged_vars.update(forced_db_vars)
        task["vars"] = merged_vars

        db_tasks.append(task)

    write_yaml(TASKS_DIR / "db_objects.yml", db_tasks)

    # -----------------------------------------------------------------
    # galaxy_server.yml = PLAY 3 roles as include_role
    # Skip galaxyproject.nginx if present because nginx is manual.
    # -----------------------------------------------------------------
    galaxy_server_tasks = []

    for role_item in galaxy_play.get("roles", []):
        if isinstance(role_item, str):
            role_name = role_item
        else:
            role_name = role_item.get("role")

        if role_name == "galaxyproject.nginx":
            continue

        task = role_item_to_include_role_task(role_item)

        # Critical: match stable galaxy.yml behavior for the Galaxy role.
        task = force_galaxy_role_stable_vars(task, role_name)

        # Critical: prepare Miniconda paths before running the Miniconda role.
        if role_name == "galaxyproject.miniconda":
            galaxy_server_tasks.extend(miniconda_cleanup_tasks())

            task.setdefault("include_role", {}).setdefault("apply", {})
            task["include_role"]["apply"]["become"] = True
            task["include_role"]["apply"]["become_user"] = "{{ galaxy_user_name }}"

        galaxy_server_tasks.append(task)

    write_yaml(TASKS_DIR / "galaxy_server.yml", galaxy_server_tasks)

    # -----------------------------------------------------------------
    # Split PLAY 3 post_tasks into role task files
    # -----------------------------------------------------------------
    split_files = {
        "backend_start.yml": [],
        "client_build.yml": [],
        "nginx.yml": [],
        "healthcheck.yml": [],
    }

    for task in galaxy_play.get("post_tasks", []):
        target = classify_post_task(task)
        split_files[target].append(task)

    for filename, tasks in split_files.items():
        if filename == "backend_start.yml":
            tasks = ensure_backend_permission_tasks(tasks)
        if filename == "nginx.yml":
            tasks = ensure_default_nginx_cleanup_task(tasks)
        write_yaml(TASKS_DIR / filename, tasks)

    create_main_tasks()
    create_defaults()
    create_handlers()
    create_role_playbook()

    print("\n[OK] Galaxy playbook synced into role successfully ✅")
    print("[NEXT] Run:")
    print("  ansible-playbook -i hosts playbooks/galaxy-role.yml --syntax-check")


if __name__ == "__main__":
    try:
        sync()
    except yaml.YAMLError as error:
        fail(f"YAML parsing failed: {error}")