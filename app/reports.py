"""
Report catalogue.

Q1-Q20 are the Review II queries, copied verbatim from CampusKart_Review2.sql.
R1-R2 are Review III reports built on the new ESCROW_BALANCE function and on
SELLER_TRUST_SCORE. "used_by" names the screen of the application that runs
the same query (or a parameterised form of it), showing the queries are part
of the application rather than separate exercises.

The same SQL text runs on Oracle and on the SQLite mirror (the mirror registers
TO_CHAR, NVL and the PL/SQL functions as SQLite functions).
"""

REPORTS = [
    {
        "key": 'Q1',
        "title": 'Active listings under Rs 1,000',
        "concept": 'Selection, WHERE with multiple conditions, ORDER BY',
        "group": 'Retrieval',
        "used_by": 'Market tab: catalogue filter (price ceiling)',
        "sql": """SELECT listing_id, title, item_condition, asking_price
  FROM listings
 WHERE status = 'ACTIVE'
   AND asking_price < 1000
 ORDER BY asking_price, listing_id""",
    },
    {
        "key": 'Q2',
        "title": 'Keyword search on listing titles',
        "concept": 'Pattern matching with LIKE and UPPER',
        "group": 'Retrieval',
        "used_by": 'Market tab: keyword search',
        "sql": """SELECT listing_id, title, asking_price, status
  FROM listings
 WHERE UPPER(title) LIKE '%CASIO%'
 ORDER BY listing_id""",
    },
    {
        "key": 'Q3',
        "title": 'Active listings with seller and category',
        "concept": 'INNER JOIN of three tables',
        "group": 'Joins',
        "used_by": 'Market tab: catalogue cards (listing + seller + category)',
        "sql": """SELECT l.listing_id, l.title, c.category_name, u.full_name AS seller, u.hostel_block, l.asking_price
  FROM listings l
  JOIN users u      ON u.user_id     = l.seller_id
  JOIN categories c ON c.category_id = l.category_id
 WHERE l.status = 'ACTIVE'
 ORDER BY c.category_name, l.listing_id""",
    },
    {
        "key": 'Q4',
        "title": 'Completed orders with buyer, seller and payout',
        "concept": 'Five-table join with a computed column',
        "group": 'Joins',
        "used_by": None,
        "sql": """SELECT o.order_id, l.title, b.full_name AS buyer, s.full_name AS seller,
       f.offered_price AS final_price, o.platform_fee,
       f.offered_price - o.platform_fee AS seller_payout
  FROM orders o
  JOIN offers   f ON f.offer_id   = o.offer_id
  JOIN listings l ON l.listing_id = f.listing_id
  JOIN users    b ON b.user_id    = f.buyer_id
  JOIN users    s ON s.user_id    = l.seller_id
 WHERE o.status = 'COMPLETED'
 ORDER BY o.order_id""",
    },
    {
        "key": 'Q5',
        "title": 'Active listings that have no offers yet',
        "concept": 'LEFT OUTER JOIN with IS NULL (anti-join)',
        "group": 'Joins',
        "used_by": None,
        "sql": """SELECT l.listing_id, l.title, l.asking_price
  FROM listings l
  LEFT JOIN offers f ON f.listing_id = l.listing_id
 WHERE l.status = 'ACTIVE'
   AND f.offer_id IS NULL
 ORDER BY l.listing_id""",
    },
    {
        "key": 'Q6',
        "title": 'Sales and platform revenue per category',
        "concept": 'GROUP BY with COUNT and SUM',
        "group": 'Aggregation',
        "used_by": 'Ledger tab: sales by category bars',
        "sql": """SELECT c.category_name,
       COUNT(o.order_id)    AS items_sold,
       SUM(f.offered_price) AS sales_value,
       SUM(o.platform_fee)  AS platform_revenue
  FROM orders o
  JOIN offers     f ON f.offer_id    = o.offer_id
  JOIN listings   l ON l.listing_id  = f.listing_id
  JOIN categories c ON c.category_id = l.category_id
 WHERE o.status = 'COMPLETED'
 GROUP BY c.category_name
 ORDER BY platform_revenue DESC, c.category_name""",
    },
    {
        "key": 'Q7',
        "title": 'Listings that received more than one offer',
        "concept": 'GROUP BY with HAVING',
        "group": 'Aggregation',
        "used_by": None,
        "sql": """SELECT l.listing_id, l.title,
       COUNT(f.offer_id)    AS offers_received,
       MAX(f.offered_price) AS highest_offer
  FROM listings l
  JOIN offers f ON f.listing_id = l.listing_id
 GROUP BY l.listing_id, l.title
HAVING COUNT(f.offer_id) > 1
 ORDER BY offers_received DESC, l.listing_id""",
    },
    {
        "key": 'Q8',
        "title": 'Listings priced above their category average',
        "concept": 'Correlated subquery',
        "group": 'Subqueries',
        "used_by": None,
        "sql": """SELECT l.listing_id, l.title, l.category_id, l.asking_price
  FROM listings l
 WHERE l.asking_price > (SELECT AVG(l2.asking_price)
                           FROM listings l2
                          WHERE l2.category_id = l.category_id)
 ORDER BY l.category_id, l.listing_id""",
    },
    {
        "key": 'Q9',
        "title": 'Students who bought an Electronics item',
        "concept": 'Nested subqueries with IN',
        "group": 'Subqueries',
        "used_by": None,
        "sql": """SELECT user_id, full_name, hostel_block
  FROM users
 WHERE user_id IN
       (SELECT f.buyer_id
          FROM offers f
         WHERE f.status = 'ACCEPTED'
           AND f.listing_id IN
               (SELECT l.listing_id
                  FROM listings l
                 WHERE l.category_id =
                       (SELECT category_id
                          FROM categories
                         WHERE category_name = 'Electronics')))
 ORDER BY user_id""",
    },
    {
        "key": 'Q10',
        "title": 'Sellers who have listed items but made no sale yet',
        "concept": 'EXISTS and NOT EXISTS',
        "group": 'Subqueries',
        "used_by": None,
        "sql": """SELECT u.user_id, u.full_name, u.reg_no
  FROM users u
 WHERE EXISTS (SELECT 1 FROM listings l WHERE l.seller_id = u.user_id)
   AND NOT EXISTS (SELECT 1
                     FROM listings l
                     JOIN offers f ON f.listing_id = l.listing_id
                     JOIN orders o ON o.offer_id   = f.offer_id
                    WHERE l.seller_id = u.user_id)
 ORDER BY u.user_id""",
    },
    {
        "key": 'Q11',
        "title": 'Escrow ledger summary',
        "concept": 'Conditional aggregation with CASE',
        "group": 'Aggregation',
        "used_by": 'Ledger tab: escrow totals and gauge',
        "sql": """SELECT SUM(CASE WHEN txn_type = 'HOLD'    THEN amount ELSE 0 END) AS total_held,
       SUM(CASE WHEN txn_type = 'RELEASE' THEN amount ELSE 0 END) AS total_released,
       SUM(CASE WHEN txn_type = 'REFUND'  THEN amount ELSE 0 END) AS total_refunded,
       SUM(CASE WHEN txn_type = 'HOLD' THEN amount ELSE -amount END) AS currently_in_escrow
  FROM escrow_txns""",
    },
    {
        "key": 'Q12',
        "title": 'Dispute statistics per seller',
        "concept": 'LEFT JOIN, GROUP BY, conditional COUNT and a ratio',
        "group": 'Aggregation',
        "used_by": None,
        "sql": """SELECT l.seller_id, u.full_name AS seller,
       COUNT(o.order_id)  AS orders,
       COUNT(d.dispute_id) AS disputes,
       COUNT(CASE WHEN d.status = 'RESOLVED_BUYER' THEN 1 END) AS disputes_lost,
       ROUND(100.0 * COUNT(d.dispute_id) / COUNT(o.order_id), 1) AS dispute_rate_pct
  FROM orders o
  JOIN offers   f ON f.offer_id   = o.offer_id
  JOIN listings l ON l.listing_id = f.listing_id
  JOIN users    u ON u.user_id    = l.seller_id
  LEFT JOIN disputes d ON d.order_id = o.order_id
 GROUP BY l.seller_id, u.full_name
 ORDER BY dispute_rate_pct DESC, l.seller_id""",
    },
    {
        "key": 'Q13',
        "title": 'Buyers ranked by total spending',
        "concept": 'Analytic function RANK() OVER',
        "group": 'Analytics',
        "used_by": None,
        "sql": """SELECT f.buyer_id, u.full_name AS buyer,
       COUNT(*)             AS purchases,
       SUM(f.offered_price) AS total_spent,
       RANK() OVER (ORDER BY SUM(f.offered_price) DESC) AS spend_rank
  FROM orders o
  JOIN offers f ON f.offer_id = o.offer_id
  JOIN users  u ON u.user_id  = f.buyer_id
 WHERE o.status = 'COMPLETED'
 GROUP BY f.buyer_id, u.full_name
 ORDER BY spend_rank, f.buyer_id""",
    },
    {
        "key": 'Q14',
        "title": 'Students who have both bought and sold',
        "concept": 'Set operation INTERSECT inside a subquery',
        "group": 'Set operations',
        "used_by": None,
        "sql": """SELECT u.user_id, u.full_name
  FROM users u
 WHERE u.user_id IN (SELECT l.seller_id
                       FROM listings l
                       JOIN offers f ON f.listing_id = l.listing_id
                       JOIN orders o ON o.offer_id   = f.offer_id
                     INTERSECT
                     SELECT f.buyer_id
                       FROM offers f
                       JOIN orders o ON o.offer_id = f.offer_id)
 ORDER BY u.user_id""",
    },
    {
        "key": 'Q15',
        "title": 'Monthly order trend',
        "concept": 'Date function TO_CHAR with GROUP BY',
        "group": 'Aggregation',
        "used_by": None,
        "sql": """SELECT TO_CHAR(o.created_at, 'YYYY-MM') AS order_month,
       COUNT(*)             AS orders_created,
       SUM(f.offered_price) AS order_value
  FROM orders o
  JOIN offers f ON f.offer_id = o.offer_id
 GROUP BY TO_CHAR(o.created_at, 'YYYY-MM')
 ORDER BY order_month""",
    },
    {
        "key": 'Q16',
        "title": 'Average negotiation discount per category',
        "concept": 'Arithmetic expressions inside AVG',
        "group": 'Aggregation',
        "used_by": None,
        "sql": """SELECT c.category_name,
       COUNT(*) AS accepted_offers,
       ROUND(AVG((l.asking_price - f.offered_price) * 100 / l.asking_price), 2) AS avg_discount_pct
  FROM offers f
  JOIN listings   l ON l.listing_id  = f.listing_id
  JOIN categories c ON c.category_id = l.category_id
 WHERE f.status = 'ACCEPTED'
 GROUP BY c.category_name
 ORDER BY avg_discount_pct DESC, c.category_name""",
    },
    {
        "key": 'Q17',
        "title": 'Open disputes awaiting an administrator',
        "concept": 'Join with USERS used in two roles',
        "group": 'Joins',
        "used_by": 'Orders tab: administrator dispute desk',
        "sql": """SELECT d.dispute_id, d.order_id, l.title,
       r.full_name AS raised_by, d.reason,
       TO_CHAR(d.raised_on, 'DD-MON-YYYY') AS raised_on
  FROM disputes d
  JOIN orders   o ON o.order_id   = d.order_id
  JOIN offers   f ON f.offer_id   = o.offer_id
  JOIN listings l ON l.listing_id = f.listing_id
  JOIN users    r ON r.user_id    = d.raised_by
 WHERE d.status = 'OPEN'
 ORDER BY d.raised_on, d.dispute_id""",
    },
    {
        "key": 'Q18',
        "title": 'Students with an above-average wallet balance',
        "concept": 'Scalar subquery with an aggregate',
        "group": 'Subqueries',
        "used_by": None,
        "sql": """SELECT user_id, full_name, wallet_balance
  FROM users
 WHERE role = 'STUDENT'
   AND wallet_balance > (SELECT AVG(wallet_balance) FROM users WHERE role = 'STUDENT')
 ORDER BY wallet_balance DESC, user_id""",
    },
    {
        "key": 'Q19',
        "title": 'Seller ratings (sellers with at least two reviews)',
        "concept": 'JOIN, GROUP BY, HAVING and ROUND(AVG)',
        "group": 'Aggregation',
        "used_by": None,
        "sql": """SELECT l.seller_id, u.full_name AS seller,
       COUNT(r.review_id)      AS reviews,
       ROUND(AVG(r.rating), 2) AS avg_rating
  FROM reviews r
  JOIN orders   o ON o.order_id   = r.order_id
  JOIN offers   f ON f.offer_id   = o.offer_id
  JOIN listings l ON l.listing_id = f.listing_id
  JOIN users    u ON u.user_id    = l.seller_id
 GROUP BY l.seller_id, u.full_name
HAVING COUNT(r.review_id) >= 2
 ORDER BY avg_rating DESC, l.seller_id""",
    },
    {
        "key": 'Q20',
        "title": 'Orders still in progress, read through a view',
        "concept": 'CREATE VIEW, then a query on the view',
        "group": 'Views',
        "used_by": 'Orders tab: order cards are read from ORDER_DETAILS_V',
        "sql": """SELECT order_id, title, buyer_name, final_price, order_status
  FROM order_details_v
 WHERE order_status IN ('CREATED', 'HANDED_OVER', 'DISPUTED')
 ORDER BY order_id""",
    },
    {
        "key": "R1",
        "title": "Escrow reconciliation: is every rupee accounted for?",
        "concept": "Review III function ESCROW_BALANCE called per row, CASE, scalar comparison",
        "group": "Review III",
        "used_by": "Ledger tab: reconciliation check",
        "sql": """SELECT o.order_id, o.status, f.offered_price AS price,
       escrow_balance(o.order_id) AS held_now,
       CASE WHEN o.status IN ('CREATED', 'HANDED_OVER', 'DISPUTED')
            THEN f.offered_price ELSE 0 END AS should_hold,
       CASE WHEN escrow_balance(o.order_id) =
                 CASE WHEN o.status IN ('CREATED', 'HANDED_OVER', 'DISPUTED')
                      THEN f.offered_price ELSE 0 END
            THEN 'OK' ELSE 'MISMATCH' END AS check_result
  FROM orders o
  JOIN offers f ON f.offer_id = o.offer_id
 ORDER BY o.order_id""",
    },
    {
        "key": "R2",
        "title": "Seller trust leaderboard",
        "concept": "Function SELLER_TRUST_SCORE in SELECT, RANK() OVER, subquery in WHERE",
        "group": "Review III",
        "used_by": "Header: trust score of the acting user",
        "sql": """SELECT u.user_id, u.full_name, u.hostel_block,
       seller_trust_score(u.user_id) AS trust_score,
       RANK() OVER (ORDER BY seller_trust_score(u.user_id) DESC) AS trust_rank
  FROM users u
 WHERE u.user_id IN (SELECT l.seller_id
                       FROM listings l
                       JOIN offers f ON f.listing_id = l.listing_id
                       JOIN orders o ON o.offer_id   = f.offer_id)
 ORDER BY trust_rank, u.user_id""",
    },
]

REPORT_INDEX = {r["key"]: r for r in REPORTS}
