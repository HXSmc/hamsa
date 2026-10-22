import sqlite3
from importlib.resources import files

from hamsa_brain.cli import main


def test_cli_and_schema(capsys):
    assert main([]) == 0
    assert "hamsa-brain" in capsys.readouterr().out
    db = sqlite3.connect(":memory:")
    db.executescript(files("hamsa_brain.schema").joinpath("001_init.sql").read_text())
    assert db.execute("SELECT version FROM schema_version").fetchall() == [(1,)]
