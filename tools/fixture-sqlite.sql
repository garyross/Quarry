-- quarry_demo.sqlite (S-068): a small store, like quarry_demo on the test server.
-- Made in /tmp by tools/snap.sh and tools/selftest.sh with /usr/bin/sqlite3.
PRAGMA foreign_keys = ON;

CREATE TABLE customers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  email TEXT UNIQUE,
  country TEXT DEFAULT 'US',
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE products (
  id INTEGER PRIMARY KEY,
  sku TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  price REAL NOT NULL,
  stock INTEGER NOT NULL DEFAULT 0,
  photo BLOB
);

CREATE TABLE orders (
  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  placed_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'new',
  note TEXT
);
CREATE INDEX orders_customer ON orders(customer_id);
CREATE INDEX orders_status_placed ON orders(status, placed_at);

CREATE TABLE order_items (
  order_id INTEGER NOT NULL REFERENCES orders(id),
  product_id INTEGER NOT NULL REFERENCES products(id),
  quantity INTEGER NOT NULL DEFAULT 1,
  unit_price REAL NOT NULL,
  PRIMARY KEY (order_id, product_id)
);

CREATE TABLE notes (body TEXT);

CREATE VIEW order_totals AS
  SELECT o.id AS order_id, c.name AS customer, SUM(i.quantity * i.unit_price) AS total
  FROM orders o JOIN customers c ON c.id = o.customer_id JOIN order_items i ON i.order_id = o.id
  GROUP BY o.id;

CREATE TRIGGER products_stock_check BEFORE UPDATE OF stock ON products
  WHEN NEW.stock < 0
  BEGIN SELECT RAISE(ABORT, 'stock can''t go below zero'); END;

INSERT INTO customers (name, email, country, created_at) VALUES
  ('Ada Lovelace', 'ada@example.com', 'UK', '2026-01-04 09:12:00'),
  ('Grace Hopper', 'grace@example.com', 'US', '2026-01-09 14:30:00'),
  ('Alan Turing', 'alan@example.com', 'UK', '2026-02-11 08:05:00'),
  ('Margaret Hamilton', 'margaret@example.com', 'US', '2026-02-20 17:45:00'),
  ('Linus Torvalds', NULL, 'FI', '2026-03-02 11:00:00'),
  ('Katherine Johnson', 'katherine@example.com', 'US', '2026-03-15 10:20:00');

INSERT INTO products (id, sku, title, price, stock, photo) VALUES
  (1, 'KB-01', 'Mechanical Keyboard', 129.0, 14, X'89504E470D0A1A0A'),
  (2, 'MS-02', 'Trackpad', 79.5, 30, NULL),
  (3, 'MN-27', '27-inch Display', 499.99, 6, NULL),
  (4, 'CB-10', 'USB-C Cable', 12.25, 250, NULL);

INSERT INTO orders (id, customer_id, placed_at, status, note) VALUES
  (1, 1, '2026-03-01 10:00:00', 'shipped', NULL),
  (2, 2, '2026-03-03 12:15:00', 'shipped', 'Gift wrap'),
  (3, 1, '2026-03-10 09:40:00', 'new', NULL),
  (4, 4, '2026-03-12 16:05:00', 'cancelled', 'Changed mind'),
  (5, 6, '2026-03-18 08:30:00', 'new', NULL);

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
  (1, 1, 1, 129.0), (1, 4, 2, 12.25), (2, 3, 1, 499.99), (3, 2, 1, 79.5),
  (4, 4, 3, 12.25), (5, 1, 1, 129.0), (5, 2, 1, 79.5);

INSERT INTO notes (body) VALUES ('No primary key here: rows are found by rowid.');

-- S-069: a WITHOUT ROWID table is edited by its primary key; 'draft' is TEXT
-- stored in an INTEGER column, which Content shows as stored, with a tooltip.
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT,
  revision INTEGER NOT NULL DEFAULT 1
) WITHOUT ROWID;
INSERT INTO settings (key, value, revision) VALUES ('theme', 'dark', 3), ('locale', 'en-GB', 'draft');

-- 2,500 rows, so Content has more than one page.
CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,
  at TEXT NOT NULL,
  amount REAL
);
WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 2500)
INSERT INTO events (id, kind, at, amount)
SELECT x, CASE x % 3 WHEN 0 THEN 'click' WHEN 1 THEN 'view' ELSE 'buy' END,
       datetime('2026-01-01', '+' || x || ' minutes'), CASE WHEN x % 3 = 2 THEN x * 1.5 END
FROM n;
