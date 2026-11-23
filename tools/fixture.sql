-- Quarry test fixture. Loaded only into the private test server (tools/testdb.sh).
-- Covers what the stories exercise: FKs, a view, a trigger, a procedure,
-- TEXT/BLOB/JSON/BIT/ENUM/DECIMAL/DATE columns, NULLs, and a larger table.

DROP DATABASE IF EXISTS quarry_demo;
CREATE DATABASE quarry_demo CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE quarry_demo;

CREATE TABLE customers (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(120) NOT NULL,
  email VARCHAR(190) NULL,
  country CHAR(2) NOT NULL DEFAULT 'US',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  notes TEXT NULL,
  UNIQUE KEY email (email),
  KEY country (country)
) ENGINE=InnoDB COMMENT='People who place orders';

CREATE TABLE products (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  sku VARCHAR(32) NOT NULL,
  title VARCHAR(200) NOT NULL,
  price DECIMAL(10,2) NOT NULL,
  status ENUM('draft','active','retired') NOT NULL DEFAULT 'draft',
  flags BIT(8) NOT NULL DEFAULT b'00000000',
  attributes JSON NULL,
  description TEXT NULL,
  thumbnail BLOB NULL,
  UNIQUE KEY sku (sku),
  FULLTEXT KEY title_description (title, description)
) ENGINE=InnoDB;

CREATE TABLE orders (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  customer_id INT UNSIGNED NOT NULL,
  ordered_on DATE NOT NULL,
  status ENUM('open','paid','shipped','cancelled') NOT NULL DEFAULT 'open',
  total DECIMAL(12,2) NOT NULL DEFAULT 0,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id)
    ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE order_items (
  order_id INT UNSIGNED NOT NULL,
  product_id INT UNSIGNED NOT NULL,
  quantity SMALLINT UNSIGNED NOT NULL DEFAULT 1,
  unit_price DECIMAL(10,2) NOT NULL,
  PRIMARY KEY (order_id, product_id),
  CONSTRAINT fk_items_order FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE,
  CONSTRAINT fk_items_product FOREIGN KEY (product_id) REFERENCES products (id)
) ENGINE=InnoDB;

CREATE TABLE events (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  happened_at DATETIME(3) NOT NULL,
  kind VARCHAR(32) NOT NULL,
  payload VARCHAR(255) NULL,
  KEY happened_at (happened_at)
) ENGINE=InnoDB COMMENT='Large table for paging and performance checks';

INSERT INTO customers (name, email, country, created_at, notes) VALUES
 ('Ada Lovelace', 'ada@example.com', 'GB', '2024-01-05 09:12:00', 'Prefers email.'),
 ('Grace Hopper', 'grace@example.com', 'US', '2024-02-11 14:30:00', NULL),
 ('Alan Turing', 'alan@example.com', 'GB', '2024-03-02 08:00:00', 'A very long note that goes on and on so the grid has to truncate it and show the full value in a tooltip when you hover the cell.'),
 ('Katherine Johnson', NULL, 'US', '2024-03-15 16:45:00', NULL),
 ('Hedy Lamarr', 'hedy@example.com', 'AT', '2024-04-20 11:00:00', NULL),
 ('Edsger Dijkstra', 'edsger@example.com', 'NL', '2024-05-01 10:10:00', 'Quote: "Simplicity is prerequisite for reliability."'),
 ('Barbara Liskov', 'barbara@example.com', 'US', '2024-06-09 13:20:00', NULL),
 ('Tim Berners-Lee', 'tim@example.com', 'GB', '2024-07-14 09:00:00', NULL),
 ('Margaret Hamilton', 'margaret@example.com', 'US', '2024-08-08 17:05:00', 'Tabs	and "quotes" and a backslash \\ in one value.'),
 ('Yukihiro Matsumoto', 'matz@example.com', 'JP', '2024-09-21 12:00:00', 'Unicode: こんにちは 🌸');

INSERT INTO products (sku, title, price, status, flags, attributes, description, thumbnail) VALUES
 ('MUG-01', 'Enamel mug', 14.50, 'active', b'00000101', '{"color":"white","volume_ml":350}', 'A mug for coffee.', UNHEX('89504E470D0A1A0A')),
 ('NB-A5', 'Dot grid notebook', 9.00, 'active', b'00000001', '{"pages":120,"size":"A5"}', 'Notebook with dot grid pages.', NULL),
 ('PEN-BLK', 'Gel pen, black', 2.25, 'active', b'00000000', NULL, NULL, NULL),
 ('LAMP-OLD', 'Desk lamp (old model)', 39.00, 'retired', b'10000000', '{"watts":40}', 'Replaced by LAMP-02.', NULL),
 ('LAMP-02', 'Desk lamp', 45.00, 'draft', b'00000011', '{"watts":8,"led":true}', NULL, UNHEX('89504E470D0A1A0A0000000D49484452000000300000003008060000005702F9870000036D4944415478DAED5A8B52134110E42304150D8A826F7CA0A5965FE647180946A23C4C100191080AA8F88012CBB2CABF6AD3B7D3C9669360C044BDADA4AAABCED9B9BBEE999EE572B1AFAFF789E8F3F3FE10DA412A49FF77625A11C2832340B6052A6BFF5C484BC20FFB1D26061C720114575E0B417F8DBC23EE91CE1D05262B7874CC211F4071E6305762788D4048F7ABAE8AB3B2229D3F0E3CAE606AD0A1104071E630B72A66A0DA91AE74A3A1EAAAB8888B74E104F0A482A7271DA60328CE1CE64A8C84A8239DEC4653F2AC982A4E12224D9233196076C8612E80E2CC99F6C4F01AEA48AEC3221AC97B55A72D12E2991AE167A780E269875200C59923413C97D72878DDE03D02119D25EF579DD51471929C1F069E9F715808A038734A9E90994C7D373A21A2CE3ABE6D449E1698F52A2EE20B678117152C8E004B0118E31A7324441D49BA118A70763A9495EA769B89819A6D42F2ACA48827A44781E50A5E9E03560230C635E63057424A4D44C84EBC77F6805D68B00E7788BCE7F92A79AB3AABCA0A8BF4ABF3C0EA05A01C8031AE49CC92752411315C13A199E03D270F61A55AF503EBC8F37EE513F256719223D1D71781B54BC07A00C6B85636218988514F84754233E15B29DBDF9E80A6D5AF5AC706B618906745573DE26F2E036FAF001B0118E39A84F09C954004AF3D67BB93AC74902E34F5FE54601D0EDF82671B91679513E263C0D655877706FD9B6BCC59F744C84EBCE67C602575A1DD59A8DF79E47D1B5C5646D6591CA9D9C627BF39E608BFBF067CB80E6C1B78CC18D7360311B213AF292BCDD940F3DEE460DBEABE021AB64EDF3EF27EB5FA661DFA79CD276FC43FDE003E8D039F0D3C668C6BCC91089E5BF6ACE47761A6D146FB6EA975FE6F661FDFFBDC0E557DFA7AC32A4F8224FBE526B0730BD835F09831AE2522CC4E3C575D580E66A1998DF69B83DFFABF18D867D5ABFE96D98655265192FE7A1BD833F078D7443087B93C475DD02CC846AD0464DB15C0AD8BCFF0DC8F7DFFF391800327FBD0C71B2640D5DF31F2DFEE00DFEF3AF09831AEA90BC950DB2C546D34E2EE513707838E4BAE9B0268090E2BFDCE4AB3EA24FEE39E038FF7AC0BCCD9968D7A0262B550AA8738EDDB686AFF90A5FE5122AE87B9B43E4EA7FE0B4D145F2953FFA53E8AD72AA97FB115C5ABC5285EEEA6FEF57A143F7044F11353343FF245F1336B343F7447F35F0D7A9F3FFCFC026634FB26A9C20F260000000049454E44AE426082'));

INSERT INTO orders (customer_id, ordered_on, status, total) VALUES
 (1, '2024-10-01', 'shipped', 33.00),
 (2, '2024-10-03', 'paid', 14.50),
 (3, '2024-10-04', 'open', 0),
 (1, '2024-10-10', 'cancelled', 9.00),
 (6, '2024-10-12', 'paid', 54.00);

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
 (1, 1, 1, 14.50), (1, 2, 2, 9.00), (1, 3, 1, 0.50),
 (2, 1, 1, 14.50),
 (4, 2, 1, 9.00),
 (5, 2, 1, 9.00), (5, 5, 1, 45.00);

-- 100 000 rows for paging (S-005 performance check).
INSERT INTO events (happened_at, kind, payload)
SELECT TIMESTAMP('2024-01-01') + INTERVAL seq SECOND,
       ELT(1 + seq % 4, 'view', 'click', 'purchase', 'error'),
       IF(seq % 7 = 0, NULL, CONCAT('event #', seq))
FROM seq_1_to_100000;

CREATE VIEW order_totals AS
  SELECT o.id AS order_id, c.name AS customer, o.ordered_on,
         SUM(i.quantity * i.unit_price) AS items_total
  FROM orders o
  JOIN customers c ON c.id = o.customer_id
  LEFT JOIN order_items i ON i.order_id = o.id
  GROUP BY o.id, c.name, o.ordered_on;

DELIMITER //
CREATE TRIGGER orders_before_update BEFORE UPDATE ON orders FOR EACH ROW
BEGIN
  IF NEW.status = 'cancelled' THEN SET NEW.total = 0; END IF;
END//

CREATE PROCEDURE customer_orders(IN p_customer INT UNSIGNED)
BEGIN
  SELECT * FROM orders WHERE customer_id = p_customer ORDER BY ordered_on;
END//

CREATE FUNCTION order_count(p_customer INT UNSIGNED) RETURNS INT DETERMINISTIC READS SQL DATA
BEGIN
  RETURN (SELECT COUNT(*) FROM orders WHERE customer_id = p_customer);
END//
DELIMITER ;

-- A second, latin1 database for the encoding story (S-056) and the database switcher.
DROP DATABASE IF EXISTS quarry_legacy;
CREATE DATABASE quarry_legacy CHARACTER SET latin1 COLLATE latin1_swedish_ci;
-- It also holds the problems the Health Check looks for: MyISAM and Aria
-- engines, utf8mb3 columns, a table with no primary key, and an
-- auto-increment column near the end of its range.
CREATE TABLE quarry_legacy.notes (id INT PRIMARY KEY, body VARCHAR(100), title VARCHAR(60) CHARACTER SET utf8mb3)
  ENGINE=MyISAM CHARACTER SET latin1;
INSERT INTO quarry_legacy.notes (id, body) VALUES (1, 'Café crème'), (2, 'Smörgåsbord');
CREATE TABLE quarry_legacy.visits (visited_at DATETIME, page VARCHAR(200)) ENGINE=Aria CHARACTER SET utf8mb3;
INSERT INTO quarry_legacy.visits VALUES ('2026-01-02 10:00:00', '/home');
CREATE TABLE quarry_legacy.counters (id TINYINT UNSIGNED AUTO_INCREMENT PRIMARY KEY, label VARCHAR(20))
  CHARACTER SET latin1 AUTO_INCREMENT=240;
INSERT INTO quarry_legacy.counters (label) VALUES ('near the end');

-- An empty database for empty-state snapshots.
DROP DATABASE IF EXISTS quarry_empty;
CREATE DATABASE quarry_empty;
