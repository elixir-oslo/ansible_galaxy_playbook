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
            "import_tasks": "healthcheck.yml",
        },
    ]

    write_yaml(TASKS_DIR / "main.yml", main_tasks)


def create_defaults():
    defaults = {
        "build_galaxy_client_after_api": True,
        "galaxy_web_port": 8080,
        "galaxy_client_use_prebuilt": False,
        "galaxy_build_client": False,
        "galaxy_client_make": False,
        "galaxy_skip_client_build": True,
        "galaxy_manage_node": False,
        "galaxy_create_web_server_config": False,
    }

    write_yaml(DEFAULTS_DIR / "main.yml", defaults)


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