-- ============================================================================
-- CampusKart SQLite MIRROR schema (offline demonstration mode only)
-- A line-by-line translation of database/CampusKart_Review3.sql:
--   * same tables, columns, constraint names, CHECK rules and foreign keys
--   * the five triggers rewritten in SQLite trigger syntax; ck_raise(code, msg)
--     is a Python function that stops the statement with the same ORA-2xxxx
--     error the Oracle trigger raises
--   * the procedures and functions are ported to Python in mirror_driver.py
-- The Oracle script remains the reference implementation.
-- ============================================================================
PRAGMA foreign_keys = ON;

DROP VIEW IF EXISTS order_details_v;
DROP TABLE IF EXISTS disputes;
DROP TABLE IF EXISTS reviews;
DROP TABLE IF EXISTS escrow_txns;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS offers;
DROP TABLE IF EXISTS listings;
DROP TABLE IF EXISTS categories;
DROP TABLE IF EXISTS users;

CREATE TABLE users (
    user_id         INTEGER         NOT NULL,
    reg_no          VARCHAR(9),
    full_name       VARCHAR(60)     NOT NULL,
    email           VARCHAR(80)     NOT NULL,
    phone           VARCHAR(10)     NOT NULL,
    hostel_block    VARCHAR(10),
    role            VARCHAR(10)     NOT NULL DEFAULT 'STUDENT',
    wallet_balance  NUMERIC(10,2)   NOT NULL DEFAULT 0,
    is_blocked      CHAR(1)         NOT NULL DEFAULT 'N',
    created_at      DATE            NOT NULL DEFAULT (datetime('now', 'localtime')),
    CONSTRAINT pk_users         PRIMARY KEY (user_id),
    CONSTRAINT uq_user_regno    UNIQUE (reg_no),
    CONSTRAINT uq_user_email    UNIQUE (email),
    CONSTRAINT uq_user_phone    UNIQUE (phone),
    CONSTRAINT chk_user_email   CHECK (email LIKE '%@vitstudent.ac.in' OR email LIKE '%@vit.ac.in'),
    CONSTRAINT chk_user_phone   CHECK (LENGTH(phone) = 10),
    CONSTRAINT chk_user_role    CHECK (role IN ('STUDENT', 'ADMIN')),
    CONSTRAINT chk_user_regno   CHECK (role = 'ADMIN' OR reg_no IS NOT NULL),
    CONSTRAINT chk_user_wallet  CHECK (wallet_balance >= 0),
    CONSTRAINT chk_user_blocked CHECK (is_blocked IN ('Y', 'N'))
);

CREATE TABLE categories (
    category_id     INTEGER         NOT NULL,
    category_name   VARCHAR(40)     NOT NULL,
    fee_percent     NUMERIC(4,2)    NOT NULL DEFAULT 5,
    description     VARCHAR(200),
    CONSTRAINT pk_categories     PRIMARY KEY (category_id),
    CONSTRAINT uq_category_name  UNIQUE (category_name),
    CONSTRAINT chk_category_fee  CHECK (fee_percent BETWEEN 0 AND 20)
);

CREATE TABLE listings (
    listing_id      INTEGER         NOT NULL,
    seller_id       INTEGER         NOT NULL,
    category_id     INTEGER         NOT NULL,
    title           VARCHAR(100)    NOT NULL,
    description     VARCHAR(500),
    item_condition  VARCHAR(10)     NOT NULL,
    asking_price    NUMERIC(10,2)   NOT NULL,
    status          VARCHAR(10)     NOT NULL DEFAULT 'ACTIVE',
    listed_on       DATE            NOT NULL DEFAULT (datetime('now', 'localtime')),
    CONSTRAINT pk_listings            PRIMARY KEY (listing_id),
    CONSTRAINT fk_listing_seller      FOREIGN KEY (seller_id)   REFERENCES users (user_id),
    CONSTRAINT fk_listing_category    FOREIGN KEY (category_id) REFERENCES categories (category_id),
    CONSTRAINT chk_listing_condition  CHECK (item_condition IN ('NEW', 'LIKE_NEW', 'GOOD', 'FAIR')),
    CONSTRAINT chk_listing_price      CHECK (asking_price > 0),
    CONSTRAINT chk_listing_status     CHECK (status IN ('ACTIVE', 'RESERVED', 'SOLD', 'WITHDRAWN'))
);

CREATE TABLE offers (
    offer_id        INTEGER         NOT NULL,
    listing_id      INTEGER         NOT NULL,
    buyer_id        INTEGER         NOT NULL,
    offered_price   NUMERIC(10,2)   NOT NULL,
    status          VARCHAR(10)     NOT NULL DEFAULT 'PENDING',
    offered_on      DATE            NOT NULL DEFAULT (datetime('now', 'localtime')),
    CONSTRAINT pk_offers          PRIMARY KEY (offer_id),
    CONSTRAINT fk_offer_listing   FOREIGN KEY (listing_id) REFERENCES listings (listing_id),
    CONSTRAINT fk_offer_buyer     FOREIGN KEY (buyer_id)   REFERENCES users (user_id),
    CONSTRAINT chk_offer_price    CHECK (offered_price > 0),
    CONSTRAINT chk_offer_status   CHECK (status IN ('PENDING', 'ACCEPTED', 'REJECTED', 'WITHDRAWN'))
);

CREATE TABLE orders (
    order_id        INTEGER         NOT NULL,
    offer_id        INTEGER         NOT NULL,
    platform_fee    NUMERIC(10,2)   NOT NULL DEFAULT 0,
    meetup_location VARCHAR(60)     NOT NULL,
    status          VARCHAR(12)     NOT NULL DEFAULT 'CREATED',
    created_at      DATE            NOT NULL DEFAULT (datetime('now', 'localtime')),
    handed_over_at  DATE,
    CONSTRAINT pk_orders           PRIMARY KEY (order_id),
    CONSTRAINT fk_order_offer      FOREIGN KEY (offer_id) REFERENCES offers (offer_id),
    CONSTRAINT uq_order_offer      UNIQUE (offer_id),
    CONSTRAINT chk_order_fee       CHECK (platform_fee >= 0),
    CONSTRAINT chk_order_status    CHECK (status IN ('CREATED', 'HANDED_OVER', 'COMPLETED',
                                                     'DISPUTED', 'REFUNDED', 'CANCELLED')),
    CONSTRAINT chk_order_handover  CHECK (handed_over_at IS NULL OR handed_over_at >= created_at)
);

CREATE TABLE escrow_txns (
    txn_id          INTEGER         NOT NULL,
    order_id        INTEGER         NOT NULL,
    txn_type        VARCHAR(8)      NOT NULL,
    amount          NUMERIC(10,2)   NOT NULL,
    txn_time        TIMESTAMP       NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%f', 'now', 'localtime')),
    CONSTRAINT pk_escrow_txns   PRIMARY KEY (txn_id),
    CONSTRAINT fk_txn_order     FOREIGN KEY (order_id) REFERENCES orders (order_id),
    CONSTRAINT chk_txn_type     CHECK (txn_type IN ('HOLD', 'RELEASE', 'REFUND')),
    CONSTRAINT chk_txn_amount   CHECK (amount > 0)
);

CREATE TABLE reviews (
    review_id       INTEGER         NOT NULL,
    order_id        INTEGER         NOT NULL,
    rating          INTEGER         NOT NULL,
    review_comment  VARCHAR(300),
    reviewed_on     DATE            NOT NULL DEFAULT (datetime('now', 'localtime')),
    CONSTRAINT pk_reviews         PRIMARY KEY (review_id),
    CONSTRAINT fk_review_order    FOREIGN KEY (order_id) REFERENCES orders (order_id),
    CONSTRAINT uq_review_order    UNIQUE (order_id),
    CONSTRAINT chk_review_rating  CHECK (rating BETWEEN 1 AND 5)
);

CREATE TABLE disputes (
    dispute_id      INTEGER         NOT NULL,
    order_id        INTEGER         NOT NULL,
    raised_by       INTEGER         NOT NULL,
    resolved_by     INTEGER,
    reason          VARCHAR(300)    NOT NULL,
    status          VARCHAR(16)     NOT NULL DEFAULT 'OPEN',
    raised_on       DATE            NOT NULL DEFAULT (datetime('now', 'localtime')),
    resolved_on     DATE,
    CONSTRAINT pk_disputes              PRIMARY KEY (dispute_id),
    CONSTRAINT fk_dispute_order         FOREIGN KEY (order_id)    REFERENCES orders (order_id),
    CONSTRAINT uq_dispute_order         UNIQUE (order_id),
    CONSTRAINT fk_dispute_raised_by     FOREIGN KEY (raised_by)   REFERENCES users (user_id),
    CONSTRAINT fk_dispute_resolved_by   FOREIGN KEY (resolved_by) REFERENCES users (user_id),
    CONSTRAINT chk_dispute_status       CHECK (status IN ('OPEN', 'RESOLVED_BUYER', 'RESOLVED_SELLER')),
    CONSTRAINT chk_dispute_resolved_on  CHECK (resolved_on IS NULL OR resolved_on >= raised_on),
    CONSTRAINT chk_dispute_resolution   CHECK (
        (status = 'OPEN'  AND resolved_by IS NULL     AND resolved_on IS NULL) OR
        (status <> 'OPEN' AND resolved_by IS NOT NULL AND resolved_on IS NOT NULL))
);

CREATE VIEW order_details_v AS
SELECT o.order_id, f.offer_id, l.listing_id, l.title, c.category_name,
       l.seller_id, s.full_name AS seller_name,
       f.buyer_id,  b.full_name AS buyer_name,
       f.offered_price AS final_price, o.platform_fee,
       f.offered_price - o.platform_fee AS seller_payout,
       o.status AS order_status, o.created_at, o.handed_over_at
  FROM orders o
  JOIN offers     f ON f.offer_id    = o.offer_id
  JOIN listings   l ON l.listing_id  = f.listing_id
  JOIN categories c ON c.category_id = l.category_id
  JOIN users      s ON s.user_id     = l.seller_id
  JOIN users      b ON b.user_id     = f.buyer_id;
