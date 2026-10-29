-- ============================================================================
-- CampusKart - Review III: real-world transaction demonstration (SQL*Plus form)
-- The same 18 steps the application runs from the Trace tab ("Reset & run all").
-- Run AFTER @CampusKart_Review3.sql, in one session, in this order.
-- Statements marked "Expected: ORA-..." must fail: they prove a rule works,
-- and the verification query after them shows nothing changed.
-- ============================================================================
SET SERVEROUTPUT ON
SET LINESIZE 200
SET PAGESIZE 100
SET DEFINE OFF

-- ---------------------------------------------------------------- T1 LISTING
-- T1: Sneha (104) lists a sketch-pen set  -> INSERT + TRG_VALIDATE_LISTING
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price)
SELECT COALESCE(MAX(listing_id), 0) + 1, 104, 8, 'Faber-Castell Sketch Pen Set (24 colours)', 'Sealed pack', 'NEW', 200
  FROM listings;
COMMIT;
SELECT listing_id, seller_id, title, asking_price, status FROM listings WHERE listing_id = 1036;

-- T1x: blocked student Nikhil (115) tries to list
-- Expected: ORA-20005: Blocked users cannot create listings
INSERT INTO listings (listing_id, seller_id, category_id, title, description, item_condition, asking_price)
SELECT COALESCE(MAX(listing_id), 0) + 1, 115, 3, 'Samsung Galaxy Buds', NULL, 'GOOD', 2500
  FROM listings;
ROLLBACK;

-- ----------------------------------------------------------------- T2 OFFERS
-- T2: Vikram (107) offers Rs 750 for the yoga mat (1030) -> INSERT + TRG_VALIDATE_OFFER
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price)
SELECT COALESCE(MAX(offer_id), 0) + 1, 1030, 107, 750 FROM offers;
COMMIT;
SELECT offer_id, listing_id, buyer_id, offered_price, status FROM offers WHERE listing_id = 1030;

-- T2x1: Sanjay (111) offers on his own listing
-- Expected: ORA-20001: You cannot make an offer on your own listing
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price)
SELECT COALESCE(MAX(offer_id), 0) + 1, 1030, 111, 700 FROM offers;
ROLLBACK;

-- T2x2: offer on a listing that is already SOLD
-- Expected: ORA-20002: Offers are allowed only on ACTIVE listings (this listing is SOLD)
INSERT INTO offers (offer_id, listing_id, buyer_id, offered_price)
SELECT COALESCE(MAX(offer_id), 0) + 1, 1001, 105, 400 FROM offers;
ROLLBACK;

-- ------------------------------------------------------------ T3 ESCROW HOLD
-- T3x: Divya (108) accepts Aditya's offer, but Aditya has only Rs 350
-- Expected: ORA-20014: Insufficient wallet balance: buyer has Rs 350, offer needs Rs 1700
BEGIN
    accept_offer(p_offer_id => 5037, p_seller_id => 108, p_meetup => 'SJT Ground Floor');
END;
/

-- T3: Divya accepts Rahul's Rs 1600 offer -> ACCEPT_OFFER + CALC_PLATFORM_FEE + TRG_SYNC_LISTING_STATUS
SELECT user_id, wallet_balance FROM users WHERE user_id IN (105, 108) ORDER BY user_id;
BEGIN
    accept_offer(p_offer_id => 5036, p_seller_id => 108, p_meetup => 'SJT Ground Floor');
END;
/
SELECT offer_id, buyer_id, offered_price, status FROM offers WHERE listing_id = 1029 ORDER BY offer_id;
SELECT listing_id, title, status FROM listings WHERE listing_id = 1029;
SELECT order_id, offer_id, platform_fee, meetup_location, status FROM orders WHERE offer_id = 5036;
SELECT txn_id, order_id, txn_type, amount FROM escrow_txns WHERE order_id = 7028;
SELECT user_id, wallet_balance FROM users WHERE user_id IN (105, 108) ORDER BY user_id;

-- -------------------------------------------------------------- T4 HANDOVER
-- T4: Divya records the handover -> MARK_HANDED_OVER (Review III)
BEGIN
    mark_handed_over(p_order_id => 7028, p_seller_id => 108);
END;
/
SELECT order_id, status, TO_CHAR(handed_over_at, 'DD-MON-YYYY HH24:MI') AS handed_over_at FROM orders WHERE order_id = 7028;

-- ------------------------------------------------------------- T5 / T6 DISPUTE
-- T5: Rahul (105) raises a dispute -> INSERT + TRG_ON_DISPUTE_RAISED (order frozen as DISPUTED)
INSERT INTO disputes (dispute_id, order_id, raised_by, reason)
SELECT COALESCE(MAX(dispute_id), 0) + 1, 7028, 105, 'Speaker crackles at high volume' FROM disputes;
COMMIT;
SELECT d.dispute_id, d.status AS dispute_status, o.status AS order_status
  FROM disputes d JOIN orders o ON o.order_id = d.order_id WHERE d.order_id = 7028;

-- T6x: a student (103) tries to resolve it
-- Expected: ORA-20030: Only an administrator can resolve disputes
BEGIN
    resolve_dispute(p_dispute_id => 9011, p_admin_id => 103, p_decision => 'BUYER');
END;
/

-- T6a: administrator 116 refunds the buyer -> RESOLVE_DISPUTE
BEGIN
    resolve_dispute(p_dispute_id => 9011, p_admin_id => 116, p_decision => 'BUYER');
END;
/
-- T6b: administrator 117 pays the seller of dispute 9007
BEGIN
    resolve_dispute(p_dispute_id => 9007, p_admin_id => 117, p_decision => 'SELLER');
END;
/
SELECT d.dispute_id, d.status AS dispute_status, d.resolved_by, o.order_id, o.status AS order_status,
       l.listing_id, l.status AS listing_status
  FROM disputes d
  JOIN orders   o ON o.order_id   = d.order_id
  JOIN offers   f ON f.offer_id   = o.offer_id
  JOIN listings l ON l.listing_id = f.listing_id
 WHERE d.dispute_id IN (9007, 9011)
 ORDER BY d.dispute_id;
SELECT txn_id, order_id, txn_type, amount FROM escrow_txns WHERE order_id IN (7019, 7028) ORDER BY txn_id;
SELECT user_id, full_name, wallet_balance FROM users WHERE user_id IN (105, 112) ORDER BY user_id;

-- ---------------------------------------------------------- T7 BATCH CURSOR
-- T7: nightly batch -> AUTO_RELEASE_ESCROW (explicit cursor C_DUE_ORDERS)
SELECT order_id, status, CASE WHEN handed_over_at <= SYSDATE - 3 THEN 'YES' ELSE 'NO' END AS window_over
  FROM orders WHERE status = 'HANDED_OVER' ORDER BY order_id;
BEGIN
    auto_release_escrow(p_days => 3);
END;
/
SELECT order_id, status FROM orders WHERE order_id IN (7023, 7024, 7025) ORDER BY order_id;
SELECT user_id, full_name, wallet_balance FROM users WHERE user_id IN (101, 110, 114) ORDER BY user_id;

-- ---------------------------------------------------------------- T8 REVIEW
-- T8: Ananya (106) rates order 7023 -> INSERT + TRG_VALIDATE_REVIEW; trust score changes
SELECT seller_trust_score(101) AS trust_before FROM dual;
INSERT INTO reviews (review_id, order_id, rating, review_comment)
SELECT COALESCE(MAX(review_id), 0) + 1, 7023, 5, 'Exactly as described, met on time' FROM reviews;
COMMIT;
SELECT seller_trust_score(101) AS trust_after FROM dual;

-- T8x: review an order that is still in escrow
-- Expected: ORA-20060: Only COMPLETED orders can be reviewed (this order is CREATED)
INSERT INTO reviews (review_id, order_id, rating, review_comment)
SELECT COALESCE(MAX(review_id), 0) + 1, 7026, 4, 'Looks fine' FROM reviews;
ROLLBACK;

-- ------------------------------------------------------------ DELETE / UPDATE
-- T2b: Sanjay deletes his pending offer 5035 (DELETE)
DELETE FROM offers WHERE offer_id = 5035 AND buyer_id = 111 AND status = 'PENDING';
COMMIT;
-- T9: Aditya tops up his wallet (UPDATE)
UPDATE users SET wallet_balance = wallet_balance + 2000 WHERE user_id = 109;
COMMIT;

-- ------------------------------------------------------------------ REPORTS
-- R3: seller statement (cursor FOR loop + DBMS_OUTPUT)
BEGIN
    seller_statement(p_seller_id => 110);
END;
/

-- R1: escrow reconciliation - every order must show OK
SELECT o.order_id, o.status, f.offered_price AS price, escrow_balance(o.order_id) AS held_now,
       CASE WHEN escrow_balance(o.order_id) =
                 CASE WHEN o.status IN ('CREATED', 'HANDED_OVER', 'DISPUTED') THEN f.offered_price ELSE 0 END
            THEN 'OK' ELSE 'MISMATCH' END AS check_result
  FROM orders o JOIN offers f ON f.offer_id = o.offer_id
 ORDER BY o.order_id;

-- Q11: escrow ledger summary after the demonstration
SELECT SUM(CASE WHEN txn_type = 'HOLD'    THEN amount ELSE 0 END) AS total_held,
       SUM(CASE WHEN txn_type = 'RELEASE' THEN amount ELSE 0 END) AS total_released,
       SUM(CASE WHEN txn_type = 'REFUND'  THEN amount ELSE 0 END) AS total_refunded,
       SUM(CASE WHEN txn_type = 'HOLD' THEN amount ELSE -amount END) AS currently_in_escrow
  FROM escrow_txns;
