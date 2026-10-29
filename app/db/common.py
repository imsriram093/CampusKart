"""Shared helpers for both database drivers."""

import datetime as _dt
import re
from decimal import Decimal, ROUND_HALF_UP


class DbError(Exception):
    """A database error in Oracle form: code like 'ORA-20001' plus the message."""

    def __init__(self, code, message):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message

    def as_dict(self):
        return {"code": self.code, "message": self.message, "text": f"{self.code}: {self.message}"}


class AppError(Exception):
    """A request the application refuses before touching the database (bad input)."""

    def __init__(self, message, status=400):
        super().__init__(message)
        self.message = message
        self.status = status


def norm_value(v):
    """Make Oracle and SQLite values look the same in JSON."""
    if v is None:
        return None
    if isinstance(v, Decimal):
        v = float(v)
    if isinstance(v, float):
        if v.is_integer():
            return int(v)
        return round(v, 4)
    if isinstance(v, (_dt.datetime, _dt.date)):
        if isinstance(v, _dt.datetime):
            if v.hour == 0 and v.minute == 0 and v.second == 0 and v.microsecond == 0:
                return v.strftime("%Y-%m-%d")
            return v.strftime("%Y-%m-%d %H:%M:%S")
        return v.strftime("%Y-%m-%d")
    if isinstance(v, str):
        # SQLite mirror stores dates as text; drop a midnight time part like Oracle DATE display
        if re.fullmatch(r"\d{4}-\d{2}-\d{2} 00:00:00(\.0+)?", v):
            return v[:10]
        m = re.fullmatch(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.\d+", v)
        if m:
            return m.group(1)
        return v
    if hasattr(v, "read"):  # CLOB
        return v.read()
    return v


def ora_num(n):
    """Format a number the way Oracle's implicit TO_CHAR does in DBMS_OUTPUT (42.50 -> 42.5)."""
    if n is None:
        return ""
    d = Decimal(str(n))
    if d == d.to_integral_value():
        return str(int(d))
    s = format(d.normalize(), "f")
    return s


def ora_round(x, places):
    """Oracle ROUND: half away from zero, exact decimal arithmetic."""
    q = Decimal(1).scaleb(-places)
    return float(Decimal(str(x)).quantize(q, rounding=ROUND_HALF_UP))


def first_line(msg):
    for line in str(msg).splitlines():
        line = line.strip()
        if line:
            return line
    return str(msg)
