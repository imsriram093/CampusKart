"""
Builds (or rebuilds) the CampusKart schema in Oracle by running
database/CampusKart_Review3.sql through python-oracledb.

    python setup_db.py

Uses ORACLE_USER / ORACLE_PASSWORD / ORACLE_DSN from .env.
The same script can be run directly in SQL*Plus (@database/CampusKart_Review3.sql)
or SQL Developer (F5); this helper is only a convenience.
"""
import sys

from app import config
from app.db.oracle_driver import OracleDriver


def main():
    if not config.ORACLE_USER:
        sys.exit("Set ORACLE_USER, ORACLE_PASSWORD and ORACLE_DSN in .env first (see .env.example).")
    print(f"Connecting to {config.ORACLE_USER}@{config.ORACLE_DSN} ...")
    drv = OracleDriver(config.ORACLE_USER, config.ORACLE_PASSWORD, config.ORACLE_DSN, config.SQL_SCRIPT)
    print(f"Connected (Oracle {drv.server_version}). Running {config.SQL_SCRIPT.name} ...")
    report = drv.reset()
    print(f"{report['statements']} statements executed in {report['seconds']} s.\n")
    print(f"{'OBJECT TYPE':<12} {'OBJECT NAME':<26} STATUS")
    for row in report["inventory"]:
        print(f"{row['object_type']:<12} {row['object_name']:<26} {row['status']}")
    if report["compile_errors"]:
        print("\nCOMPILE ERRORS:")
        for e in report["compile_errors"]:
            print(f"  {e['type']} {e['name']} line {e['line']}: {e['text']}")
        sys.exit(1)
    print("\nAll objects valid. Start the application with:  python run.py")


if __name__ == "__main__":
    main()
