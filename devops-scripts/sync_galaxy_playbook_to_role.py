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

    Why apply?
    ----------
    include_role does not accept become/become_user as normal task attributes
    for applying them inside the included role.

    Correct generated structure:

      - name: Run role galaxyproject.postgresql_objects
        include_role:
          name: galaxyproject.postgresql_objects
          apply:
            become: true
            become_user: postgres
        vars:
          postgresql_version: 16

    This function also supports role-level:
      - vars
      - environment
      - become
      - become_user
      - when
      - tags
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

    # Role-level become/become_user from original role item
    if "become" in role_data:
        apply_data["become"] = role_data["become"]

    if "become_user" in role_data:
        apply_data["become_user"] = role_data["become_user"]

    # Play-level become/become_user from original play
    if play_become is not None:
        apply_data["become"] = play_become

    if play_become_user is not None:
        apply_data["become_user"] = play_become_user

    # Apply environment to tasks inside the included role
    if "environment" in role_data:
        apply_data["environment"] = role_data["environment"]

    if apply_data:
        include_role_data["apply"] = apply_data

    task = {
        "name": f"Run role {role_name}",
        "include_role": include_role_data,
    }

    # vars stay at task level for include_role
    if "vars" in role_data:
        task["vars"] = role_data["vars"]

    # when/tags also stay at task level
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


def classify_post_task(task):
    """
    Decide which role task file each post_task should go to.

    Classification is based on task name. This keeps galaxy.yml as the
    source of truth and auto-splits post_tasks into role task files.
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

    # Safe default
    return "backend_start.yml"


def create_main_tasks():
    main_tasks = [
        {
            "import_tasks": "preflight.yml",
        },
        {
            "import_tasks": "postgresql.yml",
        },
        {
            "import_tasks": "db_objects.yml",
        },
        {
            "import_tasks": "galaxy_server.yml",
        },
        {
            "import_tasks": "backend_start.yml",
        },
        {
            "import_tasks": "client_build.yml",
            "when": "build_galaxy_client_after_api | default(false)",
        },
        {
            "import_tasks": "nginx.yml",
        },
        {
            "name": "Flush Galaxy role handlers before final health checks",
            "meta": "flush_handlers",
        },

        {
            "import_tasks": "healthcheck.yml",
        },
    ]

    write_yaml(TASKS_DIR / "main.yml", main_tasks)


def create_defaults():
    """
    Generate a readable defaults/main.yml as text.

    We write this file as text instead of using PyYAML so Jinja expressions
    stay readable and important strings like database_connection remain quoted.
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
# Galaxy user
# ---------------------------------------------------------------------
galaxy_user_name: galaxy

galaxy_user:
  name: "{{ galaxy_user_name }}"
  shell: /bin/bash

galaxy_create_user: true
galaxy_manage_paths: true
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
# PostgreSQL defaults
# ---------------------------------------------------------------------
# The password is intentionally empty here.
# The consuming project must override database.password in group_vars or Ansible Vault.
database:
  user: "galaxy"
  name: "galaxy"
  host: "localhost"
  port: 5432
  password: ""

postgresql_objects_users:
  - name: "{{ database.user }}"
    password: "{{ database.password }}"

postgresql_objects_databases:
  - name: "{{ database.name }}"
    owner: "{{ database.user }}"

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

def force_galaxy_role_client_skip_vars(task, role_name):
    """
    Force the official galaxyproject.galaxy role to skip client build.

    The galaxy_deployment role builds the client later after backend API validation.
    Without these vars, galaxyproject.galaxy may build the client too early.
    """

    if role_name != "galaxyproject.galaxy":
        return task

    forced_vars = {
        "galaxy_client_use_prebuilt": False,
        "galaxy_build_client": False,
        "galaxy_client_make": False,
        "galaxy_skip_client_build": True,
        "galaxy_manage_node": False,
        "galaxy_create_web_server_config": False,
    }

    existing_vars = task.get("vars", {})
    merged_vars = {}
    merged_vars.update(existing_vars)
    merged_vars.update(forced_vars)

    task["vars"] = merged_vars

    return task
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
    # preflight.yml = PLAY 3 pre_tasks
    # -----------------------------------------------------------------
    preflight_tasks = galaxy_play.get("pre_tasks", [])
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
    # -----------------------------------------------------------------
    db_tasks = []

    db_vars = db_play.get("vars", {})

    for role_item in db_play.get("roles", []):
        task = role_item_to_include_role_task(
            role_item,
            play_become=db_play.get("become"),
            play_become_user=db_play.get("become_user"),
        )
        task = merge_vars(task, db_vars)
        db_tasks.append(task)

    write_yaml(TASKS_DIR / "db_objects.yml", db_tasks)

    # -----------------------------------------------------------------
    # galaxy_server.yml = PLAY 3 roles as include_role
    # Skip galaxyproject.nginx if ever present because nginx is manual.
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

        # Critical: prevent official Galaxy role from building the client early.
        task = force_galaxy_role_client_skip_vars(task, role_name)

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