"""
Configuration for the CampusKart application.

Settings are read from environment variables, or from a file called `.env`
in the project folder (copy `.env.example` to `.env` and fill it in).

    CK_DB_MODE        oracle | mirror | auto   (default: auto)
                      oracle  - connect to Oracle and fail loudly if it is not reachable
                      mirror  - use the bundled SQLite mirror (offline demonstration)
                      auto    - try Oracle first, fall back to the mirror
    ORACLE_USER       lab schema user name, e.g. 24BYB0151
    ORACLE_PASSWORD   lab schema password
    ORACLE_DSN        host:port/service, e.g. localhost:1521/XEPDB1 or localhost:1521/FREEPDB1
    CK_PORT           web server port (default 5000)
"""

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WEB_DIR = ROOT / "web"
DATA_DIR = ROOT / "data"
SQL_SCRIPT = ROOT / "database" / "CampusKart_Review3.sql"
MIRROR_SCHEMA = ROOT / "app" / "db" / "mirror_schema.sql"
MIRROR_DB = DATA_DIR / "campuskart_mirror.db"


def _load_dotenv():
    env_file = ROOT / ".env"
    if not env_file.exists():
        return
    for raw in env_file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_dotenv()

DB_MODE = os.environ.get("CK_DB_MODE", "auto").strip().lower()
ORACLE_USER = os.environ.get("ORACLE_USER", "")
ORACLE_PASSWORD = os.environ.get("ORACLE_PASSWORD", "")
ORACLE_DSN = os.environ.get("ORACLE_DSN", "localhost:1521/XEPDB1")
HOST = os.environ.get("HOST", "0.0.0.0" if os.environ.get("PORT") else "127.0.0.1")
PORT = int(os.environ.get("PORT", os.environ.get("CK_PORT", "5000")))
