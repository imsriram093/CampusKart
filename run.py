"""
Start CampusKart:   python run.py            (mode from .env / CK_DB_MODE, default auto)
                    python run.py --mirror   (force the offline SQLite mirror)
                    python run.py --oracle   (force Oracle; fail if not reachable)
Then open http://127.0.0.1:5000
"""
import os
import sys

if "--mirror" in sys.argv:
    os.environ["CK_DB_MODE"] = "mirror"
elif "--oracle" in sys.argv:
    os.environ["CK_DB_MODE"] = "oracle"

from app.server import main  # noqa: E402

if __name__ == "__main__":
    main()
