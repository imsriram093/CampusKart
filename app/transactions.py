"""
Transaction engine: User Operation -> SQL/PL-SQL -> Database Processing ->
Database Update/Retrieval -> Result.

Every button in the application that changes data is one of the transaction
kinds below. For each run the engine records a TRACE that answers the five
questions the project guidelines ask for:

    1. What operation is being performed?       -> meta["operation"]
    2. Which table(s) are involved?             -> meta["tables"]
    3. Which SQL/PL-SQL component is executed?  -> meta["components"] + the exact statement
    4. How is the database affected?            -> before/after snapshot diff of the touched rows
    5. What result is generated?                -> COMMIT / ROLLBACK, DBMS_OUTPUT, message

The snapshots are ordinary SELECTs taken just before and just after the
operation, so the "effect" shown is read back from the database itself.
"""

import datetime as _dt
import itertools
import threading
import time

from .db.common import AppError, DbError, ora_num

# ----------------------------------------------------------------------------
# metadata for each kind of transaction
# ----------------------------------------------------------------------------
STAGES = {
    0: "ACCOUNT",
    1: "LISTING",
    2: "OFFER",
    3: "ESCROW HOLD",
    4: "HANDOVER",
    5: "SETTLEMENT",
}

META = {
    "create_listing": {
        "code": "T1", "stage": 1, "title": "List an item for sale",
        "operation": "A student publishes a second-hand item to the catalogue (FR-04).",
        "tables": [["LISTINGS", "INSERT one row"], ["USERS", "read by the trigger (is the seller blocked?)"]],
        "components": [
            ["SQL", "INSERT INTO listings ... SELECT COALESCE(MAX(listing_id), 0) + 1", "new primary key without a sequence"],
            ["TRIGGER", "TRG_VALIDATE_LISTING", "BEFORE INSERT: blocked sellers cannot list (BR-03)"],
            ["CONSTRAINT", "CHK_LISTING_PRICE, CHK_LISTING_CONDITION, FK_LISTING_CATEGORY", "declarative rules"],
        ],
    },
    "update_price": {
        "code": "T1b", "stage": 1, "title": "Lower the asking price",
        "operation": "The seller edits the price of one of their ACTIVE listings (FR-05).",
        "tables": [["LISTINGS", "UPDATE one row"]],
        "components": [
            ["SQL", "UPDATE listings SET asking_price ... WHERE seller_id = actor AND status = 'ACTIVE'", "ownership is part of the WHERE clause"],
            ["CONSTRAINT", "CHK_LISTING_PRICE", "price must stay positive"],
        ],
    },
    "withdraw_listing": {
        "code": "T1c", "stage": 1, "title": "Withdraw a listing (soft delete)",
        "operation": "The seller takes an ACTIVE listing off the market; its pending offers are rejected in the same transaction (BR-10).",
        "tables": [["LISTINGS", "UPDATE status to WITHDRAWN"], ["OFFERS", "UPDATE pending offers to REJECTED"]],
        "components": [
            ["SQL", "UPDATE listings ... ; UPDATE offers ... ; COMMIT", "two statements, one atomic transaction"],
        ],
    },
    "make_offer": {
        "code": "T2", "stage": 2, "title": "Make an offer",
        "operation": "A buyer offers a price for another student's ACTIVE listing (FR-07).",
        "tables": [["OFFERS", "INSERT one row"], ["LISTINGS", "read by the trigger"], ["USERS", "read by the trigger"]],
        "components": [
            ["SQL", "INSERT INTO offers ... SELECT COALESCE(MAX(offer_id), 0) + 1", "offer starts PENDING (DEFAULT)"],
            ["TRIGGER", "TRG_VALIDATE_OFFER", "BEFORE INSERT: not your own listing (BR-01), listing ACTIVE (BR-02), buyer not blocked (BR-03)"],
        ],
    },
    "withdraw_offer": {
        "code": "T2b", "stage": 2, "title": "Withdraw a pending offer (DELETE)",
        "operation": "A buyer deletes their own PENDING offer (FR-08).",
        "tables": [["OFFERS", "DELETE one row"]],
        "components": [
            ["SQL", "DELETE FROM offers WHERE offer_id = :id AND buyer_id = actor AND status = 'PENDING'", "only the owner, only while pending"],
        ],
    },
    "accept_offer": {
        "code": "T3", "stage": 3, "title": "Accept an offer: money into escrow",
        "operation": "The seller accepts one offer. As ONE atomic transaction the order is created, the fee is fixed, the buyer's money is held in escrow, the listing is reserved and every competing offer is rejected (FR-09).",
        "tables": [["OFFERS", "UPDATE accepted + competing rejected"], ["LISTINGS", "SELECT ... FOR UPDATE, then RESERVED by trigger"],
                   ["USERS", "buyer wallet debited"], ["ORDERS", "INSERT"], ["ESCROW_TXNS", "INSERT HOLD"], ["CATEGORIES", "fee percent read by function"]],
        "components": [
            ["PROCEDURE", "ACCEPT_OFFER", "row locks, validations, 6 DML statements, COMMIT or ROLLBACK"],
            ["FUNCTION", "CALC_PLATFORM_FEE", "fee = price x category fee_percent / 100"],
            ["TRIGGER", "TRG_SYNC_LISTING_STATUS", "AFTER INSERT ON orders: listing becomes RESERVED"],
        ],
    },
    "mark_handed_over": {
        "code": "T4", "stage": 4, "title": "Record the physical handover",
        "operation": "After meeting on campus the seller records the handover; the 3-day dispute window starts (FR-10).",
        "tables": [["ORDERS", "UPDATE status and handed_over_at"], ["LISTINGS", "kept RESERVED by trigger"]],
        "components": [
            ["PROCEDURE", "MARK_HANDED_OVER", "Review III: only the seller, only a CREATED order"],
            ["TRIGGER", "TRG_SYNC_LISTING_STATUS", "AFTER UPDATE OF status ON orders"],
        ],
    },
    "raise_dispute": {
        "code": "T5", "stage": 5, "title": "Raise a dispute: freeze the escrow",
        "operation": "The buyer (or seller) reports a problem. The order is frozen as DISPUTED so the batch job cannot pay the seller (FR-13).",
        "tables": [["DISPUTES", "INSERT one row"], ["ORDERS", "UPDATE to DISPUTED by trigger"], ["LISTINGS", "kept RESERVED"]],
        "components": [
            ["SQL", "INSERT INTO disputes ... SELECT COALESCE(MAX(dispute_id), 0) + 1", "dispute starts OPEN"],
            ["TRIGGER", "TRG_ON_DISPUTE_RAISED", "BEFORE INSERT: only buyer/seller (BR-07), only open orders, sets order DISPUTED"],
            ["TRIGGER", "TRG_SYNC_LISTING_STATUS", "fires because the order status changed"],
            ["CONSTRAINT", "UQ_DISPUTE_ORDER", "one dispute per order"],
        ],
    },
    "resolve_dispute": {
        "code": "T6", "stage": 5, "title": "Administrator resolves a dispute",
        "operation": "An administrator decides for the BUYER (escrow REFUND) or the SELLER (escrow RELEASE minus fee). Money, order, listing and dispute change together (FR-14).",
        "tables": [["DISPUTES", "UPDATE decision"], ["ORDERS", "REFUNDED or COMPLETED"], ["ESCROW_TXNS", "INSERT REFUND or RELEASE"],
                   ["USERS", "wallet credited"], ["LISTINGS", "ACTIVE again or SOLD (trigger)"]],
        "components": [
            ["PROCEDURE", "RESOLVE_DISPUTE", "admin check, row lock on the dispute, money movement, COMMIT"],
            ["TRIGGER", "TRG_SYNC_LISTING_STATUS", "listing follows the order status"],
            ["CONSTRAINT", "CHK_DISPUTE_RESOLUTION", "resolved disputes must record who and when"],
        ],
    },
    "auto_release": {
        "code": "T7", "stage": 5, "title": "Nightly batch: auto-release escrow",
        "operation": "Pays every seller whose order was handed over more than 3 days ago without a dispute (FR-12).",
        "tables": [["ORDERS", "UPDATE to COMPLETED"], ["ESCROW_TXNS", "INSERT RELEASE per order"], ["USERS", "seller wallets credited"], ["LISTINGS", "SOLD (trigger)"]],
        "components": [
            ["PROCEDURE", "AUTO_RELEASE_ESCROW", "batch job"],
            ["CURSOR", "C_DUE_ORDERS (explicit: OPEN / FETCH / CLOSE, FOR UPDATE)", "one iteration per due order"],
            ["TRIGGER", "TRG_SYNC_LISTING_STATUS", "fires once per completed order"],
        ],
    },
    "submit_review": {
        "code": "T8", "stage": 5, "title": "Rate the seller",
        "operation": "The buyer rates a COMPLETED order once; the seller's trust score is recomputed from the new rating (FR-15, FR-16).",
        "tables": [["REVIEWS", "INSERT one row"], ["ORDERS", "read by the trigger"]],
        "components": [
            ["SQL", "INSERT INTO reviews ... SELECT COALESCE(MAX(review_id), 0) + 1", ""],
            ["TRIGGER", "TRG_VALIDATE_REVIEW", "Review III: only COMPLETED orders can be reviewed"],
            ["FUNCTION", "SELLER_TRUST_SCORE", "read in the after-snapshot: 70% rating + 30% disputes"],
            ["CONSTRAINT", "UQ_REVIEW_ORDER, CHK_REVIEW_RATING", "once per order, rating 1-5"],
        ],
    },
    "topup_wallet": {
        "code": "T9", "stage": 0, "title": "Top up the wallet",
        "operation": "A student adds money to the simulated wallet used for escrow holds.",
        "tables": [["USERS", "UPDATE wallet_balance"]],
        "components": [
            ["SQL", "UPDATE users SET wallet_balance = wallet_balance + :amount", ""],
            ["CONSTRAINT", "CHK_USER_WALLET", "balance can never become negative"],
        ],
    },
    "block_user": {
        "code": "T10", "stage": 0, "title": "Block / unblock a user",
        "operation": "An administrator blocks a fraudulent student (or lifts the block). Triggers then stop that student from listing or offering (FR-02).",
        "tables": [["USERS", "UPDATE is_blocked"]],
        "components": [
            ["SQL", "UPDATE users SET is_blocked = :flag WHERE role = 'STUDENT'", ""],
            ["CONSTRAINT", "CHK_USER_BLOCKED", "only 'Y' or 'N'"],
        ],
    },
    "seller_statement": {
        "code": "R3", "stage": 5, "title": "Seller account statement (report)",
        "operation": "Produces a statement of every order a seller has, with totals paid, held and refunded (FR-17).",
        "tables": [["ORDERS", "SELECT"], ["OFFERS", "SELECT"], ["LISTINGS", "SELECT"], ["USERS", "SELECT"], ["REVIEWS / DISPUTES", "SELECT (trust score)"]],
        "components": [
            ["PROCEDURE", "SELLER_STATEMENT", "Review III report procedure"],
            ["CURSOR", "C_ORDERS (cursor FOR loop)", "implicit OPEN / FETCH / CLOSE"],
            ["FUNCTION", "SELLER_TRUST_SCORE", "called at the end"],
        ],
    },
}


# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
def _int(p, key, required=True):
    v = p.get(key)
    if v in (None, ""):
        if required:
            raise AppError(f"'{key}' is required")
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        raise AppError(f"'{key}' must be a whole number") from None


def _num(p, key):
    v = p.get(key)
    if v in (None, ""):
        raise AppError(f"'{key}' is required")
    try:
        return float(v)
    except (TypeError, ValueError):
        raise AppError(f"'{key}' must be a number") from None


def _str(p, key, required=True, max_len=None):
    v = p.get(key)
    v = "" if v is None else str(v).strip()
    if required and not v:
        raise AppError(f"'{key}' is required")
    if max_len and len(v) > max_len:
        raise AppError(f"'{key}' must be at most {max_len} characters")
    return v or None


def _in(prefix, values):
    values = list(values) or [-1]
    names = [f"{prefix}{i}" for i in range(len(values))]
    return ", ".join(":" + n for n in names), dict(zip(names, values))


def render_sql(sql, binds):
    """Substitute bind values into the SQL text for display in the trace."""
    out = sql
    for key in sorted(binds or {}, key=len, reverse=True):
        v = binds[key]
        if v is None:
            lit = "NULL"
        elif isinstance(v, (int, float)):
            lit = ora_num(v)
        else:
            lit = "'" + str(v).replace("'", "''") + "'"
        out = out.replace(":" + key, lit)
    return out


def W(label, table, pk, sql, binds=None):
    return {"label": label, "table": table, "pk": pk, "sql": sql, "binds": binds or {}}


USER_COLS = "user_id, full_name, role, wallet_balance, is_blocked"
LISTING_COLS = "listing_id, seller_id, title, asking_price, status"
OFFER_COLS = "offer_id, listing_id, buyer_id, offered_price, status"
ORDER_COLS = "order_id, offer_id, platform_fee, meetup_location, status, handed_over_at"
TXN_COLS = "txn_id, order_id, txn_type, amount"
DISPUTE_COLS = "dispute_id, order_id, raised_by, status, resolved_by, resolved_on"


class Engine:
    def __init__(self, driver):
        self.driver = driver
        self.traces = []
        self._ids = itertools.count(1)
        self.lock = threading.Lock()

    # ------------------------------------------------------------ lookups
    def _q1(self, sql, binds=None):
        _, rows = self.driver.select(sql, binds)
        return rows[0] if rows else None

    def _user(self, uid):
        u = self._q1(f"SELECT {USER_COLS} FROM users WHERE user_id = :p_uid", {"p_uid": uid})
        if not u:
            raise AppError(f"User {uid} does not exist", 404)
        return u

    # --------------------------------------------------------- dispatcher
    def run(self, kind, params):
        if kind not in META:
            raise AppError(f"Unknown transaction '{kind}'", 404)
        meta = META[kind]
        actor_id = _int(params, "actor")
        actor = self._user(actor_id)
        prepare = getattr(self, f"_prep_{kind}")
        plan = prepare(params, actor)  # dict(watches, statements | procedure, result_fn, ...)

        before = [self._snapshot(w) for w in plan["watches"]]
        started = time.perf_counter()
        status, error, output, rowcounts, post = "COMMIT", None, [], [], None
        try:
            if "procedure" in plan:
                output = self.driver.call_procedure(plan["procedure"], plan["args"])
                if plan.get("read_only"):
                    status = "REPORT"
            else:
                rowcounts, post = self.driver.run_dml(
                    plan["statements"], plan.get("post_select"), plan.get("require_rows"))
        except DbError as err:
            status = "ROLLBACK"
            error = err.as_dict()
            output = getattr(err, "output", output) or output
        elapsed = round((time.perf_counter() - started) * 1000, 1)
        if status == "ROLLBACK" and error and error["code"] == "NO-ROWS":
            status = "NO CHANGE"
        after = [self._snapshot(w) for w in plan["watches"]]
        diffs = [self._diff(w, b, a) for w, b, a in zip(plan["watches"], before, after)]

        if status in ("COMMIT", "REPORT"):
            result = plan["result"](output, post, diffs) if plan.get("result") else "Done."
        elif status == "NO CHANGE":
            result = error["message"]
        else:
            result = "The database rejected the operation, so every change it started was rolled back. " \
                     "The tables are exactly as they were before."

        if plan.get("procedure"):
            executed = plan["display_sql"]
        else:
            executed = ";\n".join(render_sql(s, b) for s, b in plan["statements"]) + ";\nCOMMIT;"
        trace = {
            "id": next(self._ids),
            "kind": kind,
            "code": meta["code"],
            "title": meta["title"],
            "stage": meta["stage"],
            "stage_name": STAGES[meta["stage"]],
            "operation": meta["operation"],
            "tables": meta["tables"],
            "components": meta["components"],
            "actor": {"user_id": actor["user_id"], "full_name": actor["full_name"], "role": actor["role"]},
            "params": {k: v for k, v in params.items() if k != "actor"},
            "executed_sql": executed,
            "status": status,
            "error": error,
            "dbms_output": output,
            "rowcounts": rowcounts,
            "diffs": diffs,
            "summary": self._summary(diffs),
            "result": result,
            "elapsed_ms": elapsed,
            "at": _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "mode": self.driver.mode,
        }
        with self.lock:
            self.traces.append(trace)
            del self.traces[:-200]
        return trace

    # -------------------------------------------------- snapshot and diff
    def _snapshot(self, w):
        cols, rows = self.driver.select(w["sql"], w["binds"])
        return {"columns": cols, "rows": rows}

    @staticmethod
    def _diff(w, before, after):
        pk = w["pk"]
        cols = after["columns"] or before["columns"]
        b = {r[pk]: r for r in before["rows"]}
        a = {r[pk]: r for r in after["rows"]}
        keys = list(dict.fromkeys(list(b.keys()) + list(a.keys())))
        rows = []
        counts = {"inserted": 0, "updated": 0, "deleted": 0, "unchanged": 0}
        for k in keys:
            if k in a and k not in b:
                kind, cells = "inserted", {c: [None, a[k].get(c)] for c in cols}
            elif k in b and k not in a:
                kind, cells = "deleted", {c: [b[k].get(c), None] for c in cols}
            else:
                cells = {c: [b[k].get(c), a[k].get(c)] for c in cols}
                kind = "updated" if any(o != n for o, n in cells.values()) else "unchanged"
            counts[kind] += 1
            rows.append({"key": k, "change": kind, "cells": cells})
        return {
            "label": w["label"], "table": w["table"], "pk": pk, "columns": cols,
            "rows": rows, "counts": counts, "query": render_sql(w["sql"], w["binds"]),
        }

    @staticmethod
    def _summary(diffs):
        parts = []
        for d in diffs:
            c = d["counts"]
            bits = [f"{c[k]} {k}" for k in ("inserted", "updated", "deleted") if c[k]]
            parts.append({"table": d["table"], "label": d["label"], "text": ", ".join(bits) if bits else "no change"})
        return parts

    # ================================================================ PLANS
    def _prep_create_listing(self, p, actor):
        title = _str(p, "title", max_len=100)
        descr = _str(p, "description", required=False, max_len=500)
        cond = _str(p, "item_condition")
        price = _num(p, "asking_price")
        cat = _int(p, "category_id")
        top = self._q1("SELECT COALESCE(MAX(listing_id), 0) AS m FROM listings")["m"]
        binds = {"p_seller": actor["user_id"], "p_cat": cat, "p_title": title, "p_descr": descr,
                 "p_cond": cond.upper(), "p_price": price}
        return {
            "watches": [
                W("New listing row", "LISTINGS", "listing_id",
                  f"SELECT {LISTING_COLS}, category_id, item_condition FROM listings WHERE listing_id > :p_top ORDER BY listing_id",
                  {"p_top": top}),
                W("Seller", "USERS", "user_id", f"SELECT {USER_COLS} FROM users WHERE user_id = :p_uid", {"p_uid": actor["user_id"]}),
            ],
            "statements": [(
                "INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price)\n"
                "SELECT COALESCE(MAX(listing_id), 0) + 1, :p_seller, :p_cat, :p_title, :p_descr, :p_cond, :p_price\n"
                "  FROM listings", binds)],
            "post_select": ("SELECT MAX(listing_id) AS id FROM listings WHERE seller_id = :p_seller", {"p_seller": actor["user_id"]}),
            "result": lambda out, post, d: f"Listing {post[0]['id']} is now ACTIVE in the catalogue (status set by the column DEFAULT).",
        }

    def _prep_update_price(self, p, actor):
        lid, price = _int(p, "listing_id"), _num(p, "asking_price")
        binds = {"p_price": price, "p_lid": lid, "p_seller": actor["user_id"]}
        return {
            "watches": [W("Listing", "LISTINGS", "listing_id", f"SELECT {LISTING_COLS} FROM listings WHERE listing_id = :p_lid", {"p_lid": lid})],
            "statements": [(
                "UPDATE listings\n   SET asking_price = :p_price\n WHERE listing_id = :p_lid\n   AND seller_id = :p_seller\n   AND status = 'ACTIVE'", binds)],
            "require_rows": f"0 rows updated: listing {lid} is not an ACTIVE listing of user {actor['user_id']}.",
            "result": lambda out, post, d: f"Asking price of listing {lid} is now Rs {ora_num(price)}.",
        }

    def _prep_withdraw_listing(self, p, actor):
        lid = _int(p, "listing_id")
        b1 = {"p_lid": lid, "p_seller": actor["user_id"]}
        return {
            "watches": [
                W("Listing", "LISTINGS", "listing_id", f"SELECT {LISTING_COLS} FROM listings WHERE listing_id = :p_lid", {"p_lid": lid}),
                W("Offers on the listing", "OFFERS", "offer_id", f"SELECT {OFFER_COLS} FROM offers WHERE listing_id = :p_lid ORDER BY offer_id", {"p_lid": lid}),
            ],
            "statements": [
                ("UPDATE listings\n   SET status = 'WITHDRAWN'\n WHERE listing_id = :p_lid\n   AND seller_id = :p_seller\n   AND status = 'ACTIVE'", b1),
                ("UPDATE offers\n   SET status = 'REJECTED'\n WHERE listing_id = :p_lid\n   AND status = 'PENDING'", {"p_lid": lid}),
            ],
            "require_rows": f"0 rows updated: listing {lid} is not an ACTIVE listing of user {actor['user_id']}.",
            "result": lambda out, post, d: f"Listing {lid} withdrawn; {d[1]['counts']['updated']} pending offer(s) rejected in the same transaction.",
        }

    def _prep_make_offer(self, p, actor):
        lid, price = _int(p, "listing_id"), _num(p, "offered_price")
        binds = {"p_lid": lid, "p_buyer": actor["user_id"], "p_price": price}
        return {
            "watches": [
                W("Offers on the listing", "OFFERS", "offer_id", f"SELECT {OFFER_COLS} FROM offers WHERE listing_id = :p_lid ORDER BY offer_id", {"p_lid": lid}),
                W("Listing", "LISTINGS", "listing_id", f"SELECT {LISTING_COLS} FROM listings WHERE listing_id = :p_lid", {"p_lid": lid}),
            ],
            "statements": [(
                "INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price)\n"
                "SELECT COALESCE(MAX(offer_id), 0) + 1, :p_lid, :p_buyer, :p_price\n  FROM offers", binds)],
            "post_select": ("SELECT MAX(offer_id) AS id FROM offers WHERE buyer_id = :p_buyer", {"p_buyer": actor["user_id"]}),
            "result": lambda out, post, d: f"Offer {post[0]['id']} of Rs {ora_num(price)} recorded as PENDING; the seller can now accept it.",
        }

    def _prep_withdraw_offer(self, p, actor):
        oid = _int(p, "offer_id")
        row = self._q1("SELECT listing_id FROM offers WHERE offer_id = :p_oid", {"p_oid": oid})
        lid = row["listing_id"] if row else -1
        return {
            "watches": [W("Offers on the listing", "OFFERS", "offer_id", f"SELECT {OFFER_COLS} FROM offers WHERE listing_id = :p_lid ORDER BY offer_id", {"p_lid": lid})],
            "statements": [(
                "DELETE FROM offers\n WHERE offer_id = :p_oid\n   AND buyer_id = :p_buyer\n   AND status = 'PENDING'",
                {"p_oid": oid, "p_buyer": actor["user_id"]})],
            "require_rows": f"0 rows deleted: offer {oid} is not a PENDING offer of user {actor['user_id']}.",
            "result": lambda out, post, d: f"Offer {oid} deleted.",
        }

    def _prep_accept_offer(self, p, actor):
        oid = _int(p, "offer_id")
        meetup = _str(p, "meetup_location", max_len=60)
        info = self._q1(
            "SELECT f.listing_id, f.buyer_id, l.seller_id FROM offers f JOIN listings l ON l.listing_id = f.listing_id WHERE f.offer_id = :p_oid",
            {"p_oid": oid}) or {"listing_id": -1, "buyer_id": -1, "seller_id": -1}
        ul, ub = _in("p_u", [info["buyer_id"], info["seller_id"]])
        return {
            "watches": [
                W("Offers on the listing", "OFFERS", "offer_id", f"SELECT {OFFER_COLS} FROM offers WHERE listing_id = :p_lid ORDER BY offer_id", {"p_lid": info["listing_id"]}),
                W("Listing", "LISTINGS", "listing_id", f"SELECT {LISTING_COLS} FROM listings WHERE listing_id = :p_lid", {"p_lid": info["listing_id"]}),
                W("Buyer and seller wallets", "USERS", "user_id", f"SELECT {USER_COLS} FROM users WHERE user_id IN ({ul}) ORDER BY user_id", ub),
                W("Order", "ORDERS", "order_id", f"SELECT {ORDER_COLS} FROM orders WHERE offer_id = :p_oid", {"p_oid": oid}),
                W("Escrow ledger", "ESCROW_TXNS", "txn_id",
                  f"SELECT {TXN_COLS} FROM escrow_txns WHERE order_id IN (SELECT order_id FROM orders WHERE offer_id = :p_oid) ORDER BY txn_id", {"p_oid": oid}),
            ],
            "procedure": "accept_offer",
            "args": [oid, actor["user_id"], meetup],
            "display_sql": render_sql("BEGIN\n    accept_offer(p_offer_id  => :o,\n                 p_seller_id => :s,\n                 p_meetup    => :m);\nEND;",
                                      {"o": oid, "s": actor["user_id"], "m": meetup}),
            "result": lambda out, post, d: " ".join(out) if out else "Offer accepted.",
        }

    def _prep_mark_handed_over(self, p, actor):
        oid = _int(p, "order_id")
        lid = (self._q1("SELECT f.listing_id FROM orders o JOIN offers f ON f.offer_id = o.offer_id WHERE o.order_id = :p_oid", {"p_oid": oid}) or {"listing_id": -1})["listing_id"]
        return {
            "watches": [
                W("Order", "ORDERS", "order_id", f"SELECT {ORDER_COLS} FROM orders WHERE order_id = :p_oid", {"p_oid": oid}),
                W("Listing", "LISTINGS", "listing_id", f"SELECT {LISTING_COLS} FROM listings WHERE listing_id = :p_lid", {"p_lid": lid}),
            ],
            "procedure": "mark_handed_over",
            "args": [oid, actor["user_id"]],
            "display_sql": render_sql("BEGIN\n    mark_handed_over(p_order_id  => :o,\n                     p_seller_id => :s);\nEND;", {"o": oid, "s": actor["user_id"]}),
            "result": lambda out, post, d: out[0] if out else "Handover recorded.",
        }

    def _prep_raise_dispute(self, p, actor):
        oid = _int(p, "order_id")
        reason = _str(p, "reason", max_len=300)
        lid = (self._q1("SELECT f.listing_id FROM orders o JOIN offers f ON f.offer_id = o.offer_id WHERE o.order_id = :p_oid", {"p_oid": oid}) or {"listing_id": -1})["listing_id"]
        binds = {"p_oid": oid, "p_user": actor["user_id"], "p_reason": reason}
        return {
            "watches": [
                W("Dispute", "DISPUTES", "dispute_id", f"SELECT {DISPUTE_COLS} FROM disputes WHERE order_id = :p_oid", {"p_oid": oid}),
                W("Order", "ORDERS", "order_id", f"SELECT {ORDER_COLS} FROM orders WHERE order_id = :p_oid", {"p_oid": oid}),
                W("Listing", "LISTINGS", "listing_id", f"SELECT {LISTING_COLS} FROM listings WHERE listing_id = :p_lid", {"p_lid": lid}),
            ],
            "statements": [(
                "INSERT INTO disputes (dispute_id, order_id, raised_by, reason)\n"
                "SELECT COALESCE(MAX(dispute_id), 0) + 1, :p_oid, :p_user, :p_reason\n  FROM disputes", binds)],
            "post_select": ("SELECT dispute_id AS id FROM disputes WHERE order_id = :p_oid", {"p_oid": oid}),
            "result": lambda out, post, d: f"Dispute {post[0]['id']} is OPEN. The trigger froze order {oid} as DISPUTED, so its escrow cannot be auto-released.",
        }

    def _prep_resolve_dispute(self, p, actor):
        did = _int(p, "dispute_id")
        decision = (_str(p, "decision") or "").upper()
        info = self._q1(
            """SELECT d.order_id, f.listing_id, f.buyer_id, l.seller_id FROM disputes d
                 JOIN orders o ON o.order_id = d.order_id JOIN offers f ON f.offer_id = o.offer_id
                 JOIN listings l ON l.listing_id = f.listing_id WHERE d.dispute_id = :p_did""",
            {"p_did": did}) or {"order_id": -1, "listing_id": -1, "buyer_id": -1, "seller_id": -1}
        ul, ub = _in("p_u", [info["buyer_id"], info["seller_id"]])
        return {
            "watches": [
                W("Dispute", "DISPUTES", "dispute_id", f"SELECT {DISPUTE_COLS} FROM disputes WHERE dispute_id = :p_did", {"p_did": did}),
                W("Order", "ORDERS", "order_id", f"SELECT {ORDER_COLS} FROM orders WHERE order_id = :p_oid", {"p_oid": info["order_id"]}),
                W("Escrow ledger", "ESCROW_TXNS", "txn_id", f"SELECT {TXN_COLS} FROM escrow_txns WHERE order_id = :p_oid ORDER BY txn_id", {"p_oid": info["order_id"]}),
                W("Buyer and seller wallets", "USERS", "user_id", f"SELECT {USER_COLS} FROM users WHERE user_id IN ({ul}) ORDER BY user_id", ub),
                W("Listing", "LISTINGS", "listing_id", f"SELECT {LISTING_COLS} FROM listings WHERE listing_id = :p_lid", {"p_lid": info["listing_id"]}),
            ],
            "procedure": "resolve_dispute",
            "args": [did, actor["user_id"], decision],
            "display_sql": render_sql("BEGIN\n    resolve_dispute(p_dispute_id => :d,\n                    p_admin_id   => :a,\n                    p_decision   => :x);\nEND;",
                                      {"d": did, "a": actor["user_id"], "x": decision}),
            "result": lambda out, post, d: out[0] if out else "Dispute resolved.",
        }

    def _prep_auto_release(self, p, actor):
        days = _int(p, "days", required=False) or 3
        _, rows = self.driver.select("SELECT order_id FROM orders WHERE status = 'HANDED_OVER' ORDER BY order_id")
        ids = [r["order_id"] for r in rows]
        ol, ob = _in("p_o", ids)
        return {
            "watches": [
                W("Orders waiting for release", "ORDERS", "order_id", f"SELECT {ORDER_COLS} FROM orders WHERE order_id IN ({ol}) ORDER BY order_id", ob),
                W("Escrow ledger", "ESCROW_TXNS", "txn_id", f"SELECT {TXN_COLS} FROM escrow_txns WHERE order_id IN ({ol}) ORDER BY txn_id", ob),
                W("Seller wallets", "USERS", "user_id",
                  f"""SELECT {USER_COLS} FROM users WHERE user_id IN (SELECT l.seller_id FROM orders o JOIN offers f ON f.offer_id = o.offer_id
                       JOIN listings l ON l.listing_id = f.listing_id WHERE o.order_id IN ({ol})) ORDER BY user_id""", ob),
                W("Listings", "LISTINGS", "listing_id",
                  f"""SELECT {LISTING_COLS} FROM listings WHERE listing_id IN (SELECT f.listing_id FROM orders o JOIN offers f ON f.offer_id = o.offer_id
                       WHERE o.order_id IN ({ol})) ORDER BY listing_id""", ob),
            ],
            "procedure": "auto_release_escrow",
            "args": [days],
            "display_sql": f"BEGIN\n    auto_release_escrow(p_days => {days});\nEND;",
            "result": lambda out, post, d: out[-1] if out else "Batch finished.",
        }

    def _prep_submit_review(self, p, actor):
        oid = _int(p, "order_id")
        rating = _int(p, "rating")
        comment = _str(p, "comment", required=False, max_len=300)
        info = self._q1(
            "SELECT f.buyer_id, l.seller_id FROM orders o JOIN offers f ON f.offer_id = o.offer_id JOIN listings l ON l.listing_id = f.listing_id WHERE o.order_id = :p_oid",
            {"p_oid": oid})
        if info and info["buyer_id"] != actor["user_id"]:
            raise AppError(f"Only the buyer of order {oid} (user {info['buyer_id']}) can review it", 403)
        seller = info["seller_id"] if info else -1
        return {
            "watches": [
                W("Review", "REVIEWS", "review_id", "SELECT review_id, order_id, rating, review_comment FROM reviews WHERE order_id = :p_oid", {"p_oid": oid}),
                W("Seller trust score (function)", "USERS", "user_id",
                  "SELECT user_id, full_name, seller_trust_score(user_id) AS trust_score FROM users WHERE user_id = :p_sid", {"p_sid": seller}),
            ],
            "statements": [(
                "INSERT INTO reviews (review_id, order_id, rating, review_comment)\n"
                "SELECT COALESCE(MAX(review_id), 0) + 1, :p_oid, :p_rating, :p_comment\n  FROM reviews",
                {"p_oid": oid, "p_rating": rating, "p_comment": comment})],
            "result": lambda out, post, d: self._review_result(d, rating),
        }

    @staticmethod
    def _review_result(diffs, rating):
        cells = diffs[1]["rows"][0]["cells"] if diffs[1]["rows"] else {}
        old, new = cells.get("trust_score", [None, None])
        return f"{rating}-star review saved. Seller trust score {ora_num(old) if old is not None else 'n/a'} -> {ora_num(new)}."

    def _prep_topup_wallet(self, p, actor):
        amount = _num(p, "amount")
        if amount <= 0 or amount > 50000:
            raise AppError("Top-up amount must be between 1 and 50000")
        return {
            "watches": [W("Wallet", "USERS", "user_id", f"SELECT {USER_COLS} FROM users WHERE user_id = :p_uid", {"p_uid": actor["user_id"]})],
            "statements": [("UPDATE users\n   SET wallet_balance = wallet_balance + :p_amt\n WHERE user_id = :p_uid",
                            {"p_amt": amount, "p_uid": actor["user_id"]})],
            "result": lambda out, post, d: f"Wallet credited with Rs {ora_num(amount)}.",
        }

    def _prep_block_user(self, p, actor):
        if actor["role"] != "ADMIN":
            raise AppError("Only an administrator can block or unblock users", 403)
        uid = _int(p, "user_id")
        flag = (_str(p, "blocked") or "Y").upper()
        return {
            "watches": [W("User", "USERS", "user_id", f"SELECT {USER_COLS} FROM users WHERE user_id = :p_uid", {"p_uid": uid})],
            "statements": [("UPDATE users\n   SET is_blocked = :p_flag\n WHERE user_id = :p_uid\n   AND role = 'STUDENT'", {"p_flag": flag, "p_uid": uid})],
            "require_rows": f"0 rows updated: user {uid} is not a student.",
            "result": lambda out, post, d: f"User {uid} is now {'BLOCKED' if flag == 'Y' else 'unblocked'}.",
        }

    def _prep_seller_statement(self, p, actor):
        sid = _int(p, "seller_id", required=False) or actor["user_id"]
        return {
            "watches": [],
            "procedure": "seller_statement",
            "args": [sid],
            "read_only": True,
            "display_sql": f"BEGIN\n    seller_statement(p_seller_id => {sid});\nEND;",
            "result": lambda out, post, d: f"Statement generated ({len(out)} DBMS_OUTPUT lines). Read-only: no table changed.",
        }
