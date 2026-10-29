"""
SQLite MIRROR driver: an offline copy of the CampusKart database.

It exists so the application can be demonstrated on any laptop, even when the
lab Oracle server cannot be reached. It is built from the same sources:

  * tables and constraints  -> app/db/mirror_schema.sql (same names and rules)
  * sample data             -> the INSERT statements of database/CampusKart_Review3.sql
  * triggers                -> app/db/mirror_triggers.sql (same ORA-2xxxx errors)
  * procedures / functions  -> Python ports below, statement-for-statement

Errors are reported in Oracle form (ORA-02290, ORA-20014, ...), so the
application behaves the same in both modes. Oracle stays the reference.
"""

import datetime as _dt
import re
import sqlite3
import threading
import time
from decimal import Decimal

from .common import DbError, norm_value, ora_num, ora_round

_SCHEMA = "CAMPUSKART"

_UNIQUE_MAP = {
    "users.user_id": "PK_USERS",
    "users.reg_no": "UQ_USER_REGNO",
    "users.email": "UQ_USER_EMAIL",
    "users.phone": "UQ_USER_PHONE",
    "categories.category_id": "PK_CATEGORIES",
    "categories.category_name": "UQ_CATEGORY_NAME",
    "listings.listing_id": "PK_LISTINGS",
    "offers.offer_id": "PK_OFFERS",
    "orders.order_id": "PK_ORDERS",
    "orders.offer_id": "UQ_ORDER_OFFER",
    "escrow_txns.txn_id": "PK_ESCROW_TXNS",
    "reviews.review_id": "PK_REVIEWS",
    "reviews.order_id": "UQ_REVIEW_ORDER",
    "disputes.dispute_id": "PK_DISPUTES",
    "disputes.order_id": "UQ_DISPUTE_ORDER",
}


def _d(x):
    return Decimal(str(x)) if x is not None else None


class _Raised(Exception):
    pass


class MirrorDriver:
    mode = "mirror"

    def __init__(self, db_path, schema_path, triggers_path, script_path):
        self.db_path = db_path
        self.schema_path = schema_path
        self.triggers_path = triggers_path
        self.script_path = script_path
        self.lock = threading.RLock()
        self._raised = None
        db_path.parent.mkdir(parents=True, exist_ok=True)
        fresh = not db_path.exists()
        self.conn = sqlite3.connect(str(db_path), check_same_thread=False, isolation_level=None)
        self.conn.execute("PRAGMA foreign_keys = ON")
        self._register_functions()
        if fresh or not self._has_tables():
            self.reset()

    # ------------------------------------------------------------------ info
    def info(self):
        return {
            "mode": "mirror",
            "label": "SQLITE MIRROR",
            "detail": f"data/{self.db_path.name}",
            "driver": f"sqlite3 {sqlite3.sqlite_version} (offline mirror of the Oracle schema)",
        }

    def _has_tables(self):
        cur = self.conn.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN "
            "('users','categories','listings','offers','orders','escrow_txns','reviews','disputes')"
        )
        return cur.fetchone()[0] == 8

    # ----------------------------------------------------- SQL-callable UDFs
    def _register_functions(self):
        c = self.conn

        def ck_raise(code, message):
            self._raised = DbError(f"ORA-{abs(int(code)):05d}", message)
            raise _Raised(message)

        def to_char(value, fmt=None):
            if value is None:
                return None
            if fmt is None:
                return ora_num(value) if isinstance(value, (int, float)) else str(value)
            d = _dt.datetime.fromisoformat(str(value)[:19]) if len(str(value)) > 10 else \
                _dt.datetime.strptime(str(value)[:10], "%Y-%m-%d")
            out = fmt.upper()
            out = out.replace("YYYY", d.strftime("%Y")).replace("MON", d.strftime("%b").upper())
            out = out.replace("MM", d.strftime("%m")).replace("DD", d.strftime("%d"))
            out = out.replace("HH24", d.strftime("%H")).replace("MI", d.strftime("%M"))
            out = out.replace("SS", d.strftime("%S"))
            return out

        c.create_function("ck_raise", 2, ck_raise)
        c.create_function("to_char", 1, to_char)
        c.create_function("to_char", 2, to_char)
        c.create_function("nvl", 2, lambda a, b: b if a is None else a)
        c.create_function("calc_platform_fee", 2, self._fn_calc_platform_fee)
        c.create_function("seller_trust_score", 1, self._fn_seller_trust_score)
        c.create_function("escrow_balance", 1, self._fn_escrow_balance)

    # ------------------------------------------------------- error handling
    def _translate(self, exc, sql=""):
        if self._raised is not None:
            err, self._raised = self._raised, None
            return err
        msg = str(exc)
        m = re.match(r"CHECK constraint failed: (\w+)", msg)
        if m:
            return DbError("ORA-02290", f"check constraint ({_SCHEMA}.{m.group(1).upper()}) violated")
        m = re.match(r"UNIQUE constraint failed: ([\w.]+)", msg)
        if m:
            name = _UNIQUE_MAP.get(m.group(1), m.group(1).upper())
            return DbError("ORA-00001", f"unique constraint ({_SCHEMA}.{name}) violated")
        m = re.match(r"NOT NULL constraint failed: (\w+)\.(\w+)", msg)
        if m:
            return DbError(
                "ORA-01400",
                f'cannot insert NULL into ("{_SCHEMA}"."{m.group(1).upper()}"."{m.group(2).upper()}")',
            )
        if "FOREIGN KEY constraint failed" in msg:
            if sql.lstrip().upper().startswith("DELETE"):
                return DbError("ORA-02292", "integrity constraint violated - child record found")
            return DbError("ORA-02291", "integrity constraint violated - parent key not found")
        return DbError("SQLITE", msg)

    def _exec(self, sql, binds=None):
        self._raised = None
        try:
            return self.conn.execute(sql, binds or {})
        except (sqlite3.Error, _Raised) as exc:
            raise self._translate(exc, sql) from None

    def _rows(self, cur):
        cols = [d[0].lower() for d in cur.description]
        return cols, [dict(zip(cols, (norm_value(v) for v in r))) for r in cur.fetchall()]

    def _one(self, sql, binds=None):
        row = self._exec(sql, binds).fetchone()
        return row

    @staticmethod
    def _sysdate():
        return _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # ------------------------------------------------------------ primitives
    def select(self, sql, binds=None):
        with self.lock:
            cur = self._exec(sql, binds)
            return self._rows(cur)

    def run_dml(self, statements, post_select=None, require_first=None):
        with self.lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                counts = []
                for sql, binds in statements:
                    cur = self._exec(sql, binds)
                    counts.append(cur.rowcount)
                    if require_first and len(counts) == 1 and counts[0] == 0:
                        raise DbError("NO-ROWS", require_first)
                post_rows = None
                if post_select:
                    _, post_rows = self._rows(self._exec(post_select[0], post_select[1]))
                self.conn.execute("COMMIT")
                return counts, post_rows
            except Exception:
                self.conn.execute("ROLLBACK")
                raise

    def call_procedure(self, name, args):
        impl = {
            "accept_offer": self._proc_accept_offer,
            "resolve_dispute": self._proc_resolve_dispute,
            "auto_release_escrow": self._proc_auto_release_escrow,
            "mark_handed_over": self._proc_mark_handed_over,
            "seller_statement": self._proc_seller_statement,
        }[name.lower()]
        out = []
        with self.lock:
            self.conn.execute("BEGIN IMMEDIATE")
            try:
                impl(out, *args)
                if self.conn.in_transaction:
                    self.conn.execute("COMMIT")
            except DbError as err:
                if self.conn.in_transaction:
                    self.conn.execute("ROLLBACK")
                err.output = out
                raise
            except Exception:
                if self.conn.in_transaction:
                    self.conn.execute("ROLLBACK")
                raise
        return out

    def call_function(self, name, args):
        fn = {
            "calc_platform_fee": self._fn_calc_platform_fee,
            "seller_trust_score": self._fn_seller_trust_score,
            "escrow_balance": self._fn_escrow_balance,
        }[name.lower()]
        with self.lock:
            try:
                return norm_value(fn(*args))
            except _Raised:
                err, self._raised = self._raised, None
                raise err from None

    # ----------------------------------------------------------------- reset
    def reset(self):
        started = time.time()
        with self.lock:
            self.conn.execute("PRAGMA foreign_keys = OFF")
            self.conn.executescript(self.schema_path.read_text(encoding="utf-8"))
            inserts = self._oracle_inserts()
            self.conn.execute("BEGIN")
            for stmt in inserts:
                self.conn.execute(stmt)
            self.conn.execute("COMMIT")
            self.conn.executescript(self.triggers_path.read_text(encoding="utf-8"))
            self.conn.execute("PRAGMA foreign_keys = ON")
        return {
            "statements": len(inserts),
            "seconds": round(time.time() - started, 2),
            "inventory": [],
            "compile_errors": [],
        }

    def _oracle_inserts(self):
        """Take the sample-data INSERTs straight from the Oracle script (single source of truth)."""
        text = self.script_path.read_text(encoding="utf-8")
        out = []
        for line in text.splitlines():
            if not line.startswith("INSERT INTO"):
                continue
            line = re.sub(r"TO_DATE\('([^']+)',\s*'[^']+'\)", r"'\1'", line)
            line = re.sub(r"TO_TIMESTAMP\('([^']+)',\s*'[^']+'\)", r"'\1'", line)
            out.append(line.rstrip().rstrip(";"))
        return out

    # ========================================================== FUNCTIONS
    def _fn_calc_platform_fee(self, p_listing_id, p_amount):
        if p_amount is None or float(p_amount) <= 0:
            self._raised = DbError("ORA-20040", "Sale amount must be greater than zero")
            raise _Raised()
        row = self.conn.execute(
            "SELECT c.fee_percent FROM listings l JOIN categories c ON c.category_id = l.category_id "
            "WHERE l.listing_id = ?",
            (p_listing_id,),
        ).fetchone()
        if row is None:
            self._raised = DbError("ORA-20041", f"Listing {p_listing_id} does not exist")
            raise _Raised()
        return ora_round(_d(p_amount) * _d(row[0]) / 100, 2)

    def _fn_seller_trust_score(self, p_seller_id):
        total, lost, rating_sum, rating_cnt = self.conn.execute(
            """SELECT COUNT(o.order_id),
                      COUNT(CASE WHEN d.status = 'RESOLVED_BUYER' THEN 1 END),
                      SUM(r.rating), COUNT(r.rating)
                 FROM orders o
                 JOIN offers   f ON f.offer_id   = o.offer_id
                 JOIN listings l ON l.listing_id = f.listing_id
                 LEFT JOIN disputes d ON d.order_id = o.order_id
                 LEFT JOIN reviews  r ON r.order_id = o.order_id
                WHERE l.seller_id = ?""",
            (p_seller_id,),
        ).fetchone()
        if total == 0:
            return None
        avg = Decimal(rating_sum) / Decimal(rating_cnt) if rating_cnt else Decimal(3)
        score = (avg / 5) * 70 + (1 - Decimal(lost) / Decimal(total)) * 30
        return ora_round(score, 1)

    def _fn_escrow_balance(self, p_order_id):
        row = self.conn.execute(
            "SELECT COALESCE(SUM(CASE WHEN txn_type = 'HOLD' THEN amount ELSE -amount END), 0) "
            "FROM escrow_txns WHERE order_id = ?",
            (p_order_id,),
        ).fetchone()
        return norm_value(ora_round(row[0], 2))

    # ========================================================= PROCEDURES
    # Each method is a statement-for-statement port of the Oracle procedure.
    def _err(self, code, message):
        raise DbError(f"ORA-{abs(code):05d}", message)

    def _proc_accept_offer(self, out, p_offer_id, p_seller_id, p_meetup):
        row = self._one(
            "SELECT listing_id, buyer_id, offered_price, status FROM offers WHERE offer_id = :o",
            {"o": p_offer_id},
        )
        if row is None:
            self._err(20010, f"Offer {p_offer_id} does not exist")
        listing_id, buyer_id, price, offer_status = row
        if offer_status != "PENDING":
            self._err(20011, f"Only PENDING offers can be accepted (this offer is {offer_status})")

        owner_id, listing_status = self._one(
            "SELECT seller_id, status FROM listings WHERE listing_id = :l", {"l": listing_id}
        )
        if owner_id != p_seller_id:
            self._err(20012, "Only the seller of this listing can accept its offers")
        if listing_status != "ACTIVE":
            self._err(20013, f"Listing is not ACTIVE (status: {listing_status})")

        (balance,) = self._one("SELECT wallet_balance FROM users WHERE user_id = :u", {"u": buyer_id})
        if _d(balance) < _d(price):
            self._err(
                20014,
                f"Insufficient wallet balance: buyer has Rs {ora_num(balance)}, "
                f"offer needs Rs {ora_num(price)}",
            )

        fee = self._fn_calc_platform_fee(listing_id, price)
        (order_id,) = self._one("SELECT COALESCE(MAX(order_id), 0) + 1 FROM orders")
        self._exec(
            "INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location) "
            "VALUES (:id, :o, :fee, :m)",
            {"id": order_id, "o": p_offer_id, "fee": fee, "m": p_meetup},
        )
        self._exec(
            "INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount) "
            "SELECT COALESCE(MAX(txn_id), 0) + 1, :id, 'HOLD', :p FROM escrow_txns",
            {"id": order_id, "p": price},
        )
        self._exec(
            "UPDATE users SET wallet_balance = wallet_balance - :p WHERE user_id = :u",
            {"p": price, "u": buyer_id},
        )
        self._exec("UPDATE offers SET status = 'ACCEPTED' WHERE offer_id = :o", {"o": p_offer_id})
        cur = self._exec(
            "UPDATE offers SET status = 'REJECTED' WHERE listing_id = :l AND status = 'PENDING' "
            "AND offer_id <> :o",
            {"l": listing_id, "o": p_offer_id},
        )
        rejected = cur.rowcount
        self.conn.execute("COMMIT")
        out.append(f"Order {order_id} created for offer {p_offer_id}.")
        out.append(f"Rs {ora_num(price)} moved to escrow; platform fee Rs {ora_num(fee)}.")
        out.append(f"{rejected} competing offer(s) rejected.")

    def _proc_resolve_dispute(self, out, p_dispute_id, p_admin_id, p_decision):
        row = self._one("SELECT role FROM users WHERE user_id = :u", {"u": p_admin_id})
        role = row[0] if row else None
        if role is None or role != "ADMIN":
            self._err(20030, "Only an administrator can resolve disputes")
        if p_decision is None or p_decision not in ("BUYER", "SELLER"):
            self._err(20031, "Decision must be BUYER or SELLER")
        row = self._one(
            "SELECT order_id, status FROM disputes WHERE dispute_id = :d", {"d": p_dispute_id}
        )
        if row is None:
            self._err(20032, f"Dispute {p_dispute_id} does not exist")
        order_id, d_status = row
        if d_status != "OPEN":
            self._err(20033, f"Dispute {p_dispute_id} is already resolved ({d_status})")

        price, fee, buyer_id, seller_id = self._one(
            """SELECT f.offered_price, o.platform_fee, f.buyer_id, l.seller_id
                 FROM orders o
                 JOIN offers   f ON f.offer_id   = o.offer_id
                 JOIN listings l ON l.listing_id = f.listing_id
                WHERE o.order_id = :o""",
            {"o": order_id},
        )
        now = self._sysdate()
        if p_decision == "BUYER":
            self._exec(
                "INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount) "
                "SELECT COALESCE(MAX(txn_id), 0) + 1, :o, 'REFUND', :p FROM escrow_txns",
                {"o": order_id, "p": price},
            )
            self._exec(
                "UPDATE users SET wallet_balance = wallet_balance + :p WHERE user_id = :u",
                {"p": price, "u": buyer_id},
            )
            self._exec("UPDATE orders SET status = 'REFUNDED' WHERE order_id = :o", {"o": order_id})
            self._exec(
                "UPDATE disputes SET status = 'RESOLVED_BUYER', resolved_by = :a, resolved_on = :t "
                "WHERE dispute_id = :d",
                {"a": p_admin_id, "t": now, "d": p_dispute_id},
            )
            out.append(
                f"Dispute {p_dispute_id} resolved for the buyer: Rs {ora_num(price)} "
                f"refunded to user {buyer_id}."
            )
        else:
            payout = _d(price) - _d(fee)
            self._exec(
                "INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount) "
                "SELECT COALESCE(MAX(txn_id), 0) + 1, :o, 'RELEASE', :p FROM escrow_txns",
                {"o": order_id, "p": price},
            )
            self._exec(
                "UPDATE users SET wallet_balance = wallet_balance + :p WHERE user_id = :u",
                {"p": float(payout), "u": seller_id},
            )
            self._exec("UPDATE orders SET status = 'COMPLETED' WHERE order_id = :o", {"o": order_id})
            self._exec(
                "UPDATE disputes SET status = 'RESOLVED_SELLER', resolved_by = :a, resolved_on = :t "
                "WHERE dispute_id = :d",
                {"a": p_admin_id, "t": now, "d": p_dispute_id},
            )
            out.append(
                f"Dispute {p_dispute_id} resolved for the seller: Rs {ora_num(payout)} paid to user "
                f"{seller_id} (platform fee Rs {ora_num(fee)})."
            )
        self.conn.execute("COMMIT")

    def _proc_auto_release_escrow(self, out, p_days=3):
        cutoff = (_dt.datetime.now() - _dt.timedelta(days=float(p_days))).strftime("%Y-%m-%d %H:%M:%S")
        # explicit cursor c_due_orders
        due = self._exec(
            """SELECT o.order_id, o.platform_fee, f.offered_price, l.seller_id
                 FROM orders o
                 JOIN offers   f ON f.offer_id   = o.offer_id
                 JOIN listings l ON l.listing_id = f.listing_id
                WHERE o.status = 'HANDED_OVER'
                  AND o.handed_over_at <= :cutoff
                  AND NOT EXISTS (SELECT 1 FROM disputes d WHERE d.order_id = o.order_id)
                ORDER BY o.order_id""",
            {"cutoff": cutoff},
        ).fetchall()
        total = Decimal(0)
        count = 0
        for order_id, fee, price, seller_id in due:  # FETCH ... EXIT WHEN %NOTFOUND
            payout = _d(price) - _d(fee)
            self._exec(
                "INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount) "
                "SELECT COALESCE(MAX(txn_id), 0) + 1, :o, 'RELEASE', :p FROM escrow_txns",
                {"o": order_id, "p": price},
            )
            self._exec(
                "UPDATE users SET wallet_balance = wallet_balance + :p WHERE user_id = :u",
                {"p": float(payout), "u": seller_id},
            )
            self._exec("UPDATE orders SET status = 'COMPLETED' WHERE order_id = :o", {"o": order_id})
            total += payout
            count += 1
            out.append(f"Order {order_id}: Rs {ora_num(payout)} released to seller {seller_id}")
        self.conn.execute("COMMIT")
        out.append(f"{count} order(s) completed. Total paid to sellers: Rs {ora_num(total)}")

    def _proc_mark_handed_over(self, out, p_order_id, p_seller_id):
        row = self._one(
            """SELECT o.status, l.seller_id, l.title
                 FROM orders o
                 JOIN offers   f ON f.offer_id   = o.offer_id
                 JOIN listings l ON l.listing_id = f.listing_id
                WHERE o.order_id = :o""",
            {"o": p_order_id},
        )
        if row is None:
            self._err(20050, f"Order {p_order_id} does not exist")
        status, seller_id, title = row
        if seller_id != p_seller_id:
            self._err(20051, "Only the seller of this order can record the handover")
        if status != "CREATED":
            self._err(20052, f"Only CREATED orders can be handed over (this order is {status})")
        self._exec(
            "UPDATE orders SET status = 'HANDED_OVER', handed_over_at = :t WHERE order_id = :o",
            {"t": self._sysdate(), "o": p_order_id},
        )
        self.conn.execute("COMMIT")
        out.append(
            f"Order {p_order_id} ({title}) handed over. Buyer has 3 days to raise a dispute."
        )

    def _proc_seller_statement(self, out, p_seller_id):
        row = self._one("SELECT full_name FROM users WHERE user_id = :u", {"u": p_seller_id})
        if row is None:
            self._err(20070, f"User {p_seller_id} does not exist")
        out.append(f"STATEMENT FOR SELLER {p_seller_id} - {row[0]}")
        earned = pending = refunded = Decimal(0)
        count = 0
        rows = self._exec(
            """SELECT o.order_id, l.title, f.offered_price, o.platform_fee, o.status
                 FROM orders o
                 JOIN offers   f ON f.offer_id   = o.offer_id
                 JOIN listings l ON l.listing_id = f.listing_id
                WHERE l.seller_id = :s
                ORDER BY o.order_id""",
            {"s": p_seller_id},
        ).fetchall()
        for order_id, title, price, fee, status in rows:  # cursor FOR loop
            count += 1
            if status == "COMPLETED":
                earned += _d(price) - _d(fee)
            elif status == "REFUNDED":
                refunded += _d(price)
            elif status in ("CREATED", "HANDED_OVER", "DISPUTED"):
                pending += _d(price) - _d(fee)
            out.append(
                f"  #{order_id}  {title[:34].ljust(34)}  Rs {ora_num(price).rjust(6)}"
                f"  fee {ora_num(fee).rjust(6)}  {status}"
            )
        score = self._fn_seller_trust_score(p_seller_id)
        out.append(
            f"  Orders: {count} | Paid out: Rs {ora_num(earned)} | In escrow: Rs {ora_num(pending)}"
            f" | Refunded to buyers: Rs {ora_num(refunded)}"
        )
        out.append(f"  Trust score: {ora_num(score) if score is not None else 'n/a (no orders yet)'}")
        self.conn.execute("COMMIT")

    @staticmethod
    def cutoff_sql(days):
        return f"datetime('now', 'localtime', '-{int(days)} days')"
