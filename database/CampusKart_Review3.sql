-- ============================================================================
-- CampusKart: Peer-to-Peer Campus Resale Marketplace with Escrow
-- BCSE302L Database Systems - Course Project - Review III (Integrated System)
-- Team: Parthiban M (24BYB0135), Sriram K (24BYB0151), Vimalaadhityan (24BYB0145)
--
-- This one file builds the complete database used by the CampusKart application:
--   Sections 0-2  tables, constraints and sample data          (from Review II)
--   Section 3     view ORDER_DETAILS_V                         (from Review II)
--   Sections 4-6  functions, triggers, procedures with cursor  (from Review II)
--   Section 7     Review III additions used by the application
--   Section 8     object inventory (every object must be VALID)
--
-- Run:  SQL*Plus       @CampusKart_Review3.sql
--       SQL Developer  open the file and press F5 (Run Script)
--       Application    python setup_db.py   (runs this same file through python-oracledb)
-- Re-running the file resets the database to the sample data.
-- No sequences are used (the lab account has no CREATE SEQUENCE privilege):
-- new primary keys are computed as NVL(MAX(key), 0) + 1.
-- ============================================================================
SET SERVEROUTPUT ON
SET SQLBLANKLINES ON
SET DEFINE OFF

-- ============================================================================
-- 0. CLEAN UP (drops the objects of a previous run, if any)
-- ============================================================================
BEGIN
    FOR t IN (SELECT table_name FROM user_tables
               WHERE table_name IN ('DISPUTES', 'REVIEWS', 'ESCROW_TXNS', 'ORDERS',
                                    'OFFERS', 'LISTINGS', 'CATEGORIES', 'USERS')) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS PURGE';
    END LOOP;
END;
/

-- ============================================================================
-- 1. TABLES WITH CONSTRAINTS
-- ============================================================================

CREATE TABLE users (
    user_id         NUMBER(6)       NOT NULL,
    reg_no          VARCHAR2(9),
    full_name       VARCHAR2(60)    NOT NULL,
    email           VARCHAR2(80)    NOT NULL,
    phone           VARCHAR2(10)    NOT NULL,
    hostel_block    VARCHAR2(10),
    role            VARCHAR2(10)    DEFAULT 'STUDENT' NOT NULL,
    wallet_balance  NUMBER(10,2)    DEFAULT 0 NOT NULL,
    is_blocked      CHAR(1)         DEFAULT 'N' NOT NULL,
    created_at      DATE            DEFAULT SYSDATE NOT NULL,
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
    category_id     NUMBER(4)       NOT NULL,
    category_name   VARCHAR2(40)    NOT NULL,
    fee_percent     NUMBER(4,2)     DEFAULT 5 NOT NULL,
    description     VARCHAR2(200),
    CONSTRAINT pk_categories     PRIMARY KEY (category_id),
    CONSTRAINT uq_category_name  UNIQUE (category_name),
    CONSTRAINT chk_category_fee  CHECK (fee_percent BETWEEN 0 AND 20)
);

CREATE TABLE listings (
    listing_id      NUMBER(8)       NOT NULL,
    seller_id       NUMBER(6)       NOT NULL,
    category_id     NUMBER(4)       NOT NULL,
    title           VARCHAR2(100)   NOT NULL,
    description     VARCHAR2(500),
    item_condition  VARCHAR2(10)    NOT NULL,
    asking_price    NUMBER(10,2)    NOT NULL,
    status          VARCHAR2(10)    DEFAULT 'ACTIVE' NOT NULL,
    listed_on       DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_listings            PRIMARY KEY (listing_id),
    CONSTRAINT fk_listing_seller      FOREIGN KEY (seller_id)   REFERENCES users (user_id),
    CONSTRAINT fk_listing_category    FOREIGN KEY (category_id) REFERENCES categories (category_id),
    CONSTRAINT chk_listing_condition  CHECK (item_condition IN ('NEW', 'LIKE_NEW', 'GOOD', 'FAIR')),
    CONSTRAINT chk_listing_price      CHECK (asking_price > 0),
    CONSTRAINT chk_listing_status     CHECK (status IN ('ACTIVE', 'RESERVED', 'SOLD', 'WITHDRAWN'))
);

CREATE TABLE offers (
    offer_id        NUMBER(8)       NOT NULL,
    listing_id      NUMBER(8)       NOT NULL,
    buyer_id        NUMBER(6)       NOT NULL,
    offered_price   NUMBER(10,2)    NOT NULL,
    status          VARCHAR2(10)    DEFAULT 'PENDING' NOT NULL,
    offered_on      DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_offers          PRIMARY KEY (offer_id),
    CONSTRAINT fk_offer_listing   FOREIGN KEY (listing_id) REFERENCES listings (listing_id),
    CONSTRAINT fk_offer_buyer     FOREIGN KEY (buyer_id)   REFERENCES users (user_id),
    CONSTRAINT chk_offer_price    CHECK (offered_price > 0),
    CONSTRAINT chk_offer_status   CHECK (status IN ('PENDING', 'ACCEPTED', 'REJECTED', 'WITHDRAWN'))
);

CREATE TABLE orders (
    order_id        NUMBER(8)       NOT NULL,
    offer_id        NUMBER(8)       NOT NULL,
    platform_fee    NUMBER(10,2)    DEFAULT 0 NOT NULL,
    meetup_location VARCHAR2(60)    NOT NULL,
    status          VARCHAR2(12)    DEFAULT 'CREATED' NOT NULL,
    created_at      DATE            DEFAULT SYSDATE NOT NULL,
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
    txn_id          NUMBER(10)      NOT NULL,
    order_id        NUMBER(8)       NOT NULL,
    txn_type        VARCHAR2(8)     NOT NULL,
    amount          NUMBER(10,2)    NOT NULL,
    txn_time        TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
    CONSTRAINT pk_escrow_txns   PRIMARY KEY (txn_id),
    CONSTRAINT fk_txn_order     FOREIGN KEY (order_id) REFERENCES orders (order_id),
    CONSTRAINT chk_txn_type     CHECK (txn_type IN ('HOLD', 'RELEASE', 'REFUND')),
    CONSTRAINT chk_txn_amount   CHECK (amount > 0)
);

CREATE TABLE reviews (
    review_id       NUMBER(8)       NOT NULL,
    order_id        NUMBER(8)       NOT NULL,
    rating          NUMBER(1)       NOT NULL,
    review_comment  VARCHAR2(300),
    reviewed_on     DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT pk_reviews         PRIMARY KEY (review_id),
    CONSTRAINT fk_review_order    FOREIGN KEY (order_id) REFERENCES orders (order_id),
    CONSTRAINT uq_review_order    UNIQUE (order_id),
    CONSTRAINT chk_review_rating  CHECK (rating BETWEEN 1 AND 5)
);

CREATE TABLE disputes (
    dispute_id      NUMBER(8)       NOT NULL,
    order_id        NUMBER(8)       NOT NULL,
    raised_by       NUMBER(6)       NOT NULL,
    resolved_by     NUMBER(6),
    reason          VARCHAR2(300)   NOT NULL,
    status          VARCHAR2(16)    DEFAULT 'OPEN' NOT NULL,
    raised_on       DATE            DEFAULT SYSDATE NOT NULL,
    resolved_on     DATE,
    CONSTRAINT pk_disputes              PRIMARY KEY (dispute_id),
    CONSTRAINT fk_dispute_order         FOREIGN KEY (order_id)    REFERENCES orders (order_id),
    CONSTRAINT uq_dispute_order         UNIQUE (order_id),
    CONSTRAINT fk_dispute_raised_by     FOREIGN KEY (raised_by)   REFERENCES users (user_id),
    CONSTRAINT fk_dispute_resolved_by   FOREIGN KEY (resolved_by) REFERENCES users (user_id),
    CONSTRAINT chk_dispute_status       CHECK (status IN ('OPEN', 'RESOLVED_BUYER',
                                                      'RESOLVED_SELLER')),
    CONSTRAINT chk_dispute_resolved_on  CHECK (resolved_on IS NULL OR resolved_on >= raised_on),
    CONSTRAINT chk_dispute_resolution   CHECK (
        (status = 'OPEN'  AND resolved_by IS NULL     AND resolved_on IS NULL) OR
        (status <> 'OPEN' AND resolved_by IS NOT NULL AND resolved_on IS NOT NULL))
);

-- ============================================================================
-- 2. SAMPLE DATA (parent tables first so every foreign key finds its parent)
-- ============================================================================

-- USERS (17 rows)
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (101, '24BCE0412', 'Arjun Menon', 'arjun.menon2024@vitstudent.ac.in', '9876501234', 'MH-A', 'STUDENT', 4200, 'N', TO_DATE('2026-07-20', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (102, '24BIT0156', 'Priya Raghavan', 'priya.raghavan2024@vitstudent.ac.in', '9840212345', 'LH-C', 'STUDENT', 3150, 'N', TO_DATE('2026-07-20', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (103, '23BCE0877', 'Karthik Subramanian', 'karthik.s2023@vitstudent.ac.in', '9003456789', 'MH-J', 'STUDENT', 6800, 'N', TO_DATE('2026-07-21', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (104, '24BEC0233', 'Sneha Iyer', 'sneha.iyer2024@vitstudent.ac.in', '8754321098', 'LH-E', 'STUDENT', 1250, 'N', TO_DATE('2026-07-21', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (105, '23BME0519', 'Rahul Verma', 'rahul.verma2023@vitstudent.ac.in', '9123456780', 'MH-K', 'STUDENT', 5400, 'N', TO_DATE('2026-07-22', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (106, '24BCE0690', 'Ananya Krishnan', 'ananya.k2024@vitstudent.ac.in', '9566012345', 'LH-B', 'STUDENT', 2750, 'N', TO_DATE('2026-07-22', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (107, '22BCE0345', 'Vikram Reddy', 'vikram.reddy2022@vitstudent.ac.in', '9949087654', 'MH-P', 'STUDENT', 9100, 'N', TO_DATE('2026-07-23', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (108, '23BIT0402', 'Divya Nair', 'divya.nair2023@vitstudent.ac.in', '9447123456', 'LH-C', 'STUDENT', 1800, 'N', TO_DATE('2026-07-23', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (109, '24BCB0118', 'Aditya Sharma', 'aditya.sharma2024@vitstudent.ac.in', '9810234567', 'MH-Q', 'STUDENT', 350, 'N', TO_DATE('2026-07-24', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (110, '22BEC0761', 'Meera Pillai', 'meera.pillai2022@vitstudent.ac.in', '9895567890', 'LH-G', 'STUDENT', 7600, 'N', TO_DATE('2026-07-24', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (111, '23BCE0954', 'Sanjay Kumar', 'sanjay.kumar2023@vitstudent.ac.in', '9789012345', 'MH-L', 'STUDENT', 2300, 'N', TO_DATE('2026-07-25', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (112, '24BIT0287', 'Harini Venkatesh', 'harini.v2024@vitstudent.ac.in', '9361234567', 'LH-E', 'STUDENT', 4950, 'N', TO_DATE('2026-07-25', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (113, '23BCI0063', 'Rohan Das', 'rohan.das2023@vitstudent.ac.in', '9830123456', NULL, 'STUDENT', 1600, 'N', TO_DATE('2026-07-26', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (114, '24BCE0821', 'Fathima Rizwana', 'fathima.r2024@vitstudent.ac.in', '9629876543', 'LH-B', 'STUDENT', 3900, 'N', TO_DATE('2026-07-26', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (115, '22BME0230', 'Nikhil Joshi', 'nikhil.joshi2022@vitstudent.ac.in', '9922334455', 'MH-A', 'STUDENT', 800, 'Y', TO_DATE('2026-07-27', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (116, NULL, 'Dr. S. Lakshmi', 'lakshmi.s@vit.ac.in', '9443012345', NULL, 'ADMIN', 0, 'N', TO_DATE('2026-07-01', 'YYYY-MM-DD'));
INSERT INTO users (user_id, reg_no, full_name, email, phone, hostel_block, role, wallet_balance, is_blocked, created_at) VALUES (117, NULL, 'R. Prakash', 'prakash.r@vit.ac.in', '9442098765', NULL, 'ADMIN', 0, 'N', TO_DATE('2026-07-01', 'YYYY-MM-DD'));

-- CATEGORIES (10 rows)
INSERT INTO categories (category_id, category_name, fee_percent, description) VALUES (1, 'Textbooks', 3, 'Course textbooks, reference books and lab manuals');
INSERT INTO categories (category_id, category_name, fee_percent, description) VALUES (2, 'Lab Equipment', 4, 'Lab coats, drafting kits, goggles and practical tools');
INSERT INTO categories (category_id, category_name, fee_percent, description) VALUES (3, 'Electronics', 8, 'Gadgets, computer peripherals and development boards');
INSERT INTO categories (category_id, category_name, fee_percent, description) VALUES (4, 'Bicycles', 6, 'Bicycles and cycle accessories for getting around campus');
INSERT INTO categories (category_id, category_name, fee_percent, description) VALUES (5, 'Calculators', 5, 'Scientific and programmable calculators');
INSERT INTO categories (category_id, category_name, fee_percent, description) VALUES (6, 'Hostel Essentials', 5, 'Kettles, lamps, fans, mattresses and room items');
INSERT INTO categories (category_id, category_name, fee_percent, description) VALUES (7, 'Sports and Fitness', 6, 'Sports gear and fitness equipment');
INSERT INTO categories (category_id, category_name, fee_percent, description) VALUES (8, 'Stationery', 2, 'Geometry boxes, pens, notebooks and art supplies');
INSERT INTO categories (category_id, category_name, fee_percent, description) VALUES (9, 'Musical Instruments', 7, 'Guitars, keyboards and other instruments');
INSERT INTO categories (category_id, category_name, fee_percent, description) VALUES (10, 'Clothing', 4, 'Hoodies, formal wear and club merchandise');

-- LISTINGS (35 rows)
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1001, 103, 1, 'Higher Engineering Mathematics - B.S. Grewal', 'Latest edition, a few pencil notes', 'GOOD', 450, 'SOLD', TO_DATE('2026-08-05', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1002, 107, 3, 'Logitech M235 Wireless Mouse', 'Used for one semester, battery included', 'LIKE_NEW', 600, 'SOLD', TO_DATE('2026-08-06', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1003, 110, 4, 'Hero Sprint 26T Bicycle', 'New tyres fitted in July, lock included', 'GOOD', 3500, 'SOLD', TO_DATE('2026-08-07', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1004, 105, 5, 'Casio fx-991EX Scientific Calculator', 'Exam-approved, with cover', 'LIKE_NEW', 900, 'SOLD', TO_DATE('2026-08-08', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1005, 103, 2, 'Lab Coat (Size M) with Safety Goggles', 'Washed and ironed', 'GOOD', 300, 'SOLD', TO_DATE('2026-08-10', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1006, 107, 3, 'boAt Rockerz 450 Headphones', 'Original box and cable', 'GOOD', 800, 'WITHDRAWN', TO_DATE('2026-08-12', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1007, 112, 6, 'Pigeon Electric Kettle 1.5 L', 'Works perfectly, descaled', 'GOOD', 450, 'SOLD', TO_DATE('2026-08-13', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1008, 110, 1, 'Data Structures and Algorithm Analysis - Weiss', 'Highlighted in early chapters', 'FAIR', 350, 'SOLD', TO_DATE('2026-08-14', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1009, 102, 7, 'Yonex Nanoray Badminton Racket', 'Restrung last month', 'LIKE_NEW', 1200, 'SOLD', TO_DATE('2026-08-15', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1010, 105, 9, 'Kadence Acoustic Guitar with Bag', 'Minor scratches on the back', 'GOOD', 2800, 'SOLD', TO_DATE('2026-08-16', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1011, 114, 10, 'VIT Hoodie (Size L)', 'Worn twice', 'LIKE_NEW', 500, 'SOLD', TO_DATE('2026-08-18', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1012, 101, 2, 'Mini Drafter and Drawing Board Set', 'Complete set for engineering graphics', 'GOOD', 650, 'SOLD', TO_DATE('2026-08-19', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1013, 107, 3, 'Raspberry Pi 4 (4 GB) Starter Kit', 'Case, charger and 32 GB SD card', 'LIKE_NEW', 3800, 'ACTIVE', TO_DATE('2026-08-20', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1014, 106, 8, 'Engineering Graphics Stationery Kit', 'Pencils, clutch pencil and templates', 'GOOD', 250, 'SOLD', TO_DATE('2026-08-21', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1015, 110, 6, 'Wipro LED Study Lamp', 'Three brightness levels', 'NEW', 700, 'SOLD', TO_DATE('2026-08-22', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1016, 103, 1, 'Operating System Concepts - Silberschatz', 'Clean copy, no markings', 'GOOD', 550, 'SOLD', TO_DATE('2026-08-24', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1017, 111, 4, 'Firefox Bad Attitude 21-Speed Cycle', 'Ridden for two semesters', 'FAIR', 4200, 'WITHDRAWN', TO_DATE('2026-08-25', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1018, 105, 3, 'Redmi 20000 mAh Power Bank', 'Supports 18 W fast charging', 'GOOD', 900, 'SOLD', TO_DATE('2026-08-27', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1019, 112, 5, 'Casio fx-82MS Calculator', 'Basic scientific calculator', 'FAIR', 350, 'RESERVED', TO_DATE('2026-08-28', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1020, 113, 7, 'Cosco Football (Size 5)', 'Used in a few matches', 'GOOD', 400, 'RESERVED', TO_DATE('2026-08-30', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1021, 107, 3, 'HP 24-inch Full HD Monitor', 'HDMI cable included', 'GOOD', 6500, 'ACTIVE', TO_DATE('2026-09-01', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1022, 102, 6, 'Single Bed Mattress Topper', 'Memory foam, 2 inch', 'GOOD', 900, 'RESERVED', TO_DATE('2026-09-02', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1023, 101, 1, 'Database System Concepts - Korth', '7th edition, like new', 'LIKE_NEW', 600, 'RESERVED', TO_DATE('2026-09-05', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1024, 110, 9, 'Yamaha PSR-F52 Keyboard', '61 keys with adapter', 'GOOD', 5200, 'RESERVED', TO_DATE('2026-09-07', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1025, 114, 3, 'Arduino Uno Starter Kit', 'Board, sensors, jumper wires and breadboard', 'GOOD', 1100, 'RESERVED', TO_DATE('2026-09-09', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1026, 103, 5, 'Casio fx-991ES Plus Calculator', 'Fully working, new battery', 'GOOD', 550, 'RESERVED', TO_DATE('2026-09-12', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1027, 105, 7, 'Decathlon Dumbbell Set (2 x 5 kg)', 'Rubber coated', 'GOOD', 1600, 'RESERVED', TO_DATE('2026-09-15', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1028, 104, 1, 'Digital Design - Morris Mano', '5th edition', 'GOOD', 300, 'ACTIVE', TO_DATE('2026-09-20', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1029, 108, 3, 'JBL Go 3 Bluetooth Speaker', 'Bought in June, with bill', 'LIKE_NEW', 1800, 'ACTIVE', TO_DATE('2026-09-22', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1030, 111, 7, 'Yoga Mat with Resistance Bands', 'Hardly used', 'GOOD', 900, 'ACTIVE', TO_DATE('2026-09-24', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1031, 106, 6, 'Usha Table Fan', 'Quiet, three speeds', 'GOOD', 750, 'ACTIVE', TO_DATE('2026-09-25', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1032, 109, 8, 'Camlin Geometry Box and Pen Combo', 'Unopened pack', 'NEW', 150, 'ACTIVE', TO_DATE('2026-09-27', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1033, 113, 10, 'Formal Blazer (Size M)', 'Dry-cleaned', 'LIKE_NEW', 1500, 'WITHDRAWN', TO_DATE('2026-09-28', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1034, 115, 3, 'Apple iPhone 11 (64 GB)', 'No bill available', 'FAIR', 15000, 'WITHDRAWN', TO_DATE('2026-09-10', 'YYYY-MM-DD'));
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price, status, listed_on) VALUES (1035, 112, 9, 'Kala Soprano Ukulele', 'With tuner and bag', 'GOOD', 1300, 'ACTIVE', TO_DATE('2026-09-29', 'YYYY-MM-DD'));

-- OFFERS (40 rows)
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5001, 1001, 104, 420, 'ACCEPTED', TO_DATE('2026-08-06', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5002, 1002, 101, 550, 'ACCEPTED', TO_DATE('2026-08-07', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5003, 1003, 105, 3300, 'ACCEPTED', TO_DATE('2026-08-09', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5004, 1004, 102, 850, 'ACCEPTED', TO_DATE('2026-08-09', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5005, 1005, 108, 280, 'ACCEPTED', TO_DATE('2026-08-11', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5006, 1006, 111, 750, 'ACCEPTED', TO_DATE('2026-08-13', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5007, 1007, 106, 420, 'ACCEPTED', TO_DATE('2026-08-14', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5008, 1008, 109, 300, 'ACCEPTED', TO_DATE('2026-08-15', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5009, 1009, 114, 1100, 'ACCEPTED', TO_DATE('2026-08-17', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5010, 1010, 107, 2600, 'ACCEPTED', TO_DATE('2026-08-18', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5011, 1011, 112, 450, 'ACCEPTED', TO_DATE('2026-08-19', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5012, 1012, 113, 600, 'ACCEPTED', TO_DATE('2026-08-21', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5013, 1013, 103, 3500, 'ACCEPTED', TO_DATE('2026-08-23', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5014, 1014, 104, 230, 'ACCEPTED', TO_DATE('2026-08-23', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5015, 1015, 112, 680, 'ACCEPTED', TO_DATE('2026-08-24', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5016, 1016, 111, 500, 'ACCEPTED', TO_DATE('2026-08-26', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5017, 1017, 110, 3900, 'ACCEPTED', TO_DATE('2026-08-27', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5018, 1018, 106, 850, 'ACCEPTED', TO_DATE('2026-08-28', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5019, 1019, 109, 320, 'ACCEPTED', TO_DATE('2026-08-31', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5020, 1020, 101, 380, 'ACCEPTED', TO_DATE('2026-09-02', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5021, 1021, 110, 6200, 'ACCEPTED', TO_DATE('2026-09-03', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5022, 1022, 108, 850, 'ACCEPTED', TO_DATE('2026-09-04', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5023, 1023, 106, 580, 'ACCEPTED', TO_DATE('2026-09-27', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5024, 1024, 103, 5000, 'ACCEPTED', TO_DATE('2026-09-30', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5025, 1025, 105, 1000, 'ACCEPTED', TO_DATE('2026-10-01', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5026, 1026, 112, 520, 'ACCEPTED', TO_DATE('2026-10-06', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5027, 1027, 114, 1500, 'ACCEPTED', TO_DATE('2026-10-07', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5028, 1003, 112, 3000, 'REJECTED', TO_DATE('2026-08-08', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5029, 1013, 105, 3200, 'REJECTED', TO_DATE('2026-08-22', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5030, 1021, 103, 5800, 'REJECTED', TO_DATE('2026-09-02', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5031, 1024, 101, 4500, 'REJECTED', TO_DATE('2026-09-25', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5032, 1010, 104, 2200, 'WITHDRAWN', TO_DATE('2026-08-17', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5033, 1009, 113, 950, 'WITHDRAWN', TO_DATE('2026-08-16', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5034, 1028, 101, 280, 'PENDING', TO_DATE('2026-09-22', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5035, 1028, 111, 260, 'PENDING', TO_DATE('2026-09-23', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5036, 1029, 105, 1600, 'PENDING', TO_DATE('2026-09-24', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5037, 1029, 109, 1700, 'PENDING', TO_DATE('2026-09-25', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5038, 1031, 113, 700, 'PENDING', TO_DATE('2026-09-27', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5039, 1035, 104, 1200, 'PENDING', TO_DATE('2026-10-01', 'YYYY-MM-DD'));
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price, status, offered_on) VALUES (5040, 1013, 112, 3400, 'PENDING', TO_DATE('2026-09-01', 'YYYY-MM-DD'));

-- ORDERS (27 rows)
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7001, 5001, 12.6, 'Library Entrance', 'COMPLETED', TO_DATE('2026-08-07', 'YYYY-MM-DD'), TO_DATE('2026-08-08', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7002, 5002, 44, 'SJT Ground Floor', 'COMPLETED', TO_DATE('2026-08-08', 'YYYY-MM-DD'), TO_DATE('2026-08-09', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7003, 5003, 198, 'Main Gate', 'COMPLETED', TO_DATE('2026-08-10', 'YYYY-MM-DD'), TO_DATE('2026-08-11', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7004, 5004, 42.5, 'TT Food Court', 'COMPLETED', TO_DATE('2026-08-10', 'YYYY-MM-DD'), TO_DATE('2026-08-12', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7005, 5005, 11.2, 'SMV Block Entrance', 'COMPLETED', TO_DATE('2026-08-12', 'YYYY-MM-DD'), TO_DATE('2026-08-12', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7006, 5006, 60, 'SJT Ground Floor', 'REFUNDED', TO_DATE('2026-08-14', 'YYYY-MM-DD'), TO_DATE('2026-08-15', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7007, 5007, 21, 'LH-B Block Lobby', 'COMPLETED', TO_DATE('2026-08-15', 'YYYY-MM-DD'), TO_DATE('2026-08-16', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7008, 5008, 9, 'Library Entrance', 'COMPLETED', TO_DATE('2026-08-16', 'YYYY-MM-DD'), TO_DATE('2026-08-17', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7009, 5009, 66, 'Indoor Stadium', 'COMPLETED', TO_DATE('2026-08-18', 'YYYY-MM-DD'), TO_DATE('2026-08-18', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7010, 5010, 182, 'Anna Auditorium', 'COMPLETED', TO_DATE('2026-08-19', 'YYYY-MM-DD'), TO_DATE('2026-08-20', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7011, 5011, 18, 'TT Food Court', 'COMPLETED', TO_DATE('2026-08-20', 'YYYY-MM-DD'), TO_DATE('2026-08-21', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7012, 5012, 24, 'GDN Block Entrance', 'COMPLETED', TO_DATE('2026-08-22', 'YYYY-MM-DD'), TO_DATE('2026-08-23', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7013, 5013, 280, 'SJT Ground Floor', 'REFUNDED', TO_DATE('2026-08-24', 'YYYY-MM-DD'), TO_DATE('2026-08-25', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7014, 5014, 4.6, 'SMV Block Entrance', 'COMPLETED', TO_DATE('2026-08-24', 'YYYY-MM-DD'), TO_DATE('2026-08-25', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7015, 5015, 34, 'LH-E Block Lobby', 'COMPLETED', TO_DATE('2026-08-25', 'YYYY-MM-DD'), TO_DATE('2026-08-26', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7016, 5016, 15, 'Library Entrance', 'COMPLETED', TO_DATE('2026-08-27', 'YYYY-MM-DD'), TO_DATE('2026-08-28', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7017, 5017, 234, 'Main Gate', 'REFUNDED', TO_DATE('2026-08-28', 'YYYY-MM-DD'), TO_DATE('2026-08-29', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7018, 5018, 68, 'TT Food Court', 'COMPLETED', TO_DATE('2026-08-29', 'YYYY-MM-DD'), TO_DATE('2026-08-30', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7019, 5019, 16, 'SJT Ground Floor', 'DISPUTED', TO_DATE('2026-09-01', 'YYYY-MM-DD'), TO_DATE('2026-09-02', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7020, 5020, 22.8, 'Indoor Stadium', 'DISPUTED', TO_DATE('2026-09-03', 'YYYY-MM-DD'), NULL);
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7021, 5021, 496, 'PRP Block Entrance', 'REFUNDED', TO_DATE('2026-09-04', 'YYYY-MM-DD'), TO_DATE('2026-09-05', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7022, 5022, 42.5, 'LH-C Block Lobby', 'DISPUTED', TO_DATE('2026-09-05', 'YYYY-MM-DD'), TO_DATE('2026-09-06', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7023, 5023, 17.4, 'Library Entrance', 'HANDED_OVER', TO_DATE('2026-09-28', 'YYYY-MM-DD'), TO_DATE('2026-10-02', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7024, 5024, 350, 'Anna Auditorium', 'HANDED_OVER', TO_DATE('2026-10-01', 'YYYY-MM-DD'), TO_DATE('2026-10-04', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7025, 5025, 80, 'SJT Ground Floor', 'HANDED_OVER', TO_DATE('2026-10-02', 'YYYY-MM-DD'), TO_DATE('2026-10-05', 'YYYY-MM-DD'));
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7026, 5026, 26, 'TT Food Court', 'CREATED', TO_DATE('2026-10-07', 'YYYY-MM-DD'), NULL);
INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location, status, created_at, handed_over_at) VALUES (7027, 5027, 90, 'Indoor Stadium', 'CREATED', TO_DATE('2026-10-08', 'YYYY-MM-DD'), NULL);

-- ESCROW_TXNS (46 rows)
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900001, 7001, 'HOLD', 420, TO_TIMESTAMP('2026-08-07 10:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900002, 7002, 'HOLD', 550, TO_TIMESTAMP('2026-08-08 10:07:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900003, 7003, 'HOLD', 3300, TO_TIMESTAMP('2026-08-10 10:14:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900004, 7004, 'HOLD', 850, TO_TIMESTAMP('2026-08-10 10:21:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900005, 7001, 'RELEASE', 420, TO_TIMESTAMP('2026-08-11 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900006, 7005, 'HOLD', 280, TO_TIMESTAMP('2026-08-12 10:28:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900007, 7002, 'RELEASE', 550, TO_TIMESTAMP('2026-08-12 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900008, 7006, 'HOLD', 750, TO_TIMESTAMP('2026-08-14 10:35:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900009, 7003, 'RELEASE', 3300, TO_TIMESTAMP('2026-08-14 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900010, 7007, 'HOLD', 420, TO_TIMESTAMP('2026-08-15 10:42:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900011, 7004, 'RELEASE', 850, TO_TIMESTAMP('2026-08-15 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900012, 7005, 'RELEASE', 280, TO_TIMESTAMP('2026-08-15 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900013, 7008, 'HOLD', 300, TO_TIMESTAMP('2026-08-16 10:49:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900014, 7009, 'HOLD', 1100, TO_TIMESTAMP('2026-08-18 10:56:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900015, 7010, 'HOLD', 2600, TO_TIMESTAMP('2026-08-19 11:03:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900016, 7006, 'REFUND', 750, TO_TIMESTAMP('2026-08-19 16:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900017, 7007, 'RELEASE', 420, TO_TIMESTAMP('2026-08-19 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900018, 7011, 'HOLD', 450, TO_TIMESTAMP('2026-08-20 11:10:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900019, 7008, 'RELEASE', 300, TO_TIMESTAMP('2026-08-20 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900020, 7009, 'RELEASE', 1100, TO_TIMESTAMP('2026-08-21 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900021, 7012, 'HOLD', 600, TO_TIMESTAMP('2026-08-22 11:17:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900022, 7013, 'HOLD', 3500, TO_TIMESTAMP('2026-08-24 11:24:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900023, 7014, 'HOLD', 230, TO_TIMESTAMP('2026-08-24 11:31:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900024, 7010, 'RELEASE', 2600, TO_TIMESTAMP('2026-08-24 16:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900025, 7011, 'RELEASE', 450, TO_TIMESTAMP('2026-08-24 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900026, 7015, 'HOLD', 680, TO_TIMESTAMP('2026-08-25 11:38:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900027, 7012, 'RELEASE', 600, TO_TIMESTAMP('2026-08-26 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900028, 7016, 'HOLD', 500, TO_TIMESTAMP('2026-08-27 11:45:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900029, 7017, 'HOLD', 3900, TO_TIMESTAMP('2026-08-28 11:52:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900030, 7013, 'REFUND', 3500, TO_TIMESTAMP('2026-08-28 16:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900031, 7014, 'RELEASE', 230, TO_TIMESTAMP('2026-08-28 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900032, 7018, 'HOLD', 850, TO_TIMESTAMP('2026-08-29 11:59:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900033, 7015, 'RELEASE', 680, TO_TIMESTAMP('2026-08-30 16:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900034, 7016, 'RELEASE', 500, TO_TIMESTAMP('2026-08-31 23:30:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900035, 7019, 'HOLD', 320, TO_TIMESTAMP('2026-09-01 12:06:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900036, 7017, 'REFUND', 3900, TO_TIMESTAMP('2026-09-02 16:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900037, 7020, 'HOLD', 380, TO_TIMESTAMP('2026-09-03 12:13:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900038, 7018, 'RELEASE', 850, TO_TIMESTAMP('2026-09-03 16:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900039, 7021, 'HOLD', 6200, TO_TIMESTAMP('2026-09-04 12:20:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900040, 7022, 'HOLD', 850, TO_TIMESTAMP('2026-09-05 12:27:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900041, 7021, 'REFUND', 6200, TO_TIMESTAMP('2026-09-09 16:00:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900042, 7023, 'HOLD', 580, TO_TIMESTAMP('2026-09-28 12:34:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900043, 7024, 'HOLD', 5000, TO_TIMESTAMP('2026-10-01 12:41:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900044, 7025, 'HOLD', 1000, TO_TIMESTAMP('2026-10-02 12:48:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900045, 7026, 'HOLD', 520, TO_TIMESTAMP('2026-10-07 12:55:00', 'YYYY-MM-DD HH24:MI:SS'));
INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount, txn_time) VALUES (900046, 7027, 'HOLD', 1500, TO_TIMESTAMP('2026-10-08 13:02:00', 'YYYY-MM-DD HH24:MI:SS'));

-- REVIEWS (13 rows)
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8001, 7001, 5, 'Book in great condition, seller was on time', TO_DATE('2026-08-12', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8002, 7002, 4, 'Mouse works well', TO_DATE('2026-08-13', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8003, 7003, 5, 'Cycle exactly as described', TO_DATE('2026-08-15', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8004, 7004, 5, 'Calculator like new', TO_DATE('2026-08-16', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8005, 7005, 4, 'Good coat, goggles slightly scratched', TO_DATE('2026-08-16', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8006, 7007, 4, 'Kettle works fine', TO_DATE('2026-08-20', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8007, 7008, 3, 'A few pages are loose', TO_DATE('2026-08-21', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8008, 7009, 5, 'Excellent racket', TO_DATE('2026-08-22', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8009, 7010, 2, 'Strings needed replacing', TO_DATE('2026-08-25', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8010, 7011, 5, 'Hoodie is as good as new', TO_DATE('2026-08-25', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8011, 7014, 4, 'Complete kit', TO_DATE('2026-08-29', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8012, 7015, 3, 'Lamp is fine after resetting', TO_DATE('2026-08-31', 'YYYY-MM-DD'));
INSERT INTO reviews (review_id, order_id, rating, review_comment, reviewed_on) VALUES (8013, 7016, 5, 'Very clean copy', TO_DATE('2026-09-01', 'YYYY-MM-DD'));

-- DISPUTES (10 rows)
INSERT INTO disputes (dispute_id, order_id, raised_by, resolved_by, reason, status, raised_on, resolved_on) VALUES (9001, 7006, 111, 116, 'Left ear cup of the headphones has no sound', 'RESOLVED_BUYER', TO_DATE('2026-08-16', 'YYYY-MM-DD'), TO_DATE('2026-08-19', 'YYYY-MM-DD'));
INSERT INTO disputes (dispute_id, order_id, raised_by, resolved_by, reason, status, raised_on, resolved_on) VALUES (9002, 7010, 107, 117, 'Guitar strings are rusted, not mentioned in the listing', 'RESOLVED_SELLER', TO_DATE('2026-08-21', 'YYYY-MM-DD'), TO_DATE('2026-08-24', 'YYYY-MM-DD'));
INSERT INTO disputes (dispute_id, order_id, raised_by, resolved_by, reason, status, raised_on, resolved_on) VALUES (9003, 7013, 103, 117, 'Board does not boot and the SD card was missing', 'RESOLVED_BUYER', TO_DATE('2026-08-26', 'YYYY-MM-DD'), TO_DATE('2026-08-28', 'YYYY-MM-DD'));
INSERT INTO disputes (dispute_id, order_id, raised_by, resolved_by, reason, status, raised_on, resolved_on) VALUES (9004, 7015, 112, 116, 'Lamp flickers at full brightness', 'RESOLVED_SELLER', TO_DATE('2026-08-27', 'YYYY-MM-DD'), TO_DATE('2026-08-30', 'YYYY-MM-DD'));
INSERT INTO disputes (dispute_id, order_id, raised_by, resolved_by, reason, status, raised_on, resolved_on) VALUES (9005, 7017, 110, 116, 'Gear shifter is broken, not disclosed by the seller', 'RESOLVED_BUYER', TO_DATE('2026-08-30', 'YYYY-MM-DD'), TO_DATE('2026-09-02', 'YYYY-MM-DD'));
INSERT INTO disputes (dispute_id, order_id, raised_by, resolved_by, reason, status, raised_on, resolved_on) VALUES (9006, 7018, 106, 117, 'Power bank charges very slowly', 'RESOLVED_SELLER', TO_DATE('2026-08-31', 'YYYY-MM-DD'), TO_DATE('2026-09-03', 'YYYY-MM-DD'));
INSERT INTO disputes (dispute_id, order_id, raised_by, resolved_by, reason, status, raised_on, resolved_on) VALUES (9007, 7019, 109, NULL, 'Calculator display has missing segments', 'OPEN', TO_DATE('2026-09-03', 'YYYY-MM-DD'), NULL);
INSERT INTO disputes (dispute_id, order_id, raised_by, resolved_by, reason, status, raised_on, resolved_on) VALUES (9008, 7020, 113, NULL, 'Buyer did not turn up at the meetup twice', 'OPEN', TO_DATE('2026-09-06', 'YYYY-MM-DD'), NULL);
INSERT INTO disputes (dispute_id, order_id, raised_by, resolved_by, reason, status, raised_on, resolved_on) VALUES (9009, 7021, 110, 117, 'Monitor has a vertical line of dead pixels', 'RESOLVED_BUYER', TO_DATE('2026-09-06', 'YYYY-MM-DD'), TO_DATE('2026-09-09', 'YYYY-MM-DD'));
INSERT INTO disputes (dispute_id, order_id, raised_by, resolved_by, reason, status, raised_on, resolved_on) VALUES (9010, 7022, 108, NULL, 'Mattress topper has stains not shown in the photos', 'OPEN', TO_DATE('2026-09-07', 'YYYY-MM-DD'), NULL);

COMMIT;

-- ============================================================================
-- 3. VIEW USED BY THE ORDERS SCREEN
-- ============================================================================
CREATE OR REPLACE VIEW order_details_v AS
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


-- ============================================================================
-- 4-6. PL/SQL OBJECTS FROM REVIEW II: FUNCTIONS, TRIGGERS, PROCEDURES (with cursor)
-- ============================================================================
-- FUNCTION: CALC_PLATFORM_FEE
CREATE OR REPLACE FUNCTION calc_platform_fee (
    p_listing_id IN listings.listing_id%TYPE,
    p_amount     IN NUMBER
) RETURN NUMBER
IS
    v_fee_percent categories.fee_percent%TYPE;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE_APPLICATION_ERROR(-20040, 'Sale amount must be greater than zero');
    END IF;

    -- fee percentage of the category the listing belongs to
    SELECT c.fee_percent
      INTO v_fee_percent
      FROM listings l
      JOIN categories c ON c.category_id = l.category_id
     WHERE l.listing_id = p_listing_id;

    RETURN ROUND(p_amount * v_fee_percent / 100, 2);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20041, 'Listing ' || p_listing_id || ' does not exist');
END calc_platform_fee;
/

-- FUNCTION: SELLER_TRUST_SCORE
CREATE OR REPLACE FUNCTION seller_trust_score (
    p_seller_id IN users.user_id%TYPE
) RETURN NUMBER
IS
    v_total_orders  NUMBER;
    v_disputes_lost NUMBER;
    v_avg_rating    NUMBER;
BEGIN
    SELECT COUNT(o.order_id),
           COUNT(CASE WHEN d.status = 'RESOLVED_BUYER' THEN 1 END),
           AVG(r.rating)
      INTO v_total_orders, v_disputes_lost, v_avg_rating
      FROM orders o
      JOIN offers   f ON f.offer_id   = o.offer_id
      JOIN listings l ON l.listing_id = f.listing_id
      LEFT JOIN disputes d ON d.order_id = o.order_id
      LEFT JOIN reviews  r ON r.order_id = o.order_id
     WHERE l.seller_id = p_seller_id;

    IF v_total_orders = 0 THEN
        RETURN NULL;                  -- new seller: no history yet
    END IF;

    -- 70 points from the average rating (unrated sellers get a neutral 3 out of 5)
    -- 30 points from the share of orders NOT lost in a dispute
    RETURN ROUND((NVL(v_avg_rating, 3) / 5) * 70
                 + (1 - v_disputes_lost / v_total_orders) * 30, 1);
END seller_trust_score;
/

-- TRIGGER: TRG_VALIDATE_OFFER
CREATE OR REPLACE TRIGGER trg_validate_offer
BEFORE INSERT ON offers
FOR EACH ROW
DECLARE
    v_seller_id      listings.seller_id%TYPE;
    v_listing_status listings.status%TYPE;
    v_is_blocked     users.is_blocked%TYPE;
BEGIN
    SELECT seller_id, status
      INTO v_seller_id, v_listing_status
      FROM listings
     WHERE listing_id = :NEW.listing_id;

    IF v_seller_id = :NEW.buyer_id THEN                               -- BR-01
        RAISE_APPLICATION_ERROR(-20001, 'You cannot make an offer on your own listing');
    END IF;

    IF v_listing_status <> 'ACTIVE' THEN                              -- BR-02
        RAISE_APPLICATION_ERROR(-20002, 'Offers are allowed only on ACTIVE listings (this listing is '
                                        || v_listing_status || ')');
    END IF;

    SELECT is_blocked INTO v_is_blocked FROM users WHERE user_id = :NEW.buyer_id;

    IF v_is_blocked = 'Y' THEN                                        -- BR-03
        RAISE_APPLICATION_ERROR(-20003, 'Blocked users cannot make offers');
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20004, 'Listing or buyer does not exist');
END;
/

-- TRIGGER: TRG_VALIDATE_LISTING
CREATE OR REPLACE TRIGGER trg_validate_listing
BEFORE INSERT ON listings
FOR EACH ROW
DECLARE
    v_is_blocked users.is_blocked%TYPE;
BEGIN
    SELECT is_blocked INTO v_is_blocked FROM users WHERE user_id = :NEW.seller_id;

    IF v_is_blocked = 'Y' THEN                                        -- BR-03
        RAISE_APPLICATION_ERROR(-20005, 'Blocked users cannot create listings');
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20006, 'Seller does not exist');
END;
/

-- TRIGGER: TRG_SYNC_LISTING_STATUS
CREATE OR REPLACE TRIGGER trg_sync_listing_status
AFTER INSERT OR UPDATE OF status ON orders
FOR EACH ROW
DECLARE
    v_listing_id offers.listing_id%TYPE;
BEGIN
    SELECT listing_id INTO v_listing_id FROM offers WHERE offer_id = :NEW.offer_id;

    UPDATE listings
       SET status = CASE :NEW.status
                        WHEN 'COMPLETED' THEN 'SOLD'
                        WHEN 'REFUNDED'  THEN 'ACTIVE'
                        WHEN 'CANCELLED' THEN 'ACTIVE'
                        ELSE 'RESERVED'           -- CREATED, HANDED_OVER, DISPUTED
                    END
     WHERE listing_id = v_listing_id;
END;
/

-- TRIGGER: TRG_ON_DISPUTE_RAISED
CREATE OR REPLACE TRIGGER trg_on_dispute_raised
BEFORE INSERT ON disputes
FOR EACH ROW
DECLARE
    v_order_status orders.status%TYPE;
    v_buyer_id     offers.buyer_id%TYPE;
    v_seller_id    listings.seller_id%TYPE;
BEGIN
    SELECT o.status, f.buyer_id, l.seller_id
      INTO v_order_status, v_buyer_id, v_seller_id
      FROM orders o
      JOIN offers   f ON f.offer_id   = o.offer_id
      JOIN listings l ON l.listing_id = f.listing_id
     WHERE o.order_id = :NEW.order_id;

    IF :NEW.raised_by NOT IN (v_buyer_id, v_seller_id) THEN           -- BR-07
        RAISE_APPLICATION_ERROR(-20021,
            'Only the buyer or the seller of an order can raise a dispute');
    END IF;

    IF v_order_status NOT IN ('CREATED', 'HANDED_OVER') THEN
        RAISE_APPLICATION_ERROR(-20022, 'Disputes can be raised only on CREATED or HANDED_OVER orders '
                                        || '(this order is ' || v_order_status || ')');
    END IF;

    -- freeze the escrow: the order moves to DISPUTED until an administrator decides
    UPDATE orders SET status = 'DISPUTED' WHERE order_id = :NEW.order_id;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20023, 'Order does not exist');
END;
/

-- PROCEDURE: ACCEPT_OFFER
CREATE OR REPLACE PROCEDURE accept_offer (
    p_offer_id  IN offers.offer_id%TYPE,
    p_seller_id IN users.user_id%TYPE,
    p_meetup    IN orders.meetup_location%TYPE
)
IS
    v_listing_id     offers.listing_id%TYPE;
    v_buyer_id       offers.buyer_id%TYPE;
    v_price          offers.offered_price%TYPE;
    v_offer_status   offers.status%TYPE;
    v_owner_id       listings.seller_id%TYPE;
    v_listing_status listings.status%TYPE;
    v_balance        users.wallet_balance%TYPE;
    v_fee            orders.platform_fee%TYPE;
    v_order_id       orders.order_id%TYPE;
    v_rejected       NUMBER;
BEGIN
    -- 1. Read the offer
    BEGIN
        SELECT listing_id, buyer_id, offered_price, status
          INTO v_listing_id, v_buyer_id, v_price, v_offer_status
          FROM offers
         WHERE offer_id = p_offer_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20010, 'Offer ' || p_offer_id || ' does not exist');
    END;

    IF v_offer_status <> 'PENDING' THEN
        RAISE_APPLICATION_ERROR(-20011, 'Only PENDING offers can be accepted (this offer is '
                                        || v_offer_status || ')');
    END IF;

    -- 2. Lock the listing row so the same item can never be sold twice
    SELECT seller_id, status
      INTO v_owner_id, v_listing_status
      FROM listings
     WHERE listing_id = v_listing_id
       FOR UPDATE;

    IF v_owner_id <> p_seller_id THEN
        RAISE_APPLICATION_ERROR(-20012, 'Only the seller of this listing can accept its offers');
    END IF;

    IF v_listing_status <> 'ACTIVE' THEN
        RAISE_APPLICATION_ERROR(-20013, 'Listing is not ACTIVE (status: ' || v_listing_status || ')');
    END IF;

    -- 3. Lock the buyer's wallet and check the balance (BR-04)
    SELECT wallet_balance INTO v_balance FROM users WHERE user_id = v_buyer_id FOR UPDATE;

    IF v_balance < v_price THEN
        RAISE_APPLICATION_ERROR(-20014, 'Insufficient wallet balance: buyer has Rs ' || v_balance
                                        || ', offer needs Rs ' || v_price);
    END IF;

    -- 4. Create the order; the platform fee is fixed at this moment (BR-09)
    v_fee := calc_platform_fee(v_listing_id, v_price);
    SELECT NVL(MAX(order_id), 0) + 1 INTO v_order_id FROM orders;      -- next order number

    INSERT INTO orders (order_id, offer_id, platform_fee, meetup_location)
    VALUES (v_order_id, p_offer_id, v_fee, p_meetup);      -- trigger marks the listing RESERVED

    -- 5. Move the buyer's money into escrow (BR-08)
    INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount)
    SELECT NVL(MAX(txn_id), 0) + 1, v_order_id, 'HOLD', v_price FROM escrow_txns;

    UPDATE users SET wallet_balance = wallet_balance - v_price WHERE user_id = v_buyer_id;

    -- 6. Close the negotiation
    UPDATE offers SET status = 'ACCEPTED' WHERE offer_id = p_offer_id;

    UPDATE offers SET status = 'REJECTED'
     WHERE listing_id = v_listing_id
       AND status = 'PENDING'
       AND offer_id <> p_offer_id;
    v_rejected := SQL%ROWCOUNT;

    COMMIT;

    DBMS_OUTPUT.PUT_LINE('Order ' || v_order_id || ' created for offer ' || p_offer_id || '.');
    DBMS_OUTPUT.PUT_LINE('Rs ' || v_price || ' moved to escrow; platform fee Rs ' || v_fee || '.');
    DBMS_OUTPUT.PUT_LINE(v_rejected || ' competing offer(s) rejected.');
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;                     -- undo every step if anything fails
        RAISE;
END accept_offer;
/

-- PROCEDURE: RESOLVE_DISPUTE
CREATE OR REPLACE PROCEDURE resolve_dispute (
    p_dispute_id IN disputes.dispute_id%TYPE,
    p_admin_id   IN users.user_id%TYPE,
    p_decision   IN VARCHAR2        -- 'BUYER' = refund the buyer, 'SELLER' = pay the seller
)
IS
    v_role           users.role%TYPE;
    v_order_id       disputes.order_id%TYPE;
    v_dispute_status disputes.status%TYPE;
    v_price          offers.offered_price%TYPE;
    v_fee            orders.platform_fee%TYPE;
    v_buyer_id       offers.buyer_id%TYPE;
    v_seller_id      listings.seller_id%TYPE;
BEGIN
    -- 1. Only an administrator may resolve a dispute (BR-07)
    BEGIN
        SELECT role INTO v_role FROM users WHERE user_id = p_admin_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            v_role := NULL;
    END;

    IF v_role IS NULL OR v_role <> 'ADMIN' THEN
        RAISE_APPLICATION_ERROR(-20030, 'Only an administrator can resolve disputes');
    END IF;

    IF p_decision IS NULL OR p_decision NOT IN ('BUYER', 'SELLER') THEN
        RAISE_APPLICATION_ERROR(-20031, 'Decision must be BUYER or SELLER');
    END IF;

    -- 2. Lock the dispute row
    BEGIN
        SELECT order_id, status
          INTO v_order_id, v_dispute_status
          FROM disputes
         WHERE dispute_id = p_dispute_id
           FOR UPDATE;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20032, 'Dispute ' || p_dispute_id || ' does not exist');
    END;

    IF v_dispute_status <> 'OPEN' THEN
        RAISE_APPLICATION_ERROR(-20033, 'Dispute ' || p_dispute_id || ' is already resolved ('
                                        || v_dispute_status || ')');
    END IF;

    -- 3. Money details of the disputed order
    SELECT f.offered_price, o.platform_fee, f.buyer_id, l.seller_id
      INTO v_price, v_fee, v_buyer_id, v_seller_id
      FROM orders o
      JOIN offers   f ON f.offer_id   = o.offer_id
      JOIN listings l ON l.listing_id = f.listing_id
     WHERE o.order_id = v_order_id;

    -- 4. Apply the decision
    IF p_decision = 'BUYER' THEN
        INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount)
        SELECT NVL(MAX(txn_id), 0) + 1, v_order_id, 'REFUND', v_price FROM escrow_txns;

        UPDATE users  SET wallet_balance = wallet_balance + v_price WHERE user_id = v_buyer_id;
        -- trg_sync_listing_status then puts the listing back to ACTIVE
        UPDATE orders SET status = 'REFUNDED' WHERE order_id = v_order_id;
        UPDATE disputes
           SET status = 'RESOLVED_BUYER', resolved_by = p_admin_id, resolved_on = SYSDATE
         WHERE dispute_id = p_dispute_id;

        DBMS_OUTPUT.PUT_LINE('Dispute ' || p_dispute_id || ' resolved for the buyer: Rs ' || v_price
                             || ' refunded to user ' || v_buyer_id || '.');
    ELSE
        INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount)
        SELECT NVL(MAX(txn_id), 0) + 1, v_order_id, 'RELEASE', v_price FROM escrow_txns;

        UPDATE users  SET wallet_balance = wallet_balance + (v_price - v_fee)
         WHERE user_id = v_seller_id;
        -- trg_sync_listing_status then marks the listing SOLD
        UPDATE orders SET status = 'COMPLETED' WHERE order_id = v_order_id;
        UPDATE disputes
           SET status = 'RESOLVED_SELLER', resolved_by = p_admin_id, resolved_on = SYSDATE
         WHERE dispute_id = p_dispute_id;

        DBMS_OUTPUT.PUT_LINE('Dispute ' || p_dispute_id || ' resolved for the seller: Rs '
                             || (v_price - v_fee) || ' paid to user ' || v_seller_id
                             || ' (platform fee Rs ' || v_fee || ').');
    END IF;

    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END resolve_dispute;
/

-- PROCEDURE: AUTO_RELEASE_ESCROW
CREATE OR REPLACE PROCEDURE auto_release_escrow (
    p_days IN NUMBER DEFAULT 3        -- buyer's window to raise a dispute after handover
)
IS
    -- explicit cursor: every handed-over order whose dispute window has passed
    CURSOR c_due_orders IS
        SELECT o.order_id, o.platform_fee, f.offered_price, l.seller_id
          FROM orders o
          JOIN offers   f ON f.offer_id   = o.offer_id
          JOIN listings l ON l.listing_id = f.listing_id
         WHERE o.status = 'HANDED_OVER'
           AND o.handed_over_at <= SYSDATE - p_days
           AND NOT EXISTS (SELECT 1 FROM disputes d WHERE d.order_id = o.order_id)
         ORDER BY o.order_id
           FOR UPDATE OF o.status;

    v_rec    c_due_orders%ROWTYPE;
    v_payout NUMBER(10,2);
    v_total  NUMBER(12,2) := 0;
    v_count  NUMBER := 0;
BEGIN
    OPEN c_due_orders;
    LOOP
        FETCH c_due_orders INTO v_rec;
        EXIT WHEN c_due_orders%NOTFOUND;

        v_payout := v_rec.offered_price - v_rec.platform_fee;

        INSERT INTO escrow_txns (txn_id, order_id, txn_type, amount)
        SELECT NVL(MAX(txn_id), 0) + 1, v_rec.order_id, 'RELEASE', v_rec.offered_price
          FROM escrow_txns;

        UPDATE users SET wallet_balance = wallet_balance + v_payout
         WHERE user_id = v_rec.seller_id;

        -- trg_sync_listing_status then marks the listing SOLD
        UPDATE orders SET status = 'COMPLETED' WHERE order_id = v_rec.order_id;

        v_total := v_total + v_payout;
        DBMS_OUTPUT.PUT_LINE('Order ' || v_rec.order_id || ': Rs ' || v_payout
                             || ' released to seller ' || v_rec.seller_id);
    END LOOP;
    v_count := c_due_orders%ROWCOUNT;
    CLOSE c_due_orders;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE(v_count || ' order(s) completed. Total paid to sellers: Rs ' || v_total);
EXCEPTION
    WHEN OTHERS THEN
        IF c_due_orders%ISOPEN THEN
            CLOSE c_due_orders;
        END IF;
        ROLLBACK;
        RAISE;
END auto_release_escrow;
/


-- ============================================================================
-- 7. REVIEW III ADDITIONS: objects needed by the integrated application
--    (each one closes a gap that appeared when the screens were wired up)
-- ============================================================================

-- PROCEDURE: MARK_HANDED_OVER  (FR-10)
-- Review II recorded the handover with a bare UPDATE. In the application the
-- seller presses "Mark handed over", so the rule "only the seller, and only a
-- CREATED order" must be checked inside the database, not in the screen.
CREATE OR REPLACE PROCEDURE mark_handed_over (
    p_order_id  IN orders.order_id%TYPE,
    p_seller_id IN users.user_id%TYPE
)
IS
    v_status    orders.status%TYPE;
    v_seller_id listings.seller_id%TYPE;
    v_title     listings.title%TYPE;
BEGIN
    BEGIN
        SELECT o.status, l.seller_id, l.title
          INTO v_status, v_seller_id, v_title
          FROM orders o
          JOIN offers   f ON f.offer_id   = o.offer_id
          JOIN listings l ON l.listing_id = f.listing_id
         WHERE o.order_id = p_order_id
           FOR UPDATE OF o.status;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20050, 'Order ' || p_order_id || ' does not exist');
    END;

    IF v_seller_id <> p_seller_id THEN
        RAISE_APPLICATION_ERROR(-20051, 'Only the seller of this order can record the handover');
    END IF;

    IF v_status <> 'CREATED' THEN
        RAISE_APPLICATION_ERROR(-20052, 'Only CREATED orders can be handed over (this order is '
                                        || v_status || ')');
    END IF;

    -- trg_sync_listing_status keeps the listing RESERVED
    UPDATE orders
       SET status = 'HANDED_OVER',
           handed_over_at = SYSDATE
     WHERE order_id = p_order_id;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Order ' || p_order_id || ' (' || v_title || ') handed over. '
                         || 'Buyer has 3 days to raise a dispute.');
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END mark_handed_over;
/

-- TRIGGER: TRG_VALIDATE_REVIEW  (FR-15)
-- A review is only meaningful after the deal is closed. Without this trigger
-- a buyer could rate an order that is still in escrow or was refunded.
CREATE OR REPLACE TRIGGER trg_validate_review
BEFORE INSERT ON reviews
FOR EACH ROW
DECLARE
    v_status orders.status%TYPE;
BEGIN
    SELECT status INTO v_status FROM orders WHERE order_id = :NEW.order_id;

    IF v_status <> 'COMPLETED' THEN
        RAISE_APPLICATION_ERROR(-20060, 'Only COMPLETED orders can be reviewed (this order is '
                                        || v_status || ')');
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20061, 'Order does not exist');
END;
/

-- FUNCTION: ESCROW_BALANCE
-- Money still held by the platform for one order:
--   HOLD adds the amount, RELEASE and REFUND take it out.
-- An open order must hold exactly its price; a closed order must hold 0.
-- The Ledger screen uses it to reconcile every order (no money lost or doubled).
CREATE OR REPLACE FUNCTION escrow_balance (
    p_order_id IN orders.order_id%TYPE
) RETURN NUMBER
IS
    v_balance NUMBER;
BEGIN
    SELECT NVL(SUM(CASE WHEN txn_type = 'HOLD' THEN amount ELSE -amount END), 0)
      INTO v_balance
      FROM escrow_txns
     WHERE order_id = p_order_id;

    RETURN v_balance;
END escrow_balance;
/

-- PROCEDURE: SELLER_STATEMENT  (FR-17, second cursor)
-- Prints a seller's account statement: one line per order, then totals.
-- Uses a cursor FOR loop (implicit OPEN / FETCH / CLOSE) over the seller's orders.
CREATE OR REPLACE PROCEDURE seller_statement (
    p_seller_id IN users.user_id%TYPE
)
IS
    CURSOR c_orders IS
        SELECT o.order_id, l.title, f.offered_price, o.platform_fee, o.status
          FROM orders o
          JOIN offers   f ON f.offer_id   = o.offer_id
          JOIN listings l ON l.listing_id = f.listing_id
         WHERE l.seller_id = p_seller_id
         ORDER BY o.order_id;

    v_name     users.full_name%TYPE;
    v_earned   NUMBER(12,2) := 0;
    v_pending  NUMBER(12,2) := 0;
    v_refunded NUMBER(12,2) := 0;
    v_count    NUMBER := 0;
    v_score    NUMBER;
BEGIN
    BEGIN
        SELECT full_name INTO v_name FROM users WHERE user_id = p_seller_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20070, 'User ' || p_seller_id || ' does not exist');
    END;

    DBMS_OUTPUT.PUT_LINE('STATEMENT FOR SELLER ' || p_seller_id || ' - ' || v_name);

    FOR r IN c_orders LOOP
        v_count := v_count + 1;
        IF r.status = 'COMPLETED' THEN
            v_earned := v_earned + (r.offered_price - r.platform_fee);
        ELSIF r.status = 'REFUNDED' THEN
            v_refunded := v_refunded + r.offered_price;
        ELSIF r.status IN ('CREATED', 'HANDED_OVER', 'DISPUTED') THEN
            v_pending := v_pending + (r.offered_price - r.platform_fee);
        END IF;

        DBMS_OUTPUT.PUT_LINE('  #' || r.order_id || '  ' || RPAD(SUBSTR(r.title, 1, 34), 34)
                             || '  Rs ' || LPAD(TO_CHAR(r.offered_price), 6)
                             || '  fee ' || LPAD(TO_CHAR(r.platform_fee), 6)
                             || '  ' || r.status);
    END LOOP;

    v_score := seller_trust_score(p_seller_id);

    DBMS_OUTPUT.PUT_LINE('  Orders: ' || v_count
                         || ' | Paid out: Rs ' || v_earned
                         || ' | In escrow: Rs ' || v_pending
                         || ' | Refunded to buyers: Rs ' || v_refunded);
    DBMS_OUTPUT.PUT_LINE('  Trust score: ' || NVL(TO_CHAR(v_score), 'n/a (no orders yet)'));
END seller_statement;
/

-- ============================================================================
-- 8. OBJECT INVENTORY (every object must show STATUS = VALID)
-- ============================================================================
SELECT object_type, object_name, status
  FROM user_objects
 WHERE object_type IN ('TABLE', 'VIEW', 'FUNCTION', 'PROCEDURE', 'TRIGGER')
   AND object_name IN ('USERS', 'CATEGORIES', 'LISTINGS', 'OFFERS', 'ORDERS', 'ESCROW_TXNS',
                       'REVIEWS', 'DISPUTES', 'ORDER_DETAILS_V',
                       'CALC_PLATFORM_FEE', 'SELLER_TRUST_SCORE', 'ESCROW_BALANCE',
                       'ACCEPT_OFFER', 'RESOLVE_DISPUTE', 'AUTO_RELEASE_ESCROW',
                       'MARK_HANDED_OVER', 'SELLER_STATEMENT',
                       'TRG_VALIDATE_OFFER', 'TRG_VALIDATE_LISTING', 'TRG_SYNC_LISTING_STATUS',
                       'TRG_ON_DISPUTE_RAISED', 'TRG_VALIDATE_REVIEW')
 ORDER BY DECODE(object_type, 'TABLE', 1, 'VIEW', 2, 'FUNCTION', 3, 'PROCEDURE', 4, 5),
          object_name;
