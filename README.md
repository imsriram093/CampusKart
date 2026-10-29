# CampusKart: Review III Integrated Application

A peer-to-peer campus resale marketplace with **escrow-based payment protection**.
BCSE302L Database Systems, VIT Vellore.
Team: Parthiban M (24BYB0135), Sriram K (24BYB0151), Vimalaadhityan (24BYB0145).

The browser UI (Flask + vanilla JS) talks to **Oracle** through `python-oracledb`.
Every button runs a real SQL statement or PL/SQL procedure. The **Trace** tab shows,
for every transaction, the operation, the tables, the SQL/PL-SQL component, the
before/after rows and the result (DBMS_OUTPUT, COMMIT or ROLLBACK).

```
campuskart/
├── run.py                     start the application
├── setup_db.py                build the Oracle schema from the SQL script
├── requirements.txt           flask, oracledb
├── .env.example               copy to .env and fill in your Oracle login
├── database/
│   ├── CampusKart_Review3.sql               complete build: tables, data, all PL/SQL (run this first)
│   └── CampusKart_Review3_Transactions.sql  the 18 demo transactions in SQL*Plus form
├── app/
│   ├── server.py              REST API (all SQL uses bind variables)
│   ├── transactions.py        transaction engine: before/after snapshots, traces
│   ├── reports.py             Q1-Q20 (Review II) + R1-R2 (Review III)
│   ├── presets.py             the viva demonstration script
│   └── db/
│       ├── oracle_driver.py   python-oracledb (Thin mode, no Instant Client needed)
│       ├── mirror_driver.py   offline SQLite mirror (same rules, same ORA- errors)
│       ├── mirror_schema.sql, mirror_triggers.sql
│       └── sqlscript.py       SQL*Plus script splitter (";" and "/")
└── web/                       index.html, style.css, app.js, fonts/
```

## 1. Install (once)

```bash
python -m pip install -r requirements.txt
```
Python 3.9 or newer. No Oracle Client install is needed: python-oracledb runs in Thin mode.

## 2. Point it at your Oracle account

Copy `.env.example` to `.env` and edit:
```
CK_DB_MODE=oracle
ORACLE_USER=your_lab_username
ORACLE_PASSWORD=your_password
ORACLE_DSN=localhost:1521/XEPDB1      # 23ai Free: localhost:1521/FREEPDB1
```

## 3. Build the database

Either run `@database/CampusKart_Review3.sql` in SQL*Plus or SQL Developer (F5), or:
```bash
python setup_db.py
```
It prints the object inventory. All 22 objects must show `VALID`.

## 4. Run

```bash
python run.py            # uses .env (Oracle)
python run.py --mirror   # offline demo without Oracle (SQLite mirror)
```
Open **http://127.0.0.1:5000**. The header chip shows which database is live:
`DB: ORACLE 21.x (USER@DSN)` or `DB: SQLITE MIRROR`.

## 5. Viva demonstration

Go to **03 Trace**, then click **Reset & run all**. The app rebuilds the database and runs the
18-step script: 10 transactions that must COMMIT, 6 that a database rule must ROLLBACK,
the batch cursor and a report. Click any history row to replay its trace.
Then explore by hand: pick a user in **Acting as**, make an offer in **01 Market**, accept it
as the seller, mark it handed over in **02 Orders**, check the ledger in **04 Ledger**.

| Code | Transaction | SQL / PL-SQL used |
|------|-------------|-------------------|
| T1 | List an item | INSERT, TRG_VALIDATE_LISTING |
| T2 | Make an offer | INSERT, TRG_VALIDATE_OFFER |
| T3 | Accept offer (escrow HOLD) | ACCEPT_OFFER, CALC_PLATFORM_FEE, TRG_SYNC_LISTING_STATUS |
| T4 | Record handover | MARK_HANDED_OVER *(Review III)* |
| T5 | Raise dispute | INSERT, TRG_ON_DISPUTE_RAISED |
| T6 | Resolve dispute | RESOLVE_DISPUTE |
| T7 | Nightly auto-release | AUTO_RELEASE_ESCROW (explicit cursor) |
| T8 | Rate the seller | INSERT, TRG_VALIDATE_REVIEW *(Review III)*, SELLER_TRUST_SCORE |
| T2b / T9 / T10 | Delete offer, wallet top-up, block user | DELETE / UPDATE |
| R1-R3 | Reports | ESCROW_BALANCE, SELLER_STATEMENT (cursor FOR loop), Q1-Q20 |

## Fonts

The UI uses the AI-TOG fonts. Copy the `.woff2` files from your AI-TOG `web/fonts/` folder
(orbitron-latin-600/700/800, rajdhani-latin-500/600/700, jetbrains-mono-latin-400/600/700)
into `web/fonts/`. Without them the app falls back to the bundled Tektur, Jura and
JetBrains Mono (all SIL Open Font Licence).

## Troubleshooting

* `DPY-6005 / ORA-12514` (cannot connect): check the service name in `ORACLE_DSN` (`lsnrctl status`).
* `ORA-00942 table or view does not exist`: run step 3 first. The app shows a banner for this.
* `ORA-01031 insufficient privileges`: your account needs CREATE TABLE, CREATE PROCEDURE,
  CREATE TRIGGER and CREATE VIEW (no CREATE SEQUENCE is needed).
* In auto mode, if Oracle cannot be reached the app falls back to the SQLite mirror and
  says so in a banner. Use `CK_DB_MODE=oracle` during the evaluation so the app fails loudly instead.