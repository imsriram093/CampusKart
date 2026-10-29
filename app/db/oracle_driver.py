"""
Oracle driver: the real CampusKart database (python-oracledb, Thin mode).

Thin mode talks to Oracle directly over the network, so no Oracle Client /
Instant Client installation is needed on the laptop.

Every operation of the application ends up in one of four calls:
    select()          SELECT statements (screens and reports)
    run_dml()         INSERT / UPDATE / DELETE in one transaction (COMMIT or ROLLBACK)
    call_procedure()  BEGIN proc(...); END;  plus the DBMS_OUTPUT lines it printed
    call_function()   SELECT fn(...) FROM dual
"""

import time

from .common import DbError, first_line, norm_value
from .sqlscript import split_statements

try:  # imported lazily so the mirror mode works without the package
    import oracledb  # type: ignore
except ImportError:  # pragma: no cover
    oracledb = None


def _to_db_error(exc):
    """Turn an oracledb.DatabaseError into DbError('ORA-xxxxx', 'message')."""
    err = exc.args[0] if exc.args else exc
    full_code = getattr(err, "full_code", None) or "ORA-?????"
    message = first_line(getattr(err, "message", str(err)))
    prefix = f"{full_code}: "
    if message.startswith(prefix):
        message = message[len(prefix):]
    return DbError(full_code, message)


class OracleDriver:
    mode = "oracle"

    def __init__(self, user, password, dsn, script_path):
        if oracledb is None:
            raise RuntimeError("python-oracledb is not installed (pip install oracledb)")
        self.user = user
        self.dsn = dsn
        self.script_path = script_path
        self.pool = oracledb.create_pool(
            user=user, password=password, dsn=dsn, min=1, max=4, increment=1
        )
        # fail fast if the credentials or DSN are wrong
        with self.pool.acquire() as conn:
            self.server_version = conn.version

    # ------------------------------------------------------------------ info
    def info(self):
        return {
            "mode": "oracle",
            "label": f"ORACLE {self.server_version}",
            "detail": f"{self.user.upper()}@{self.dsn}",
            "driver": f"python-oracledb {oracledb.__version__} (Thin mode)",
        }

    # ------------------------------------------------------------ primitives
    def select(self, sql, binds=None):
        try:
            with self.pool.acquire() as conn:
                with conn.cursor() as cur:
                    cur.execute(sql, binds or {})
                    cols = [d[0].lower() for d in cur.description]
                    rows = [dict(zip(cols, (norm_value(v) for v in r))) for r in cur]
            return cols, rows
        except oracledb.DatabaseError as exc:
            raise _to_db_error(exc) from None

    def run_dml(self, statements, post_select=None, require_first=None):
        """Run [(sql, binds), ...] as ONE transaction. Returns (rowcounts, post_rows).

        require_first: if given and the first statement changes no row, the whole
        transaction is rolled back and DbError('NO-ROWS', require_first) is raised.
        """
        conn = self.pool.acquire()
        try:
            cur = conn.cursor()
            counts = []
            for sql, binds in statements:
                cur.execute(sql, binds or {})
                counts.append(cur.rowcount)
                if require_first and len(counts) == 1 and counts[0] == 0:
                    raise DbError("NO-ROWS", require_first)
            post_rows = None
            if post_select:
                cur.execute(post_select[0], post_select[1] or {})
                cols = [d[0].lower() for d in cur.description]
                post_rows = [dict(zip(cols, (norm_value(v) for v in r))) for r in cur]
            conn.commit()
            return counts, post_rows
        except oracledb.DatabaseError as exc:
            conn.rollback()
            raise _to_db_error(exc) from None
        except DbError:
            conn.rollback()
            raise
        finally:
            self.pool.release(conn)

    def call_procedure(self, name, args):
        """Execute a stored procedure and collect its DBMS_OUTPUT lines."""
        conn = self.pool.acquire()
        lines = []
        error = None
        try:
            cur = conn.cursor()
            cur.execute("BEGIN DBMS_OUTPUT.ENABLE(NULL); END;")
            try:
                cur.callproc(name, args)
            except oracledb.DatabaseError as exc:
                error = _to_db_error(exc)
                conn.rollback()
            # read whatever the procedure printed (also after an error)
            line_var = cur.var(str)
            status_var = cur.var(int)
            while True:
                cur.callproc("DBMS_OUTPUT.GET_LINE", (line_var, status_var))
                if status_var.getvalue() != 0:
                    break
                lines.append(line_var.getvalue() or "")
        finally:
            self.pool.release(conn)
        if error:
            error.output = lines
            raise error
        return lines

    def call_function(self, name, args):
        placeholders = ", ".join(f":a{i}" for i in range(len(args)))
        binds = {f"a{i}": v for i, v in enumerate(args)}
        _, rows = self.select(f"SELECT {name}({placeholders}) AS result FROM dual", binds)
        return rows[0]["result"] if rows else None

    @staticmethod
    def cutoff_sql(days):
        """SQL expression for 'now minus <days> days' in this dialect."""
        return f"(SYSDATE - {int(days)})"

    # ----------------------------------------------------------------- reset
    def reset(self):
        """Re-run database/CampusKart_Review3.sql: drops and rebuilds everything."""
        started = time.time()
        text = self.script_path.read_text(encoding="utf-8")
        executed = 0
        inventory = []
        with self.pool.acquire() as conn:
            cur = conn.cursor()
            for kind, stmt in split_statements(text):
                if kind == "sql" and stmt.lstrip().upper().startswith("SELECT"):
                    cur.execute(stmt)
                    cols = [d[0].lower() for d in cur.description]
                    inventory = [dict(zip(cols, r)) for r in cur]
                else:
                    try:
                        cur.execute(stmt)
                    except oracledb.DatabaseError as exc:
                        conn.rollback()
                        raise _to_db_error(exc) from None
                executed += 1
            conn.commit()
            cur.execute(
                "SELECT name, type, line, position, text FROM user_errors ORDER BY name, sequence"
            )
            errors = [
                {"name": n, "type": t, "line": l, "position": p, "text": x}
                for n, t, l, p, x in cur
            ]
        return {
            "statements": executed,
            "seconds": round(time.time() - started, 2),
            "inventory": inventory,
            "compile_errors": errors,
        }
