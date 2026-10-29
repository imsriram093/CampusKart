-- ============================================================================
-- SQLite translations of the five Oracle triggers (mirror mode only).
-- Created AFTER the sample data is loaded, exactly as in Oracle where the
-- triggers are compiled after Section 2.
-- ============================================================================

-- TRG_VALIDATE_LISTING (BR-03)
CREATE TRIGGER trg_validate_listing
BEFORE INSERT ON listings
BEGIN
    SELECT ck_raise(-20006, 'Seller does not exist')
     WHERE NOT EXISTS (SELECT 1 FROM users WHERE user_id = NEW.seller_id);
    SELECT ck_raise(-20005, 'Blocked users cannot create listings')
      FROM users WHERE user_id = NEW.seller_id AND is_blocked = 'Y';
END;

-- TRG_VALIDATE_OFFER (BR-01, BR-02, BR-03)
CREATE TRIGGER trg_validate_offer
BEFORE INSERT ON offers
BEGIN
    SELECT ck_raise(-20004, 'Listing or buyer does not exist')
     WHERE NOT EXISTS (SELECT 1 FROM listings WHERE listing_id = NEW.listing_id);
    SELECT ck_raise(-20001, 'You cannot make an offer on your own listing')
      FROM listings WHERE listing_id = NEW.listing_id AND seller_id = NEW.buyer_id;
    SELECT ck_raise(-20002, 'Offers are allowed only on ACTIVE listings (this listing is '
                            || status || ')')
      FROM listings WHERE listing_id = NEW.listing_id AND status <> 'ACTIVE';
    SELECT ck_raise(-20004, 'Listing or buyer does not exist')
     WHERE NOT EXISTS (SELECT 1 FROM users WHERE user_id = NEW.buyer_id);
    SELECT ck_raise(-20003, 'Blocked users cannot make offers')
      FROM users WHERE user_id = NEW.buyer_id AND is_blocked = 'Y';
END;

-- TRG_SYNC_LISTING_STATUS (Oracle: AFTER INSERT OR UPDATE OF status ON orders)
CREATE TRIGGER trg_sync_listing_status_ins
AFTER INSERT ON orders
BEGIN
    UPDATE listings
       SET status = CASE NEW.status
                        WHEN 'COMPLETED' THEN 'SOLD'
                        WHEN 'REFUNDED'  THEN 'ACTIVE'
                        WHEN 'CANCELLED' THEN 'ACTIVE'
                        ELSE 'RESERVED'
                    END
     WHERE listing_id = (SELECT listing_id FROM offers WHERE offer_id = NEW.offer_id);
END;

CREATE TRIGGER trg_sync_listing_status_upd
AFTER UPDATE OF status ON orders
BEGIN
    UPDATE listings
       SET status = CASE NEW.status
                        WHEN 'COMPLETED' THEN 'SOLD'
                        WHEN 'REFUNDED'  THEN 'ACTIVE'
                        WHEN 'CANCELLED' THEN 'ACTIVE'
                        ELSE 'RESERVED'
                    END
     WHERE listing_id = (SELECT listing_id FROM offers WHERE offer_id = NEW.offer_id);
END;

-- TRG_ON_DISPUTE_RAISED (BR-07; freezes the escrow)
CREATE TRIGGER trg_on_dispute_raised
BEFORE INSERT ON disputes
BEGIN
    SELECT ck_raise(-20023, 'Order does not exist')
     WHERE NOT EXISTS (SELECT 1 FROM orders WHERE order_id = NEW.order_id);
    SELECT ck_raise(-20021, 'Only the buyer or the seller of an order can raise a dispute')
      FROM orders o
      JOIN offers   f ON f.offer_id   = o.offer_id
      JOIN listings l ON l.listing_id = f.listing_id
     WHERE o.order_id = NEW.order_id
       AND NEW.raised_by NOT IN (f.buyer_id, l.seller_id);
    SELECT ck_raise(-20022, 'Disputes can be raised only on CREATED or HANDED_OVER orders '
                            || '(this order is ' || status || ')')
      FROM orders WHERE order_id = NEW.order_id AND status NOT IN ('CREATED', 'HANDED_OVER');
    UPDATE orders SET status = 'DISPUTED' WHERE order_id = NEW.order_id;
END;

-- TRG_VALIDATE_REVIEW (FR-15, Review III)
CREATE TRIGGER trg_validate_review
BEFORE INSERT ON reviews
BEGIN
    SELECT ck_raise(-20061, 'Order does not exist')
     WHERE NOT EXISTS (SELECT 1 FROM orders WHERE order_id = NEW.order_id);
    SELECT ck_raise(-20060, 'Only COMPLETED orders can be reviewed (this order is '
                            || status || ')')
      FROM orders WHERE order_id = NEW.order_id AND status <> 'COMPLETED';
END;
