-- Aggregates over expressions of columnar fields, such as SUM(price - discount),
-- run on the DataFusion backend: Tantivy only aggregates single fields.
-- https://github.com/paradedb/paradedb/issues/7075

CREATE EXTENSION IF NOT EXISTS pg_search;
SET max_parallel_workers_per_gather = 0;
SET paradedb.enable_aggregate_custom_scan TO on;

CREATE TABLE expr_invoices (
    id SERIAL PRIMARY KEY,
    customer_id INTEGER,
    description TEXT,
    status TEXT,
    price FLOAT8,
    discount FLOAT8,
    qty INTEGER,
    amount NUMERIC(10, 2),
    fee NUMERIC(8, 3)
);

INSERT INTO expr_invoices (customer_id, description, status, price, discount, qty, amount, fee) VALUES
    (1, 'red widget', 'paid', 100.0, 10.0, 2, 10.50, 0.125),
    (1, 'blue widget', 'returned', 50.0, 5.0, 1, 20.00, 1.000),
    (2, 'green widget', 'paid', 75.0, NULL, 3, NULL, 0.500),
    (2, 'red gadget', 'returned', 20.0, 2.5, 4, 4.25, NULL),
    (3, 'blue gadget', 'pending', 60.0, 0.0, NULL, 99.99, 2.250);

CREATE INDEX expr_invoices_idx ON expr_invoices
USING paradedb (id, customer_id, description, (status::pdb.literal), price, discount, qty, amount, fee);

CREATE TABLE expr_customers (
    id INTEGER PRIMARY KEY,
    region TEXT
);

INSERT INTO expr_customers (id, region) VALUES (1, 'east'), (2, 'west'), (3, 'east');

CREATE INDEX expr_customers_idx ON expr_customers
USING paradedb (id, (region::pdb.literal));

-- The query from the issue, with and without a FILTER.
EXPLAIN (COSTS OFF, VERBOSE)
SELECT SUM(price - discount) FILTER (WHERE status = 'returned'),
       SUM(price - discount)
FROM expr_invoices
WHERE description ||| 'widget gadget';

SELECT SUM(price - discount) FILTER (WHERE status = 'returned'),
       SUM(price - discount)
FROM expr_invoices
WHERE description ||| 'widget gadget';

-- Operators, aggregates, and NULL propagation, grouped.
SELECT status,
       AVG(price * qty),
       MIN(price / 2),
       MAX(qty % 3),
       COUNT(price - discount),
       SUM(COALESCE(discount, 0) + 1),
       SUM(qty * 2),
       SUM(-qty)
FROM expr_invoices
WHERE description ||| 'widget gadget'
GROUP BY status
ORDER BY status;

-- HAVING over an expression aggregate.
SELECT status, SUM(price - discount)
FROM expr_invoices
WHERE description ||| 'widget gadget'
GROUP BY status
HAVING SUM(price - discount) > 60
ORDER BY status;

-- An expression aggregate that only HAVING uses still runs on DataFusion.
EXPLAIN (COSTS OFF)
SELECT status
FROM expr_invoices
WHERE description ||| 'widget gadget'
GROUP BY status
HAVING SUM(price - discount) > 60;

SELECT status
FROM expr_invoices
WHERE description ||| 'widget gadget'
GROUP BY status
HAVING SUM(price - discount) > 60
ORDER BY status;

-- An expression over columns of a joined table.
EXPLAIN (COSTS OFF)
SELECT c.region, SUM(i.price - i.discount)
FROM expr_invoices i JOIN expr_customers c ON i.customer_id = c.id
WHERE i.description ||| 'widget gadget'
GROUP BY c.region;

SELECT c.region, SUM(i.price - i.discount), SUM(i.qty * c.id)
FROM expr_invoices i JOIN expr_customers c ON i.customer_id = c.id
WHERE i.description ||| 'widget gadget'
GROUP BY c.region
ORDER BY c.region;

-- DISTINCT counts the values of the expression, not of its columns: qty - customer_id
-- is 1, 0, 1, 2 where the (qty, customer_id) pairs are all different.
SELECT status, COUNT(DISTINCT qty - customer_id), SUM(DISTINCT qty * 2)
FROM expr_invoices
WHERE description ||| 'widget gadget'
GROUP BY status
ORDER BY status;

-- ORDER BY inside the aggregate, on a column.
SELECT status, array_agg(qty + 1 ORDER BY id)
FROM expr_invoices
WHERE description ||| 'widget gadget'
GROUP BY status
ORDER BY status;

\echo 'Same results from PostgreSQL'
SET paradedb.enable_aggregate_custom_scan TO off;

SELECT SUM(price - discount) FILTER (WHERE status = 'returned'),
       SUM(price - discount)
FROM expr_invoices
WHERE description ||| 'widget gadget';

SELECT status,
       AVG(price * qty),
       MIN(price / 2),
       MAX(qty % 3),
       COUNT(price - discount),
       SUM(COALESCE(discount, 0) + 1),
       SUM(qty * 2),
       SUM(-qty)
FROM expr_invoices
WHERE description ||| 'widget gadget'
GROUP BY status
ORDER BY status;

SELECT status, SUM(price - discount)
FROM expr_invoices
WHERE description ||| 'widget gadget'
GROUP BY status
HAVING SUM(price - discount) > 60
ORDER BY status;

SELECT status
FROM expr_invoices
WHERE description ||| 'widget gadget'
GROUP BY status
HAVING SUM(price - discount) > 60
ORDER BY status;

SELECT c.region, SUM(i.price - i.discount), SUM(i.qty * c.id)
FROM expr_invoices i JOIN expr_customers c ON i.customer_id = c.id
WHERE i.description ||| 'widget gadget'
GROUP BY c.region
ORDER BY c.region;

SELECT status, COUNT(DISTINCT qty - customer_id), SUM(DISTINCT qty * 2)
FROM expr_invoices
WHERE description ||| 'widget gadget'
GROUP BY status
ORDER BY status;

SELECT status, array_agg(qty + 1 ORDER BY id)
FROM expr_invoices
WHERE description ||| 'widget gadget'
GROUP BY status
ORDER BY status;

SET paradedb.enable_aggregate_custom_scan TO on;

-- A bare column still runs on Tantivy.
EXPLAIN (COSTS OFF)
SELECT SUM(price)
FROM expr_invoices
WHERE description ||| 'widget gadget';

-- Declines: a column that is not columnar, NUMERIC expressions, a volatile function,
-- a subquery, ORDER BY on the expression, extra arguments, and DISTINCT over a float expression.
EXPLAIN (COSTS OFF)
SELECT AVG(LENGTH(description))
FROM expr_invoices
WHERE description ||| 'widget gadget';

EXPLAIN (COSTS OFF)
SELECT SUM(amount - fee)
FROM expr_invoices
WHERE description ||| 'widget gadget';

EXPLAIN (COSTS OFF)
SELECT SUM(price * random())
FROM expr_invoices
WHERE description ||| 'widget gadget';

EXPLAIN (COSTS OFF)
SELECT SUM(price + (SELECT c.id FROM expr_customers c WHERE c.id = expr_invoices.customer_id))
FROM expr_invoices
WHERE description ||| 'widget gadget';

EXPLAIN (COSTS OFF)
SELECT array_agg(qty + 1 ORDER BY qty + 1)
FROM expr_invoices
WHERE description ||| 'widget gadget';

EXPLAIN (COSTS OFF)
SELECT string_agg(lower(status), ',')
FROM expr_invoices
WHERE description ||| 'widget gadget';

EXPLAIN (COSTS OFF)
SELECT COUNT(DISTINCT price - discount)
FROM expr_invoices
WHERE description ||| 'widget gadget';

-- Expressions other than float8 arithmetic are evaluated by PostgreSQL, so they
-- raise its errors and keep its types.
CREATE TABLE expr_edge (
    id SERIAL PRIMARY KEY,
    big_a BIGINT,
    big_b BIGINT,
    price FLOAT8,
    discount FLOAT8,
    shipped DATE,
    ordered DATE
);

INSERT INTO expr_edge (big_a, big_b, price, discount, shipped, ordered) VALUES
    (9223372036854775807, 2, 10.0, 0.0, '2024-01-05', '2024-01-01'),
    (1, 1, 20.0, 4.0, '2024-01-03', '2024-01-02');

CREATE INDEX expr_edge_idx ON expr_edge
USING paradedb (id, big_a, big_b, price, discount, shipped, ordered);

SELECT SUM(big_a * big_b) FROM expr_edge WHERE id @@@ pdb.all();
SELECT SUM(price / discount) FROM expr_edge WHERE id @@@ pdb.all();

-- float8 arithmetic runs natively, so an overflow gives Infinity where PostgreSQL errors.
-- Unary minus is evaluated by PostgreSQL.
EXPLAIN (COSTS OFF)
SELECT SUM(-price), MAX(price * 1e308) FROM expr_edge WHERE id @@@ pdb.all();
SELECT SUM(-price), MAX(price * 1e308) FROM expr_edge WHERE id @@@ pdb.all();

EXPLAIN (COSTS OFF)
SELECT MAX(shipped - ordered) FROM expr_edge WHERE id @@@ pdb.all();
SELECT MAX(shipped - ordered) FROM expr_edge WHERE id @@@ pdb.all();

-- A date result has no supported output type, so it falls back.
EXPLAIN (COSTS OFF)
SELECT MAX(shipped + 1) FROM expr_edge WHERE id @@@ pdb.all();

SET paradedb.enable_aggregate_custom_scan TO off;
SELECT SUM(big_a * big_b) FROM expr_edge WHERE id @@@ pdb.all();
SELECT SUM(price / discount) FROM expr_edge WHERE id @@@ pdb.all();
SELECT SUM(-price), MAX(price * 1e308) FROM expr_edge WHERE id @@@ pdb.all();
SELECT MAX(shipped - ordered) FROM expr_edge WHERE id @@@ pdb.all();
SET paradedb.enable_aggregate_custom_scan TO on;

DROP TABLE expr_edge;

-- MPP: the expression is evaluated in each producer worker.
SET max_parallel_workers_per_gather TO 3;
SET max_parallel_workers TO 8;
SET min_parallel_table_scan_size TO 0;
SET parallel_setup_cost TO 0;
SET parallel_tuple_cost TO 0;
SET paradedb.global_mutable_segment_rows = 0;

CREATE TABLE expr_lines (
    id SERIAL PRIMARY KEY,
    note TEXT,
    bucket INTEGER,
    price FLOAT8,
    discount FLOAT8
);

CREATE INDEX expr_lines_idx ON expr_lines
USING paradedb (id, note, bucket, price, discount);

INSERT INTO expr_lines (note, bucket, price, discount)
SELECT 'line ' || g, g % 4, g * 1.5, g % 7
FROM generate_series(1, 500) AS g;

INSERT INTO expr_lines (note, bucket, price, discount)
SELECT 'line ' || g, g % 4, g * 1.5, g % 7
FROM generate_series(501, 1000) AS g;

EXPLAIN (COSTS OFF)
SELECT bucket, SUM(price - discount)
FROM expr_lines
WHERE note ||| 'line'
GROUP BY bucket;

SELECT bucket, SUM(price - discount)
FROM expr_lines
WHERE note ||| 'line'
GROUP BY bucket
ORDER BY bucket;

SET paradedb.enable_aggregate_custom_scan TO off;
SELECT bucket, SUM(price - discount)
FROM expr_lines
WHERE note ||| 'line'
GROUP BY bucket
ORDER BY bucket;

DROP TABLE expr_lines;
DROP TABLE expr_customers;
DROP TABLE expr_invoices;

RESET paradedb.global_mutable_segment_rows;
RESET parallel_tuple_cost;
RESET parallel_setup_cost;
RESET min_parallel_table_scan_size;
RESET max_parallel_workers;
RESET max_parallel_workers_per_gather;
RESET paradedb.enable_aggregate_custom_scan;
