"""Per-machine settings. Project definitions point at private notes, so they live outside the (public) repo."""
import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

CONFIG_PATH = Path(os.environ.get("HAMSA_CONFIG", "~/.config/hamsa/projects.toml")).expanduser()
DATA_DIR = Path(os.environ.get("HAMSA_DATA", "~/.local/share/hamsa")).expanduser()

# Never indexed, whatever a project config says.
ALWAYS_EXCLUDE = ["**/Secrets/**", "**/*.bak*", "**/.git/**", "**/node_modules/**"]


@dataclass
class Project:
    id: str
    name: str
    include: list[str]  # absolute globs, "~" allowed
    exclude: list[str] = field(default_factory=list)
    git: str | None = None  # "owner/repo"; cloned sparse into DATA_DIR/sources/<id>
    git_paths: list[str] = field(default_factory=list)


def load_projects(path: Path = CONFIG_PATH) -> dict[str, Project]:
    raw = tomllib.loads(path.read_text())
    return {pid: Project(id=pid, **spec) for pid, spec in raw.get("projects", {}).items()}


def index_path() -> Path:
    return DATA_DIR / "index.sqlite"
