"""
CampusKart web server (Flask).

The browser never sees SQL it could change: it sends an operation name and
parameters, the server binds them into fixed statements (bind variables, no
string concatenation), and returns rows and transaction traces as JSON.
"""

import sys
import traceback

from flask import Flask, jsonify, request, send_from_directory
from werkzeug.exceptions import HTTPException

from . import config
from .db.common import AppError, DbError
from .db.sqlscript import extract_object_sources
from .presets import PRESETS
from .reports import REPORT_INDEX, REPORTS
from .transactions import META, STAGES, Engine

TABLES = ["USERS", "CATEGORIES", "LISTINGS", "OFFERS", "ORDERS", "ESCROW_TXNS", "REVIEWS", "DISPUTES"]

PLSQL_OBJECTS = [
    # (name, type, review, purpose)
    ("CALC_PLATFORM_FEE", "FUNCTION", "II", "Fee for a sale = price x category fee percent"),
    ("SELLER_TRUST_SCORE", "FUNCTION", "II", "0-100 score from ratings (70) and disputes lost (30)"),
    ("ESCROW_BALANCE", "FUNCTION", "III", "Money the platform still holds for one order"),
    ("ACCEPT_OFFER", "PROCEDURE", "II", "Offer -> order + escrow HOLD, atomically"),
    ("RESOLVE_DISPUTE", "PROCEDURE", "II", "Admin decision: REFUND buyer or RELEASE to seller"),
    ("AUTO_RELEASE_ESCROW", "PROCEDURE", "II", "Batch job with explicit cursor C_DUE_ORDERS"),
    ("MARK_HANDED_OVER", "PROCEDURE", "III", "Seller records the physical handover"),
    ("SELLER_STATEMENT", "PROCEDURE", "III", "Report with cursor FOR loop and DBMS_OUTPUT"),
    ("TRG_VALIDATE_LISTING", "TRIGGER", "II", "BEFORE INSERT ON listings: blocked sellers"),
    ("TRG_VALIDATE_OFFER", "TRIGGER", "II", "BEFORE INSERT ON offers: own listing, status, blocked"),
    ("TRG_SYNC_LISTING_STATUS", "TRIGGER", "II", "AFTER INSERT/UPDATE OF status ON orders"),
    ("TRG_ON_DISPUTE_RAISED", "TRIGGER", "II", "BEFORE INSERT ON disputes: freezes the order"),
    ("TRG_VALIDATE_REVIEW", "TRIGGER", "III", "BEFORE INSERT ON reviews: only COMPLETED orders"),
    ("ORDER_DETAILS_V", "VIEW", "II", "Order + offer + listing + category + buyer + seller"),
]


def make_driver():
    """Pick Oracle or the SQLite mirror according to CK_DB_MODE."""
    mode = config.DB_MODE
    note = None
    if mode in ("oracle", "auto"):
        if config.ORACLE_USER:
            try:
                from .db.oracle_driver import OracleDriver

                return OracleDriver(config.ORACLE_USER, config.ORACLE_PASSWORD, config.ORACLE_DSN,
                                    config.SQL_SCRIPT), None
            except Exception as exc:  # noqa: BLE001
                if mode == "oracle":
                    raise
                note = f"Oracle not reachable ({exc}). Running on the SQLite mirror."
        elif mode == "oracle":
            raise RuntimeError("CK_DB_MODE=oracle but ORACLE_USER is not set (see .env.example)")
        else:
            note = "ORACLE_USER not set: running on the SQLite mirror. Fill in .env to use Oracle."
    from .db.mirror_driver import MirrorDriver

    drv = MirrorDriver(config.MIRROR_DB, config.MIRROR_SCHEMA,
                       config.ROOT / "app" / "db" / "mirror_triggers.sql", config.SQL_SCRIPT)
    return drv, note


def create_app():
    driver, note = make_driver()
    engine = Engine(driver)
    sources = extract_object_sources(config.SQL_SCRIPT.read_text(encoding="utf-8"))
    app = Flask(__name__, static_folder=None)
    app.config["JSON_SORT_KEYS"] = False

    def rows(sql, binds=None):
        return driver.select(sql, binds)[1]

    # ------------------------------------------------------------ errors
    @app.errorhandler(AppError)
    def _app_error(err):
        return jsonify({"error": err.message}), err.status

    @app.errorhandler(DbError)
    def _db_error(err):
        return jsonify({"error": f"{err.code}: {err.message}", "code": err.code}), 500

    @app.errorhandler(Exception)
    def _any_error(err):  # pragma: no cover
        if isinstance(err, HTTPException):  # 404 for a font that is not bundled, etc.
            return err
        traceback.print_exc()
        return jsonify({"error": str(err)}), 500

    # ------------------------------------------------------------ static
    @app.get("/")
    def index():
        return send_from_directory(config.WEB_DIR, "index.html")

    @app.get("/<path:path>")
    def static_files(path):
        return send_from_directory(config.WEB_DIR, path)

    # ------------------------------------------------------------ status
    @app.get("/api/status")
    def status():
        counts = {}
        ready = True
        for t in TABLES:
            try:
                counts[t] = rows(f"SELECT COUNT(*) AS n FROM {t.lower()}")[0]["n"]
            except DbError:
                counts[t] = None
                ready = False
        return jsonify({**driver.info(), "note": note, "schema_ready": ready, "counts": counts})

    @app.get("/api/meta")
    def meta():
        return jsonify({
            "transactions": META, "stages": STAGES, "presets": PRESETS,
            "objects": [{"name": n, "type": t, "review": r, "purpose": p} for n, t, r, p in PLSQL_OBJECTS],
            "reports": [{k: v for k, v in r.items() if k != "sql"} | {"sql": r["sql"]} for r in REPORTS],
        })

    @app.get("/api/source/<name>")
    def source(name):
        obj = sources.get(name.upper())
        if not obj:
            raise AppError(f"No source for {name}", 404)
        return jsonify(obj)

    # ------------------------------------------------------------- users
    @app.get("/api/users")
    def users():
        return jsonify(rows(
            """SELECT user_id, reg_no, full_name, email, hostel_block, role, wallet_balance, is_blocked,
                      seller_trust_score(user_id) AS trust_score
                 FROM users
                ORDER BY CASE role WHEN 'STUDENT' THEN 0 ELSE 1 END, user_id"""))

    @app.get("/api/categories")
    def categories():
        return jsonify(rows("SELECT category_id, category_name, fee_percent, description FROM categories ORDER BY category_name"))

    # ---------------------------------------------------------- listings
    @app.get("/api/listings")
    def listings():
        a = request.args
        where, binds = [], {}
        status = a.get("status", "ACTIVE")
        if status and status != "ALL":
            where.append("l.status = :p_status")
            binds["p_status"] = status
        if a.get("category"):
            where.append("l.category_id = :p_cat")
            binds["p_cat"] = int(a["category"])
        if a.get("condition"):
            where.append("l.item_condition = :p_cond")
            binds["p_cond"] = a["condition"]
        if a.get("max_price"):
            where.append("l.asking_price <= :p_max")  # Q1
            binds["p_max"] = float(a["max_price"])
        if a.get("q"):
            where.append("UPPER(l.title) LIKE '%' || UPPER(:p_q) || '%'")  # Q2
            binds["p_q"] = a["q"].strip()
        if a.get("seller"):
            where.append("l.seller_id = :p_seller")
            binds["p_seller"] = int(a["seller"])
        sql = """SELECT l.listing_id, l.title, l.description, l.item_condition, l.asking_price, l.status, l.listed_on,
                        c.category_id, c.category_name, c.fee_percent,
                        u.user_id AS seller_id, u.full_name AS seller, u.hostel_block,
                        seller_trust_score(u.user_id) AS seller_trust,
                        (SELECT COUNT(*) FROM offers f WHERE f.listing_id = l.listing_id AND f.status = 'PENDING') AS pending_offers
                   FROM listings l
                   JOIN users u      ON u.user_id     = l.seller_id
                   JOIN categories c ON c.category_id = l.category_id"""  # Q3
        if where:
            sql += "\n  WHERE " + "\n    AND ".join(where)
        sql += "\n  ORDER BY l.listing_id DESC"
        return jsonify({"sql": sql, "rows": rows(sql, binds)})

    @app.get("/api/listings/<int:lid>")
    def listing(lid):
        found = rows(
            """SELECT l.listing_id, l.title, l.description, l.item_condition, l.asking_price, l.status, l.listed_on,
                      c.category_name, c.fee_percent, u.user_id AS seller_id, u.full_name AS seller, u.hostel_block,
                      seller_trust_score(u.user_id) AS seller_trust,
                      calc_platform_fee(l.listing_id, l.asking_price) AS fee_at_asking
                 FROM listings l
                 JOIN users u      ON u.user_id     = l.seller_id
                 JOIN categories c ON c.category_id = l.category_id
                WHERE l.listing_id = :p_lid""", {"p_lid": lid})
        if not found:
            raise AppError(f"Listing {lid} does not exist", 404)
        offers = rows(
            """SELECT f.offer_id, f.buyer_id, u.full_name AS buyer, u.wallet_balance AS buyer_wallet,
                      f.offered_price, f.status, f.offered_on
                 FROM offers f JOIN users u ON u.user_id = f.buyer_id
                WHERE f.listing_id = :p_lid
                ORDER BY f.offered_price DESC, f.offer_id""", {"p_lid": lid})
        return jsonify({"listing": found[0], "offers": offers})

    # ------------------------------------------------------------ orders
    @app.get("/api/orders")
    def orders():
        uid = request.args.get("user", type=int)
        sql = """SELECT v.*, d.dispute_id, d.status AS dispute_status, d.reason AS dispute_reason,
                        r.rating, r.review_comment
                   FROM order_details_v v
                   LEFT JOIN disputes d ON d.order_id = v.order_id
                   LEFT JOIN reviews  r ON r.order_id = v.order_id"""
        binds = {}
        if uid:
            sql += "\n  WHERE v.buyer_id = :p_u OR v.seller_id = :p_u"
            binds["p_u"] = uid
        sql += "\n  ORDER BY v.order_id DESC"
        return jsonify(rows(sql, binds))

    @app.get("/api/admin")
    def admin():
        disputes = rows(
            """SELECT d.dispute_id, d.order_id, l.title, r.full_name AS raised_by, d.reason,
                      TO_CHAR(d.raised_on, 'DD-MON-YYYY') AS raised_on,
                      f.offered_price AS price, o.platform_fee, b.full_name AS buyer, s.full_name AS seller
                 FROM disputes d
                 JOIN orders   o ON o.order_id   = d.order_id
                 JOIN offers   f ON f.offer_id   = o.offer_id
                 JOIN listings l ON l.listing_id = f.listing_id
                 JOIN users    r ON r.user_id    = d.raised_by
                 JOIN users    b ON b.user_id    = f.buyer_id
                 JOIN users    s ON s.user_id    = l.seller_id
                WHERE d.status = 'OPEN'
                ORDER BY d.raised_on, d.dispute_id""")  # Q17 (+ money columns)
        cutoff = driver.cutoff_sql(3)
        handed = rows(
            f"""SELECT o.order_id, l.title, o.handed_over_at,
                       CASE WHEN o.handed_over_at <= {cutoff} THEN 'YES' ELSE 'NO' END AS window_over,
                       f.offered_price - o.platform_fee AS payout, s.full_name AS seller
                  FROM orders o
                  JOIN offers   f ON f.offer_id   = o.offer_id
                  JOIN listings l ON l.listing_id = f.listing_id
                  JOIN users    s ON s.user_id    = l.seller_id
                 WHERE o.status = 'HANDED_OVER'
                 ORDER BY o.order_id""")
        return jsonify({"disputes": disputes, "handed_over": handed})

    # ------------------------------------------------------------ ledger
    @app.get("/api/ledger")
    def ledger():
        txns = rows(
            """SELECT t.txn_id, t.order_id, t.txn_type, t.amount, t.txn_time, l.title
                 FROM escrow_txns t
                 JOIN orders   o ON o.order_id   = t.order_id
                 JOIN offers   f ON f.offer_id   = o.offer_id
                 JOIN listings l ON l.listing_id = f.listing_id
                ORDER BY t.txn_id DESC""")
        totals = rows(REPORT_INDEX["Q11"]["sql"])[0]
        by_cat = rows(REPORT_INDEX["Q6"]["sql"])
        recon = rows(REPORT_INDEX["R1"]["sql"])
        wallets = rows("SELECT user_id, full_name, role, wallet_balance, is_blocked FROM users ORDER BY wallet_balance DESC, user_id")
        return jsonify({"txns": txns, "totals": totals, "by_category": by_cat, "reconciliation": recon, "wallets": wallets})

    @app.get("/api/overview")
    def overview():
        def one(sql):
            return rows(sql)[0]["n"]
        return jsonify({
            "active_listings": one("SELECT COUNT(*) AS n FROM listings WHERE status = 'ACTIVE'"),
            "pending_offers": one("SELECT COUNT(*) AS n FROM offers WHERE status = 'PENDING'"),
            "open_orders": one("SELECT COUNT(*) AS n FROM orders WHERE status IN ('CREATED', 'HANDED_OVER', 'DISPUTED')"),
            "open_disputes": one("SELECT COUNT(*) AS n FROM disputes WHERE status = 'OPEN'"),
            "created_orders": one("SELECT COUNT(*) AS n FROM orders WHERE status = 'CREATED'"),
            "handed_over_orders": one("SELECT COUNT(*) AS n FROM orders WHERE status = 'HANDED_OVER'"),
            "completed_orders": one("SELECT COUNT(*) AS n FROM orders WHERE status = 'COMPLETED'"),
            "in_escrow": rows(REPORT_INDEX["Q11"]["sql"])[0]["currently_in_escrow"],
            "platform_revenue": one("SELECT COALESCE(SUM(platform_fee), 0) AS n FROM orders WHERE status = 'COMPLETED'"),
        })

    # ----------------------------------------------------------- reports
    @app.get("/api/reports/<key>")
    def report(key):
        r = REPORT_INDEX.get(key.upper())
        if not r:
            raise AppError(f"Unknown report {key}", 404)
        cols, data = driver.select(r["sql"])
        return jsonify({**r, "columns": cols, "rows": data})

    # ------------------------------------------------------ transactions
    @app.post("/api/tx/<kind>")
    def run_tx(kind):
        params = request.get_json(silent=True) or {}
        return jsonify(engine.run(kind, params))

    @app.get("/api/traces")
    def traces():
        return jsonify(list(reversed(engine.traces)))

    @app.post("/api/reset")
    def reset():
        report = driver.reset()
        engine.traces.clear()
        return jsonify({"message": f"Database rebuilt from CampusKart_Review3.sql "
                                   f"({report['statements']} statements, {report['seconds']} s).", **report})

    return app


def main():
    try:
        app = create_app()
    except Exception as exc:  # noqa: BLE001
        print(f"\n[CampusKart] could not start: {exc}\n", file=sys.stderr)
        raise SystemExit(1)
    print(f"\n  CampusKart running on http://127.0.0.1:{config.PORT}\n")
    app.run(host="127.0.0.1", port=config.PORT, debug=False, threaded=True)
