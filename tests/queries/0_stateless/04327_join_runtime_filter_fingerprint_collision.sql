-- Two structurally identical JOINs (same tables joined on the same columns) hash to the same
-- runtime-filter structural fingerprint by design. The build/apply rendezvous, however, uses a
-- fresh random key per filter, so a colliding fingerprint must NOT cross-wire filters: with runtime
-- filters on, the full joined result must equal the runtime-filters-off baseline even when the
-- colliding joins read the same table through different filters. See `joinRuntimeFilter.cpp`: the
-- const argument's NAME is the structural fingerprint (`_runtime_filter_<hash>`, which may collide),
-- while its VALUE is the random rendezvous key the build and apply sides actually agree on.

DROP TABLE IF EXISTS rf_fp_t;
DROP TABLE IF EXISTS rf_fp_a;

CREATE TABLE rf_fp_t (k UInt64, v UInt64) ENGINE = MergeTree ORDER BY k;
CREATE TABLE rf_fp_a (k UInt64, w UInt64) ENGINE = MergeTree ORDER BY k;
INSERT INTO rf_fp_t SELECT number, number * 31 + 7 FROM numbers(1000);
-- Two payload rows per key, so the joins are 1-to-many and the aggregates below depend on which
-- rows survive and how they pair, not just on a row count.
INSERT INTO rf_fp_a SELECT number, number * 17 + 3 FROM numbers(1000);
INSERT INTO rf_fp_a SELECT number, number * 19 + 5 FROM numbers(1000);

SET enable_analyzer = 1, query_plan_join_swap_table = 'false', enable_join_runtime_filters = 1;

-- Sanity: the two identical join subtrees really do collide on the structural fingerprint, so the
-- test exercises the collision path rather than silently diverging into distinct fingerprints.
SELECT 'fingerprint collides', (name1 = name2) AND (name1 != '')
FROM
(
    SELECT
        (SELECT extractAll(arrayStringConcat(groupArray(explain), ' '), '_runtime_filter_\\d+')[1]
         FROM (EXPLAIN actions = 1 SELECT count() FROM rf_fp_t JOIN rf_fp_a ON rf_fp_t.k = rf_fp_a.k WHERE rf_fp_a.k < 300)) AS name1,
        (SELECT extractAll(arrayStringConcat(groupArray(explain), ' '), '_runtime_filter_\\d+')[1]
         FROM (EXPLAIN actions = 1 SELECT count() FROM rf_fp_t JOIN rf_fp_a ON rf_fp_t.k = rf_fp_a.k WHERE rf_fp_a.k >= 700)) AS name2
);

-- Result-row counts of the 1-to-many joins (human-checkable: 300 matching keys * 2 payload rows = 600
-- per separate subtree; 100 keys in [200, 300) * 2 * 2 = 400 for the shared-probe double join).
SELECT 'separate subtree rows',
    (SELECT count() FROM rf_fp_t t JOIN rf_fp_a a ON t.k = a.k WHERE a.k < 300),
    (SELECT count() FROM rf_fp_t t JOIN rf_fp_a a ON t.k = a.k WHERE a.k >= 700);
SELECT 'shared probe rows',
    count()
FROM rf_fp_t t JOIN rf_fp_a AS a1 ON t.k = a1.k JOIN rf_fp_a AS a2 ON t.k = a2.k
WHERE a1.k < 300 AND a2.k >= 200;

-- The real guarantee: a hash over every surviving row's keys AND payloads (so any wrongly pruned or
-- wrongly paired row changes it) must be identical with runtime filters on and off.
SELECT 'rf on == off',
    (SELECT sum(cityHash64(t.k, t.v, a.w)) FROM rf_fp_t t JOIN rf_fp_a a ON t.k = a.k WHERE a.k < 300 SETTINGS enable_join_runtime_filters = 1)
  = (SELECT sum(cityHash64(t.k, t.v, a.w)) FROM rf_fp_t t JOIN rf_fp_a a ON t.k = a.k WHERE a.k < 300 SETTINGS enable_join_runtime_filters = 0)
    AND
    (SELECT sum(cityHash64(t.k, t.v, a.w)) FROM rf_fp_t t JOIN rf_fp_a a ON t.k = a.k WHERE a.k >= 700 SETTINGS enable_join_runtime_filters = 1)
  = (SELECT sum(cityHash64(t.k, t.v, a.w)) FROM rf_fp_t t JOIN rf_fp_a a ON t.k = a.k WHERE a.k >= 700 SETTINGS enable_join_runtime_filters = 0)
    AND
    (SELECT sum(cityHash64(t.k, t.v, a1.w, a2.w)) FROM rf_fp_t t JOIN rf_fp_a AS a1 ON t.k = a1.k JOIN rf_fp_a AS a2 ON t.k = a2.k WHERE a1.k < 300 AND a2.k >= 200 SETTINGS enable_join_runtime_filters = 1)
  = (SELECT sum(cityHash64(t.k, t.v, a1.w, a2.w)) FROM rf_fp_t t JOIN rf_fp_a AS a1 ON t.k = a1.k JOIN rf_fp_a AS a2 ON t.k = a2.k WHERE a1.k < 300 AND a2.k >= 200 SETTINGS enable_join_runtime_filters = 0);

DROP TABLE rf_fp_t;
DROP TABLE rf_fp_a;
