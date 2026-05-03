-- V1__order_item_snapshot_fields.sql
-- Add nullable snapshot columns so order history survives product-service deletions.
-- Legacy rows are unaffected (values default to NULL).
ALTER TABLE order_item
  ADD COLUMN product_name VARCHAR(255) NULL,
  ADD COLUMN image_url VARCHAR(512) NULL;
