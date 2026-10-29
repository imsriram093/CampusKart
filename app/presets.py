"""
Viva presets: the demonstration script for Review III.

Run in this order on a freshly reset database. Each step is one real
transaction; the ones marked expect=ROLLBACK prove that a business rule
inside the database stops a bad operation and leaves the tables unchanged.
"""

PRESETS = [
    # ---------------------------------------------------------------- listing
    {"id": "p01", "group": "Happy path", "kind": "create_listing", "expect": "COMMIT",
     "label": "Sneha lists a sketch-pen set",
     "params": {"actor": 104, "category_id": 8, "title": "Faber-Castell Sketch Pen Set (24 colours)",
                "description": "Sealed pack", "item_condition": "NEW", "asking_price": 200}},
    {"id": "p02", "group": "Rules that stop bad data", "kind": "create_listing", "expect": "ROLLBACK",
     "label": "Blocked user Nikhil tries to list",
     "params": {"actor": 115, "category_id": 3, "title": "Samsung Galaxy Buds",
                "description": "", "item_condition": "GOOD", "asking_price": 2500}},
    # ------------------------------------------------------------------ offers
    {"id": "p03", "group": "Happy path", "kind": "make_offer", "expect": "COMMIT",
     "label": "Vikram offers Rs 750 for the yoga mat",
     "params": {"actor": 107, "listing_id": 1030, "offered_price": 750}},
    {"id": "p04", "group": "Rules that stop bad data", "kind": "make_offer", "expect": "ROLLBACK",
     "label": "Sanjay offers on his own listing",
     "params": {"actor": 111, "listing_id": 1030, "offered_price": 700}},
    {"id": "p05", "group": "Rules that stop bad data", "kind": "make_offer", "expect": "ROLLBACK",
     "label": "Offer on a book that is already SOLD",
     "params": {"actor": 105, "listing_id": 1001, "offered_price": 400}},
    # ------------------------------------------------------------ escrow hold
    {"id": "p06", "group": "Rules that stop bad data", "kind": "accept_offer", "expect": "ROLLBACK",
     "label": "Accept an offer the buyer cannot afford",
     "params": {"actor": 108, "offer_id": 5037, "meetup_location": "SJT Ground Floor"}},
    {"id": "p07", "group": "Happy path", "kind": "accept_offer", "expect": "COMMIT",
     "label": "Divya accepts Rahul's Rs 1600 for the speaker",
     "params": {"actor": 108, "offer_id": 5036, "meetup_location": "SJT Ground Floor"}},
    # ---------------------------------------------------------------- handover
    {"id": "p08", "group": "Happy path", "kind": "mark_handed_over", "expect": "COMMIT",
     "label": "Divya records the handover of order 7028",
     "params": {"actor": 108, "order_id": 7028}},
    # ---------------------------------------------------------------- disputes
    {"id": "p09", "group": "Happy path", "kind": "raise_dispute", "expect": "COMMIT",
     "label": "Rahul disputes: speaker crackles",
     "params": {"actor": 105, "order_id": 7028, "reason": "Speaker crackles at high volume"}},
    {"id": "p10", "group": "Rules that stop bad data", "kind": "resolve_dispute", "expect": "ROLLBACK",
     "label": "A student tries to resolve the dispute",
     "params": {"actor": 103, "dispute_id": 9011, "decision": "BUYER"}},
    {"id": "p11", "group": "Happy path", "kind": "resolve_dispute", "expect": "COMMIT",
     "label": "Admin refunds Rahul (decision: BUYER)",
     "params": {"actor": 116, "dispute_id": 9011, "decision": "BUYER"}},
    {"id": "p12", "group": "Happy path", "kind": "resolve_dispute", "expect": "COMMIT",
     "label": "Admin pays Harini for dispute 9007 (SELLER)",
     "params": {"actor": 117, "dispute_id": 9007, "decision": "SELLER"}},
    # ------------------------------------------------------------ batch cursor
    {"id": "p13", "group": "Batch job and reports", "kind": "auto_release", "expect": "COMMIT",
     "label": "Run the nightly auto-release cursor",
     "params": {"actor": 116, "days": 3}},
    # ----------------------------------------------------------------- reviews
    {"id": "p14", "group": "Happy path", "kind": "submit_review", "expect": "COMMIT",
     "label": "Ananya rates the Korth textbook 5 stars",
     "params": {"actor": 106, "order_id": 7023, "rating": 5, "comment": "Exactly as described, met on time"}},
    {"id": "p15", "group": "Rules that stop bad data", "kind": "submit_review", "expect": "ROLLBACK",
     "label": "Review an order that is still in escrow",
     "params": {"actor": 112, "order_id": 7026, "rating": 4, "comment": "Looks fine"}},
    # ---------------------------------------------------------------- DML misc
    {"id": "p16", "group": "Happy path", "kind": "withdraw_offer", "expect": "COMMIT",
     "label": "Sanjay deletes his pending offer 5035",
     "params": {"actor": 111, "offer_id": 5035}},
    {"id": "p17", "group": "Happy path", "kind": "topup_wallet", "expect": "COMMIT",
     "label": "Aditya tops up his wallet by Rs 2000",
     "params": {"actor": 109, "amount": 2000}},
    {"id": "p18", "group": "Batch job and reports", "kind": "seller_statement", "expect": "REPORT",
     "label": "Seller statement for Meera (cursor report)",
     "params": {"actor": 116, "seller_id": 110}},
]
