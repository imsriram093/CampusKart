"""
Splits an Oracle SQL*Plus script into executable statements.

Rules (the same ones SQL*Plus follows for this project's script):
  * SET ... lines and comment lines outside a statement are skipped.
  * A statement that starts with CREATE [OR REPLACE] FUNCTION / PROCEDURE / TRIGGER,
    or with BEGIN / DECLARE, is a PL/SQL block. It ends at a line containing only "/".
    The block is sent with its final "END;" (PL/SQL needs it).
  * Any other statement ends at the first ";" that is outside a string literal.
    The ";" is removed (Oracle's SQL engine does not accept it).
"""

import re

_PLSQL_START = re.compile(
    r"^\s*(CREATE\s+(OR\s+REPLACE\s+)?(FUNCTION|PROCEDURE|TRIGGER|PACKAGE|TYPE)\b|BEGIN\b|DECLARE\b)",
    re.IGNORECASE,
)
_SQLPLUS_CMD = re.compile(r"^\s*(SET|SPOOL|PROMPT|SHOW|EXIT|QUIT)\b", re.IGNORECASE)


def _ends_outside_quote(text):
    """True if `text` ends with ';' that is not inside a '...' literal."""
    in_q = False
    last_semicolon_outside = False
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "'":
            if in_q and i + 1 < len(text) and text[i + 1] == "'":
                i += 2
                continue
            in_q = not in_q
            last_semicolon_outside = False
        elif ch == ";" and not in_q:
            last_semicolon_outside = True
        elif not ch.isspace():
            last_semicolon_outside = False
        i += 1
    return last_semicolon_outside and not in_q


def split_statements(script_text):
    """Return a list of (kind, statement_text) where kind is 'plsql' or 'sql'."""
    statements = []
    buf = []
    mode = None  # None | 'sql' | 'plsql'
    for line in script_text.splitlines():
        stripped = line.strip()
        if mode is None:
            if not stripped or stripped.startswith("--"):
                continue
            if _SQLPLUS_CMD.match(stripped):
                continue
            mode = "plsql" if _PLSQL_START.match(stripped) else "sql"
            buf = []
        if mode == "plsql":
            if stripped == "/":
                statements.append(("plsql", "\n".join(buf).rstrip()))
                mode = None
                continue
            buf.append(line)
        else:
            buf.append(line)
            joined = "\n".join(buf)
            if _ends_outside_quote(joined):
                text = joined.rstrip()
                text = text[:-1].rstrip()  # drop the final ';'
                statements.append(("sql", text))
                mode = None
    return statements


def extract_object_sources(script_text):
    """Map OBJECT_NAME -> full CREATE OR REPLACE text, for the 'view source' panels."""
    sources = {}
    for kind, stmt in split_statements(script_text):
        m = re.match(
            r"\s*CREATE\s+OR\s+REPLACE\s+(FUNCTION|PROCEDURE|TRIGGER|VIEW)\s+(\w+)",
            stmt,
            re.IGNORECASE,
        )
        if m:
            sources[m.group(2).upper()] = {
                "type": m.group(1).upper(),
                "name": m.group(2).upper(),
                "source": stmt + (";" if kind == "sql" else "\n/"),
            }
    return sources
