-- V2: dedup shopping_cart_item and enforce one row per (cart, product).
-- Context: docs/performance-stress-report-2026-06-10.md problem P1 — the
-- check-then-insert race under replica lag left duplicate rows in the table.
-- Dedup MUST run before the ALTER or the unique key creation fails.

-- 1) Merge duplicate quantities into the keeper row (lowest id). The "latest
--    price" rule is not reconstructible post-hoc, so the keeper's price stays.
UPDATE shopping_cart_item sci
JOIN (
    SELECT shopping_cart_id, product_id, MIN(id) AS keep_id, SUM(quantity) AS total_qty
    FROM shopping_cart_item
    GROUP BY shopping_cart_id, product_id
    HAVING COUNT(*) > 1
) d ON sci.id = d.keep_id
SET sci.quantity = d.total_qty;

-- 2) Drop the non-keeper duplicates.
DELETE sci FROM shopping_cart_item sci
JOIN (
    SELECT shopping_cart_id, product_id, MIN(id) AS keep_id
    FROM shopping_cart_item
    GROUP BY shopping_cart_id, product_id
    HAVING COUNT(*) > 1
) d ON sci.shopping_cart_id = d.shopping_cart_id
   AND sci.product_id = d.product_id
   AND sci.id <> d.keep_id;

-- 3) Enforce.
ALTER TABLE shopping_cart_item
    ADD UNIQUE KEY uq_cart_product (shopping_cart_id, product_id);
