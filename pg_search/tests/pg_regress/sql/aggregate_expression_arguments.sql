-- Aggregates over an expression, such as SUM(price - discount), on the DataFusion backend.
-- https://github.com/paradedb/paradedb/issues/7075
-- Each query is compared with Postgres; scan_used() shows which path planned it.
CREATE EXTENSION IF NOT EXISTS pg_search;
SET max_parallel_workers_per_gather = 0;
SET paradedb.planner_warnings = 'off';

CREATE FUNCTION scan_used(query text) RETURNS text AS $$
DECLARE
    line text;
BEGIN
    FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || query LOOP
        IF line LIKE '%ParadeDB Aggregate Scan%' THEN
            RETURN 'Aggregate Scan';
        END IF;
    END LOOP;
    RETURN 'PostgreSQL';
END
$$ LANGUAGE plpgsql;

CREATE TABLE inv (
    id int PRIMARY KEY,
    description text,
    status text,
    grp int,
    price float8,
    discount float8,
    qty int,
    amt numeric(10,2),
    dsc numeric(10,2),
    shipped date,
    ordered date
);
INSERT INTO inv VALUES
    (1, 'red widget',   'returned', 1, 100, 10,   2, 10.50, 1.25, '2024-01-05', '2024-01-01'),
    (2, 'blue widget',  'paid',     1, 200, 50,   3, 20.25, 2.00, '2024-01-03', '2024-01-02'),
    (3, 'green widget', 'returned', 2,  50,  5,   NULL, NULL, 0.50, '2024-01-09', '2024-01-04'),
    (4, 'red gadget',   'paid',     2, NULL, 1,   1, 7.00, NULL, '2024-01-07', '2024-01-06'),
    (5, 'blue gadget',  'paid',     2,  30,  3,   4, 3.33, 0.33, '2024-01-08', '2024-01-07');
CREATE INDEX inv_idx ON inv USING paradedb (id, description, (status::pdb.literal), grp, price, discount, qty, amt, dsc, shipped, ordered);

CREATE TABLE ord (id int PRIMARY KEY, inv_id int, factor float8);
INSERT INTO ord VALUES (1, 1, 0.5), (2, 2, 0.25), (3, 3, 2), (4, 4, 1), (5, 5, 3);
CREATE INDEX ord_idx ON ord USING paradedb (id, inv_id, factor);

-- The query of the feature request.
SELECT scan_used($$SELECT SUM(price - discount) FILTER (WHERE status = 'returned'), SUM(price - discount) FROM inv WHERE description ||| 'widget gadget'$$);
SELECT SUM(price - discount) FILTER (WHERE status = 'returned'), SUM(price - discount) FROM inv WHERE description ||| 'widget gadget';
SET paradedb.enable_aggregate_custom_scan = off;
SELECT SUM(price - discount) FILTER (WHERE status = 'returned'), SUM(price - discount) FROM inv WHERE description ||| 'widget gadget';
RESET paradedb.enable_aggregate_custom_scan;

-- The plan shows the expression.
EXPLAIN (COSTS OFF) SELECT SUM(price - discount) FROM inv WHERE description ||| 'widget gadget';

-- float8 and integer expressions, with NULL propagation.
SELECT scan_used($$SELECT SUM(price * 2 + discount) FROM inv WHERE id @@@ pdb.all()$$);
SELECT SUM(price * 2 + discount), MIN(price - discount), MAX(price - discount), COUNT(price - discount), AVG(price - discount) FROM inv WHERE id @@@ pdb.all();
SELECT SUM(qty * 2), SUM(qty + qty), MAX(qty - 10), COUNT(qty * 2), SUM(-qty) FROM inv WHERE id @@@ pdb.all();
SELECT SUM(price / 2), SUM(COALESCE(price, 0) - discount), SUM(qty::float8), MAX(qty % 3) FROM inv WHERE id @@@ pdb.all();
SET paradedb.enable_aggregate_custom_scan = off;
SELECT SUM(price * 2 + discount), MIN(price - discount), MAX(price - discount), COUNT(price - discount), AVG(price - discount) FROM inv WHERE id @@@ pdb.all();
SELECT SUM(qty * 2), SUM(qty + qty), MAX(qty - 10), COUNT(qty * 2), SUM(-qty) FROM inv WHERE id @@@ pdb.all();
SELECT SUM(price / 2), SUM(COALESCE(price, 0) - discount), SUM(qty::float8), MAX(qty % 3) FROM inv WHERE id @@@ pdb.all();
RESET paradedb.enable_aggregate_custom_scan;

-- No rows, and only NULL inputs.
SELECT SUM(price - discount), COUNT(price - discount) FROM inv WHERE id @@@ pdb.all() AND id > 100;
SELECT SUM(price * discount), COUNT(price * discount) FROM inv WHERE id @@@ pdb.all() AND id = 4;

-- GROUP BY, and HAVING over an expression, including one only HAVING uses.
SELECT scan_used($$SELECT grp, SUM(price - discount) FROM inv WHERE id @@@ pdb.all() GROUP BY grp$$);
SELECT grp, SUM(price - discount), COUNT(*) FROM inv WHERE id @@@ pdb.all() GROUP BY grp ORDER BY grp;
SELECT grp, SUM(price - discount) FROM inv WHERE id @@@ pdb.all() GROUP BY grp HAVING SUM(price - discount) > 100 ORDER BY grp;
SELECT scan_used($$SELECT grp FROM inv WHERE id @@@ pdb.all() GROUP BY grp HAVING SUM(price - discount) > 100$$);
SELECT grp FROM inv WHERE id @@@ pdb.all() GROUP BY grp HAVING SUM(price - discount) > 100 ORDER BY grp;
SET paradedb.enable_aggregate_custom_scan = off;
SELECT grp, SUM(price - discount), COUNT(*) FROM inv WHERE id @@@ pdb.all() GROUP BY grp ORDER BY grp;
SELECT grp, SUM(price - discount) FROM inv WHERE id @@@ pdb.all() GROUP BY grp HAVING SUM(price - discount) > 100 ORDER BY grp;
SELECT grp FROM inv WHERE id @@@ pdb.all() GROUP BY grp HAVING SUM(price - discount) > 100 ORDER BY grp;
RESET paradedb.enable_aggregate_custom_scan;

-- Over a join.
SELECT scan_used($$SELECT SUM(i.price * o.factor) FROM inv i JOIN ord o ON o.inv_id = i.id WHERE i.id @@@ pdb.all()$$);
SELECT SUM(i.price * o.factor), SUM(i.price * o.factor) FILTER (WHERE i.status = 'returned'), SUM(i.qty * o.id) FROM inv i JOIN ord o ON o.inv_id = i.id WHERE i.id @@@ pdb.all();
SELECT i.grp, SUM(i.price * o.factor) FROM inv i JOIN ord o ON o.inv_id = i.id WHERE i.id @@@ pdb.all() GROUP BY i.grp ORDER BY i.grp;
SELECT SUM(i.price * o.factor) FROM inv i LEFT JOIN ord o ON o.inv_id = i.id AND o.id > 3 WHERE i.id @@@ pdb.all();
SET paradedb.enable_aggregate_custom_scan = off;
SELECT SUM(i.price * o.factor), SUM(i.price * o.factor) FILTER (WHERE i.status = 'returned'), SUM(i.qty * o.id) FROM inv i JOIN ord o ON o.inv_id = i.id WHERE i.id @@@ pdb.all();
SELECT i.grp, SUM(i.price * o.factor) FROM inv i JOIN ord o ON o.inv_id = i.id WHERE i.id @@@ pdb.all() GROUP BY i.grp ORDER BY i.grp;
SELECT SUM(i.price * o.factor) FROM inv i LEFT JOIN ord o ON o.inv_id = i.id AND o.id > 3 WHERE i.id @@@ pdb.all();
RESET paradedb.enable_aggregate_custom_scan;

-- Without a search operator it stays on Postgres, unless the setting allows it.
SELECT scan_used($$SELECT SUM(price - discount) FROM inv$$);
SET paradedb.enable_custom_scan_without_operator = on;
SELECT scan_used($$SELECT SUM(price - discount) FROM inv$$);
RESET paradedb.enable_custom_scan_without_operator;

-- Integer overflow and float division by zero raise Postgres's errors.
SELECT SUM(qty * 1000000000) FROM inv WHERE id @@@ pdb.all();
SELECT SUM(price / 0) FROM inv WHERE id @@@ pdb.all();

-- float8 + - * run natively, so an overflow gives Infinity instead of an error.
SELECT MAX(price * 1e308) FROM inv WHERE id @@@ pdb.all();
SET paradedb.enable_aggregate_custom_scan = off;
SELECT MAX(price * 1e308) FROM inv WHERE id @@@ pdb.all();
RESET paradedb.enable_aggregate_custom_scan;

-- Everything but float8 + - * is evaluated by Postgres, so functions and integer
-- and float4 arithmetic match it.
CREATE TABLE num (id int PRIMARY KEY, grp int, f float8, g float8, i int, s smallint, b bigint, r real);
INSERT INTO num VALUES
    (1, 1, 2.5, 1, 7, 3, 9007199254740993, 1.1),
    (2, 1, 3.5, 2, -7, -3, 9007199254740995, 2.2),
    (3, 2, -2.5, -0.0, 2147483647, 32767, -5, 3.3),
    (4, 2, 'NaN', 3, 0, 0, 0, 4.4),
    (5, 3, 0.0, 4, NULL, NULL, NULL, NULL);
CREATE INDEX num_idx ON num USING paradedb (id, grp, f, g, i, s, b, r);
SELECT scan_used($$SELECT SUM(round(f)) FROM num WHERE id @@@ pdb.all()$$);
SELECT SUM(round(f)), MAX(round(f)), SUM(floor(f)), SUM(ceil(f)), SUM(abs(f)) FROM num WHERE id @@@ pdb.all() AND id = 1;
SELECT SUM(i / 2), SUM(i % 2), SUM(abs(i)), SUM(abs(s)), MAX(s * 2) FROM num WHERE id @@@ pdb.all() AND id IN (1, 2);
SELECT MIN(s + s), MAX(s + s), SUM(s + s), SUM(b + 0), MAX(b + 1), SUM(b::float8 * 2) FROM num WHERE id @@@ pdb.all() AND id IN (1, 2);
SELECT SUM(r * 2), SUM(r::float8 * 2) FROM num WHERE id @@@ pdb.all();
SELECT MIN(f + 1), MAX(f + 1), SUM(f + 1), COUNT(f + 1), MIN(g * -1), MAX(g * -1) FROM num WHERE id @@@ pdb.all();
SELECT SUM(CASE WHEN g > 1 THEN g * 2 ELSE 0 END), SUM(COALESCE(g, 0) + 1) FROM num WHERE id @@@ pdb.all();
SET paradedb.enable_aggregate_custom_scan = off;
SELECT SUM(round(f)), MAX(round(f)), SUM(floor(f)), SUM(ceil(f)), SUM(abs(f)) FROM num WHERE id @@@ pdb.all() AND id = 1;
SELECT SUM(i / 2), SUM(i % 2), SUM(abs(i)), SUM(abs(s)), MAX(s * 2) FROM num WHERE id @@@ pdb.all() AND id IN (1, 2);
SELECT MIN(s + s), MAX(s + s), SUM(s + s), SUM(b + 0), MAX(b + 1), SUM(b::float8 * 2) FROM num WHERE id @@@ pdb.all() AND id IN (1, 2);
SELECT SUM(r * 2), SUM(r::float8 * 2) FROM num WHERE id @@@ pdb.all();
SELECT MIN(f + 1), MAX(f + 1), SUM(f + 1), COUNT(f + 1), MIN(g * -1), MAX(g * -1) FROM num WHERE id @@@ pdb.all();
SELECT SUM(CASE WHEN g > 1 THEN g * 2 ELSE 0 END), SUM(COALESCE(g, 0) + 1) FROM num WHERE id @@@ pdb.all();
RESET paradedb.enable_aggregate_custom_scan;

-- PostgreSQL's own errors, not DataFusion's.
SELECT SUM(ln(f)) FROM num WHERE id @@@ pdb.all() AND id = 5;
SELECT SUM(sqrt(f)) FROM num WHERE id @@@ pdb.all() AND id = 3;
SELECT SUM(i / 0) FROM num WHERE id @@@ pdb.all() AND id = 1;
SELECT SUM(i % 0) FROM num WHERE id @@@ pdb.all() AND id = 1;
SELECT SUM(b * 1024) FROM num WHERE id @@@ pdb.all() AND id = 1;

-- An expression next to other aggregates, in larger target lists, and in a self join.
SELECT scan_used($$SELECT COUNT(DISTINCT grp), SUM(g * 2) FROM num WHERE id @@@ pdb.all()$$);
SELECT COUNT(DISTINCT grp), SUM(g * 2), SUM(2 * g), SUM(g * 2) FROM num WHERE id @@@ pdb.all();
SELECT grp, SUM(g * 2) * 2, COALESCE(SUM(g * 2), 0), SUM(g * 2) / COUNT(*) FROM num WHERE id @@@ pdb.all() GROUP BY grp ORDER BY grp;
SELECT grp, SUM(g * 2) AS t FROM num WHERE id @@@ pdb.all() GROUP BY grp ORDER BY t DESC, grp LIMIT 2;
SELECT DISTINCT SUM(g * 2) FROM num WHERE id @@@ pdb.all() GROUP BY grp ORDER BY 1;
SELECT SUM(a.g * c.g) FROM num a JOIN num c ON c.grp = a.grp WHERE a.id @@@ pdb.all();
SELECT * FROM (SELECT SUM(g * 2) AS t FROM num WHERE id @@@ pdb.all()) s, ord o WHERE o.id = 1;
SET paradedb.enable_aggregate_custom_scan = off;
SELECT COUNT(DISTINCT grp), SUM(g * 2), SUM(2 * g), SUM(g * 2) FROM num WHERE id @@@ pdb.all();
SELECT grp, SUM(g * 2) * 2, COALESCE(SUM(g * 2), 0), SUM(g * 2) / COUNT(*) FROM num WHERE id @@@ pdb.all() GROUP BY grp ORDER BY grp;
SELECT grp, SUM(g * 2) AS t FROM num WHERE id @@@ pdb.all() GROUP BY grp ORDER BY t DESC, grp LIMIT 2;
SELECT DISTINCT SUM(g * 2) FROM num WHERE id @@@ pdb.all() GROUP BY grp ORDER BY 1;
SELECT SUM(a.g * c.g) FROM num a JOIN num c ON c.grp = a.grp WHERE a.id @@@ pdb.all();
SELECT * FROM (SELECT SUM(g * 2) AS t FROM num WHERE id @@@ pdb.all()) s, ord o WHERE o.id = 1;
RESET paradedb.enable_aggregate_custom_scan;

-- A column that is not indexed, and an aggregate neither backend can run.
CREATE TABLE part (id int PRIMARY KEY, a float8, b float8);
INSERT INTO part VALUES (1, 1, 2);
CREATE INDEX part_idx ON part USING paradedb (id, a);
SELECT scan_used($$SELECT SUM(a * b) FROM part WHERE id @@@ pdb.all()$$);
SELECT SUM(a * b) FROM part WHERE id @@@ pdb.all();
DROP TABLE part;
SELECT scan_used($$SELECT SUM(g * 2), AVG(i * 2) FROM num WHERE id @@@ pdb.all()$$);

-- An expression over a NUMERIC column, even cast to a float, stays on Postgres.
CREATE TABLE dec (id int PRIMARY KEY, grp int, a numeric(10,2), b numeric(10,3), q int);
INSERT INTO dec VALUES (1, 1, 10.50, 1.125, 2), (2, 1, 20.25, 2.500, 3), (3, 2, NULL, 3.000, 1);
CREATE INDEX dec_idx ON dec USING paradedb (id, grp, a, b, q);
SELECT scan_used($$SELECT SUM(a - b) FROM dec WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT SUM(a * 2) FROM dec WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT SUM(a::float8 * 2) FROM dec WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT SUM(q * a) FROM dec WHERE id @@@ pdb.all()$$);
SELECT SUM(a - b), SUM(a * b), AVG(a - b), SUM(a::float8 * 2) FROM dec WHERE id @@@ pdb.all();
-- A plain NUMERIC column next to a supported expression still takes the scan.
SELECT scan_used($$SELECT SUM(a), SUM(q * 2) FROM dec WHERE id @@@ pdb.all()$$);
SELECT SUM(a), SUM(q * 2) FROM dec WHERE id @@@ pdb.all();

-- float4 results, STDDEV and VARIANCE, booleans and dates.
CREATE TABLE misc (id int PRIMARY KEY, i int, f4 real, g4 real, f8 float8, bo boolean, d date, d2 date, ts timestamp);
INSERT INTO misc VALUES
    (1, 2, 1.1, 2.2, 2.5, true, '2024-01-05', '2024-01-01', '2024-01-01 10:00'),
    (2, 5, 2.2, 3.3, 3.5, false, '2024-01-09', '2024-01-02', '2024-01-02 10:30'),
    (3, -3, NULL, 1.0, -1.5, NULL, NULL, '2024-01-03', '2024-01-03 00:00'),
    (4, 7, 4.4, 0.5, 6, true, '2024-02-01', '2024-01-04', NULL);
CREATE INDEX misc_idx ON misc USING paradedb (id, i, f4, g4, f8, bo, d, d2, ts);
SELECT scan_used($$SELECT SUM(f4 * g4), STDDEV(f8 * 2), BOOL_AND(i > 1), MAX(d - d2) FROM misc WHERE id @@@ pdb.all()$$);
SELECT SUM(f4 * g4), MIN(f4 * g4), MAX(f4 + g4), AVG(f4 * g4) FROM misc WHERE id @@@ pdb.all();
SELECT STDDEV(f8 * 2), STDDEV_POP(f8 + 1), VARIANCE(f8 - 1), VAR_POP(f4 * g4) FROM misc WHERE id @@@ pdb.all();
SELECT BOOL_AND(i > 1), BOOL_OR(i > 6), COUNT(i > 1), SUM(CASE WHEN bo THEN 1 ELSE 0 END) FROM misc WHERE id @@@ pdb.all();
SELECT MAX(d - d2), SUM(d - d2), SUM(CASE WHEN ts > '2024-01-02' THEN 1 ELSE 0 END) FROM misc WHERE id @@@ pdb.all();
SET paradedb.enable_aggregate_custom_scan = off;
SELECT SUM(f4 * g4), MIN(f4 * g4), MAX(f4 + g4), AVG(f4 * g4) FROM misc WHERE id @@@ pdb.all();
SELECT STDDEV(f8 * 2), STDDEV_POP(f8 + 1), VARIANCE(f8 - 1), VAR_POP(f4 * g4) FROM misc WHERE id @@@ pdb.all();
SELECT BOOL_AND(i > 1), BOOL_OR(i > 6), COUNT(i > 1), SUM(CASE WHEN bo THEN 1 ELSE 0 END) FROM misc WHERE id @@@ pdb.all();
SELECT MAX(d - d2), SUM(d - d2), SUM(CASE WHEN ts > '2024-01-02' THEN 1 ELSE 0 END) FROM misc WHERE id @@@ pdb.all();
RESET paradedb.enable_aggregate_custom_scan;
-- AVG, STDDEV and VARIANCE of an integer are computed as a float, like a plain column.
SELECT scan_used($$SELECT AVG(i * 2), STDDEV(i * 2), VARIANCE(i + 1) FROM misc WHERE id @@@ pdb.all()$$);
SELECT AVG(i * 2), STDDEV(i * 2), VARIANCE(i + 1), STDDEV_POP(i * 2), VAR_POP(i + 1) FROM misc WHERE id @@@ pdb.all();
-- A date result stays on Postgres.
SELECT scan_used($$SELECT MAX(d + 1) FROM misc WHERE id @@@ pdb.all()$$);

-- A columnar text column, with NULLs and multibyte text.
CREATE TABLE tx (id int PRIMARY KEY, grp int, a text, b varchar(20), q int);
INSERT INTO tx VALUES (1, 1, 'abc', 'xy', 2), (2, 1, 'héllo', NULL, 3), (3, 2, NULL, 'qrs', 1), (4, 2, '世界', 'x', 5);
CREATE INDEX tx_idx ON tx USING paradedb (id, grp, (a::pdb.literal), (b::pdb.literal), q);
SELECT scan_used($$SELECT SUM(length(a)), MAX(length(upper(b))) FROM tx WHERE id @@@ pdb.all()$$);
SELECT SUM(length(a)), MAX(length(upper(b))), BOOL_OR(a = 'abc'), SUM(length(a) * q), COUNT(length(b)) FROM tx WHERE id @@@ pdb.all();
SELECT grp, SUM(length(a) + length(b)) FROM tx WHERE id @@@ pdb.all() GROUP BY grp ORDER BY grp;
SET paradedb.enable_aggregate_custom_scan = off;
SELECT SUM(length(a)), MAX(length(upper(b))), BOOL_OR(a = 'abc'), SUM(length(a) * q), COUNT(length(b)) FROM tx WHERE id @@@ pdb.all();
SELECT grp, SUM(length(a) + length(b)) FROM tx WHERE id @@@ pdb.all() GROUP BY grp ORDER BY grp;
RESET paradedb.enable_aggregate_custom_scan;
DROP TABLE tx;

-- DISTINCT, ordered ARRAY_AGG and STRING_AGG, and text MIN and MAX, on a single table
-- and over a join.
CREATE TABLE dg (id int PRIMARY KEY, k int, q int, f float8, t text);
CREATE TABLE dgk (id int PRIMARY KEY, k int);
INSERT INTO dg VALUES
    (1, 1, 3, 0.0, 'ab'), (2, 1, 4, '-0', NULL), (3, 2, 3, 'NaN', 'héllo'),
    (4, 2, NULL, 2.5, ''), (5, 1, 7, 2.5, 'ab'), (6, 2, 4, 1.0, 'zz');
INSERT INTO dgk VALUES (1, 1), (2, 2), (3, 2);
CREATE INDEX dg_idx ON dg USING paradedb (id, k, q, f, (t::pdb.literal));
CREATE INDEX dgk_idx ON dgk USING paradedb (id, k);
SELECT scan_used($$SELECT COUNT(DISTINCT q * 2), SUM(DISTINCT q % 3) FROM dg WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT array_agg(q * 2 ORDER BY id), string_agg(upper(t), ',' ORDER BY id) FROM dg WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT MIN(upper(d.t)), MAX(d.t || 'z') FROM dg d JOIN dgk g ON d.k = g.k WHERE d.id @@@ pdb.all()$$);
SELECT COUNT(DISTINCT q * 2), SUM(DISTINCT q % 3), COUNT(DISTINCT q > 3), COUNT(DISTINCT length(t)) FROM dg WHERE id @@@ pdb.all();
SELECT array_agg(q * 2 ORDER BY id), array_agg(upper(t) ORDER BY id DESC), string_agg(upper(t), ',' ORDER BY id), MIN(upper(t)), MAX(t || 'z') FROM dg WHERE id @@@ pdb.all();
SELECT d.k, COUNT(DISTINCT d.q * 2), array_agg(d.q + g.id ORDER BY d.id, g.id), string_agg(upper(d.t), '|' ORDER BY d.id, g.id), MAX(upper(d.t))
FROM dg d JOIN dgk g ON d.k = g.k WHERE d.id @@@ pdb.all() GROUP BY d.k ORDER BY d.k;
SET paradedb.enable_aggregate_custom_scan = off;
SELECT COUNT(DISTINCT q * 2), SUM(DISTINCT q % 3), COUNT(DISTINCT q > 3), COUNT(DISTINCT length(t)) FROM dg WHERE id @@@ pdb.all();
SELECT array_agg(q * 2 ORDER BY id), array_agg(upper(t) ORDER BY id DESC), string_agg(upper(t), ',' ORDER BY id), MIN(upper(t)), MAX(t || 'z') FROM dg WHERE id @@@ pdb.all();
SELECT d.k, COUNT(DISTINCT d.q * 2), array_agg(d.q + g.id ORDER BY d.id, g.id), string_agg(upper(d.t), '|' ORDER BY d.id, g.id), MAX(upper(d.t))
FROM dg d JOIN dgk g ON d.k = g.k WHERE d.id @@@ pdb.all() GROUP BY d.k ORDER BY d.k;
RESET paradedb.enable_aggregate_custom_scan;
-- DISTINCT over a float stays on Postgres: DataFusion counts -0.0 and 0.0 apart.
SELECT scan_used($$SELECT COUNT(DISTINCT f * 0) FROM dg WHERE id @@@ pdb.all()$$);
SELECT COUNT(DISTINCT f * 0) FROM dg WHERE id @@@ pdb.all();
-- STDDEV(DISTINCT) stays on Postgres. VARIANCE(DISTINCT) is pushed down and, of an
-- integer, matches to 15 digits.
SELECT scan_used($$SELECT STDDEV(DISTINCT q * 2) FROM dg WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT STDDEV_POP(DISTINCT q + 1) FROM dg WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT VARIANCE(DISTINCT q * 2) FROM dg WHERE id @@@ pdb.all()$$);
SELECT STDDEV(DISTINCT q * 2), STDDEV_POP(DISTINCT q + 1) FROM dg WHERE id @@@ pdb.all();
SELECT VARIANCE(DISTINCT q * 2), VAR_POP(DISTINCT q * 2) FROM dg WHERE id @@@ pdb.all();
SET paradedb.enable_aggregate_custom_scan = off;
SELECT VARIANCE(DISTINCT q * 2), VAR_POP(DISTINCT q * 2) FROM dg WHERE id @@@ pdb.all();
RESET paradedb.enable_aggregate_custom_scan;
-- Stays on Postgres: DISTINCT on ARRAY_AGG and STRING_AGG, other ORDER BYs, and a
-- collation that cannot be ordered natively.
CREATE COLLATION IF NOT EXISTS agg_expr_ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false);
SELECT scan_used($$SELECT array_agg(DISTINCT q * 2) FROM dg WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT string_agg(DISTINCT upper(t), ',') FROM dg WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT SUM(q * 2 ORDER BY id) FROM dg WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT array_agg(q * 2 ORDER BY q * 2) FROM dg WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT MAX(upper(t) COLLATE agg_expr_ci) FROM dg WHERE id @@@ pdb.all()$$);
DROP TABLE dg, dgk;
DROP COLLATION agg_expr_ci;

-- Refused: volatile, subquery, parameter, score.
SELECT scan_used($$SELECT SUM(price * random()) FROM inv WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT SUM(price + (SELECT 1)) FROM inv WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT SUM(price * pdb.score(id)) FROM inv WHERE description ||| 'widget'$$);
SELECT SUM(price + (SELECT 1)) FROM inv WHERE id @@@ pdb.all();
-- DISTINCT over a float expression, and a window.
SELECT scan_used($$SELECT SUM(DISTINCT price - discount) FROM inv WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT SUM(price - discount) OVER () FROM inv WHERE id @@@ pdb.all() ORDER BY id LIMIT 2$$);
-- A JSON sub-field inside an expression. A bare cast of one is a field of its own.
CREATE TABLE js (id int PRIMARY KEY, m jsonb);
INSERT INTO js VALUES (1, '{"qty": 3}'), (2, '{"qty": 4}'), (3, NULL);
CREATE INDEX js_idx ON js USING paradedb (id, (m::pdb.literal));
SELECT scan_used($$SELECT SUM((m->>'qty')::int) FROM js WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT SUM((m->>'qty')::int * 2) FROM js WHERE id @@@ pdb.all()$$);
SELECT SUM((m->>'qty')::int * 2) FROM js WHERE id @@@ pdb.all();
DROP TABLE js;

-- A prepared statement's parameter is refused.
SET plan_cache_mode = force_generic_plan;
PREPARE p(float8) AS SELECT SUM(price * $1) FROM inv WHERE id @@@ pdb.all();
SELECT scan_used($$EXECUTE p(2)$$);
EXECUTE p(2);
DEALLOCATE p;
RESET plan_cache_mode;

-- A prepared statement over an expression runs the same on every execution.
PREPARE q(int) AS SELECT SUM(price - discount) FROM inv WHERE id @@@ pdb.all() AND grp = $1;
EXECUTE q(1);
EXECUTE q(2);
EXECUTE q(1);
EXECUTE q(2);
EXECUTE q(1);
EXECUTE q(2);
SET plan_cache_mode = force_generic_plan;
EXECUTE q(1);
EXECUTE q(2);
DEALLOCATE q;
RESET plan_cache_mode;

-- A refused expression keeps its earlier plan and warning.
RESET paradedb.planner_warnings;
EXPLAIN (COSTS OFF) SELECT SUM(price * random()) FROM inv WHERE id @@@ pdb.all();
EXPLAIN (COSTS OFF) SELECT SUM(i.price + (SELECT 1)) FROM inv i JOIN ord o ON o.inv_id = i.id WHERE i.id @@@ pdb.all();
SET paradedb.planner_warnings = 'off';

-- A FILTER guards the expression, so i = 0 does not divide by zero.
SELECT scan_used($$SELECT grp, SUM(100 / i) FILTER (WHERE i <> 0) FROM num WHERE id @@@ pdb.all() GROUP BY grp$$);
SELECT grp, SUM(100 / i) FILTER (WHERE i <> 0), COUNT(100 / i) FILTER (WHERE i <> 0) FROM num WHERE id @@@ pdb.all() GROUP BY grp ORDER BY grp;
SELECT SUM(100 / i) FILTER (WHERE i <> 0), MAX(100 / i) FILTER (WHERE i <> 0) FROM num WHERE id @@@ pdb.all();
SET paradedb.enable_aggregate_custom_scan = off;
SELECT grp, SUM(100 / i) FILTER (WHERE i <> 0), COUNT(100 / i) FILTER (WHERE i <> 0) FROM num WHERE id @@@ pdb.all() GROUP BY grp ORDER BY grp;
SELECT SUM(100 / i) FILTER (WHERE i <> 0), MAX(100 / i) FILTER (WHERE i <> 0) FROM num WHERE id @@@ pdb.all();
RESET paradedb.enable_aggregate_custom_scan;

-- ARRAY_AGG of a smallint or real expression stays on Postgres.
SELECT scan_used($$SELECT array_agg(s + s) FROM num WHERE id @@@ pdb.all()$$);
SELECT scan_used($$SELECT array_agg(r * r) FROM num WHERE id @@@ pdb.all()$$);
SELECT array_agg(s + s ORDER BY id), array_agg(r * 2 ORDER BY id) FROM num WHERE id @@@ pdb.all() AND id IN (1, 2);

-- An expression over a LATERAL unnest output stays on Postgres, like a bare one.
CREATE TABLE tg (id int PRIMARY KEY, tags text[]);
INSERT INTO tg VALUES (1, '{x,y}'), (2, '{z}'), (3, NULL);
CREATE INDEX tg_idx ON tg USING paradedb (id, (tags::pdb.literal));
SELECT scan_used($$SELECT MAX(upper(tag)) FROM tg, LATERAL unnest(tags) tag WHERE id @@@ pdb.all()$$);
SELECT MAX(upper(tag)), MIN(tag || '!'), COUNT(length(tag)) FROM tg, LATERAL unnest(tags) tag WHERE id @@@ pdb.all();
SET paradedb.enable_aggregate_custom_scan = off;
SELECT MAX(upper(tag)), MIN(tag || '!'), COUNT(length(tag)) FROM tg, LATERAL unnest(tags) tag WHERE id @@@ pdb.all();
RESET paradedb.enable_aggregate_custom_scan;
DROP TABLE tg;

-- CASE with an operand, ANY with >, integer abs and division at INT_MIN, and text
-- GREATEST under a collation.
CREATE TABLE edge (id int PRIMARY KEY, f float8, q int, t text, b bool);
INSERT INTO edge VALUES
    (1, 2.5, 5, 'abc', true), (2, 90, 1, 'B', false), (3, 1, -2147483648, 'a', true), (4, 200, 7, 'Zed', false);
CREATE INDEX edge_idx ON edge USING paradedb (id, f, q, (t::pdb.literal), b);
SELECT scan_used($$SELECT SUM(CASE b WHEN true THEN 1 ELSE 0 END) FROM edge WHERE id @@@ pdb.all()$$);
SELECT SUM(CASE b WHEN true THEN 1 ELSE 0 END), SUM(CASE q WHEN 5 THEN 10 WHEN 7 THEN 70 ELSE 0 END) FROM edge WHERE id @@@ pdb.all();
SELECT SUM(CASE WHEN f > ANY(ARRAY[q::float8, 100]) THEN 1 ELSE 0 END), SUM(CASE WHEN f < ALL(ARRAY[q::float8, 100]) THEN 1 ELSE 0 END) FROM edge WHERE id @@@ pdb.all();
SELECT MAX(abs(q)) FROM edge WHERE id @@@ pdb.all();
SELECT MAX(q / -1) FROM edge WHERE id @@@ pdb.all();
SELECT MAX(abs(q)), MAX(q / -1), MAX(q % 4) FROM edge WHERE id @@@ pdb.all() AND id <> 3;
SELECT MAX(greatest(t COLLATE "und-x-icu", 'B')), MIN(least(t COLLATE "und-x-icu", 'b')), COUNT(nullif(t COLLATE "und-x-icu", 'abc')) FROM edge WHERE id @@@ pdb.all();
SET paradedb.enable_aggregate_custom_scan = off;
SELECT SUM(CASE b WHEN true THEN 1 ELSE 0 END), SUM(CASE q WHEN 5 THEN 10 WHEN 7 THEN 70 ELSE 0 END) FROM edge WHERE id @@@ pdb.all();
SELECT SUM(CASE WHEN f > ANY(ARRAY[q::float8, 100]) THEN 1 ELSE 0 END), SUM(CASE WHEN f < ALL(ARRAY[q::float8, 100]) THEN 1 ELSE 0 END) FROM edge WHERE id @@@ pdb.all();
SELECT MAX(abs(q)) FROM edge WHERE id @@@ pdb.all();
SELECT MAX(q / -1) FROM edge WHERE id @@@ pdb.all();
SELECT MAX(abs(q)), MAX(q / -1), MAX(q % 4) FROM edge WHERE id @@@ pdb.all() AND id <> 3;
SELECT MAX(greatest(t COLLATE "und-x-icu", 'B')), MIN(least(t COLLATE "und-x-icu", 'b')), COUNT(nullif(t COLLATE "und-x-icu", 'abc')) FROM edge WHERE id @@@ pdb.all();
RESET paradedb.enable_aggregate_custom_scan;

-- STRING_AGG keeps its separator under a FILTER, and ARRAY_AGG guards its values.
SELECT scan_used($$SELECT string_agg(upper(t), ',' ORDER BY id) FILTER (WHERE q > 2) FROM edge WHERE id @@@ pdb.all()$$);
SELECT string_agg(upper(t), ',' ORDER BY id) FILTER (WHERE q > 2), array_agg(q * 2 ORDER BY id) FILTER (WHERE q > 2) FROM edge WHERE id @@@ pdb.all();
SELECT b, string_agg(upper(t), '|' ORDER BY id) FILTER (WHERE q > 2) FROM edge WHERE id @@@ pdb.all() GROUP BY b ORDER BY b;
SET paradedb.enable_aggregate_custom_scan = off;
SELECT string_agg(upper(t), ',' ORDER BY id) FILTER (WHERE q > 2), array_agg(q * 2 ORDER BY id) FILTER (WHERE q > 2) FROM edge WHERE id @@@ pdb.all();
SELECT b, string_agg(upper(t), '|' ORDER BY id) FILTER (WHERE q > 2) FROM edge WHERE id @@@ pdb.all() GROUP BY b ORDER BY b;
RESET paradedb.enable_aggregate_custom_scan;
DROP TABLE edge;

-- Parallel workers run a distributed aggregate over a join, with PgExprUdf in them.
CREATE TABLE files (id serial PRIMARY KEY, category text, content text, weight float8);
CREATE TABLE pages (id serial PRIMARY KEY, file_id int, size_bytes int, rate float8);
CREATE INDEX files_idx ON files USING paradedb (id, (category::pdb.unicode_words('columnar=true')), content, weight);
CREATE INDEX pages_idx ON pages USING paradedb (id, file_id, size_bytes, rate);
SET paradedb.global_mutable_segment_rows = 0;
INSERT INTO files (category, content, weight) SELECT 'cat-' || (g % 5), 'Section ' || g, g * 0.5 FROM generate_series(1, 100) g;
INSERT INTO files (category, content, weight) SELECT 'cat-' || (g % 5), 'Section ' || g, g * 0.5 FROM generate_series(101, 200) g;
INSERT INTO pages (file_id, size_bytes, rate) SELECT (g % 200) + 1, g * 10, g % 3 FROM generate_series(1, 500) g;
INSERT INTO pages (file_id, size_bytes, rate) SELECT (g % 200) + 1, g * 10, g % 3 FROM generate_series(501, 1000) g;
RESET paradedb.global_mutable_segment_rows;
SET max_parallel_workers_per_gather TO 3;
SET max_parallel_workers TO 8;
SET min_parallel_table_scan_size TO 0;
SET parallel_setup_cost TO 0;
SET parallel_tuple_cost TO 0;
CREATE FUNCTION plan_is_distributed(query text) RETURNS boolean AS $$
DECLARE
    line text;
BEGIN
    FOR line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || query LOOP
        IF line LIKE '%AggregateExec: mode=Partial%' THEN
            RETURN true;
        END IF;
    END LOOP;
    RETURN false;
END
$$ LANGUAGE plpgsql;
SELECT plan_is_distributed($$SELECT f.category, COUNT(*), SUM(p.size_bytes * 2), SUM(f.weight * p.rate), MAX(p.size_bytes + f.id) FROM files f JOIN pages p ON f.id = p.file_id WHERE f.content ||| 'Section' GROUP BY f.category$$);
SELECT f.category, COUNT(*), SUM(p.size_bytes * 2), SUM(f.weight * p.rate), MAX(p.size_bytes + f.id) FROM files f JOIN pages p ON f.id = p.file_id WHERE f.content ||| 'Section' GROUP BY f.category ORDER BY f.category;
RESET parallel_tuple_cost;
RESET parallel_setup_cost;
RESET min_parallel_table_scan_size;
RESET max_parallel_workers;
SET max_parallel_workers_per_gather = 0;
SELECT f.category, COUNT(*), SUM(p.size_bytes * 2), SUM(f.weight * p.rate), MAX(p.size_bytes + f.id) FROM files f JOIN pages p ON f.id = p.file_id WHERE f.content ||| 'Section' GROUP BY f.category ORDER BY f.category;
SET paradedb.enable_aggregate_custom_scan = off;
SELECT f.category, COUNT(*), SUM(p.size_bytes * 2), SUM(f.weight * p.rate), MAX(p.size_bytes + f.id) FROM files f JOIN pages p ON f.id = p.file_id WHERE f.content ||| 'Section' GROUP BY f.category ORDER BY f.category;
RESET paradedb.enable_aggregate_custom_scan;
RESET max_parallel_workers_per_gather;

DROP FUNCTION plan_is_distributed(text);
DROP TABLE pages;
DROP TABLE files;
DROP TABLE num;
DROP TABLE misc;
DROP TABLE dec;
DROP TABLE ord;
DROP TABLE inv;
DROP FUNCTION scan_used(text);
