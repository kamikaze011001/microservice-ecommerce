-- =============================================
-- K6 Performance Test - Database Seed Script
-- =============================================
-- Run this BEFORE running performance tests
-- Password for all users: Test@123456 or Admin@123456
-- BCrypt hash generated with cost factor 10
-- =============================================

-- Create Admin User for Setup Phase
-- Password: Admin@123456
INSERT INTO account (id, username, password, is_activated, created_at)
VALUES (
  UUID(),
  'perftest_admin',
  '$2a$10$dXJ3SW6G7P50lGmMkkmwe.20cQQubK3.HZWzG3YB1tlRy.fqvM/BG', -- Admin@123456
  true,
  NOW()
) ON DUPLICATE KEY UPDATE is_activated = true;

-- Get the admin account ID and create user record
SET @admin_account_id = (SELECT id FROM account WHERE username = 'perftest_admin');

INSERT INTO user (id, email, account_id)
VALUES (
  UUID(),
  'perftest_admin@test.com',
  @admin_account_id
) ON DUPLICATE KEY UPDATE email = 'perftest_admin@test.com';

-- Assign ADMIN role to admin user
INSERT INTO account_role (account_id, role_id)
SELECT @admin_account_id, r.id
FROM role r
WHERE r.name = 'ADMIN'
ON DUPLICATE KEY UPDATE account_id = account_id;

-- Also assign USER role to admin (some endpoints might need it)
INSERT INTO account_role (account_id, role_id)
SELECT @admin_account_id, r.id
FROM role r
WHERE r.name = 'USER'
ON DUPLICATE KEY UPDATE account_id = account_id;

-- =============================================
-- Create 100 Test Users
-- Password: Test@123456
-- =============================================

DELIMITER //

DROP PROCEDURE IF EXISTS create_test_users//

CREATE PROCEDURE create_test_users()
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE account_uuid VARCHAR(36);
  DECLARE user_uuid VARCHAR(36);
  DECLARE username VARCHAR(50);
  DECLARE email VARCHAR(100);
  DECLARE user_role_id VARCHAR(36);

  -- Get USER role ID
  SELECT id INTO user_role_id FROM role WHERE name = 'USER' LIMIT 1;

  WHILE i <= 100 DO
    SET account_uuid = UUID();
    SET user_uuid = UUID();
    SET username = CONCAT('perftest_user_', i);
    SET email = CONCAT('perftest_user_', i, '@test.com');

    -- Create account (skip if exists)
    INSERT IGNORE INTO account (id, username, password, is_activated, created_at)
    VALUES (
      account_uuid,
      username,
      '$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZRGdjGj/n3.nL/9Rcf6/1sJwBaHHi', -- Test@123456
      true,
      NOW()
    );

    -- Get actual account ID (in case it already existed)
    SELECT id INTO account_uuid FROM account WHERE username = username;

    -- Create user record (skip if exists)
    INSERT IGNORE INTO user (id, email, account_id)
    VALUES (user_uuid, email, account_uuid);

    -- Assign USER role (skip if exists)
    INSERT IGNORE INTO account_role (account_id, role_id)
    VALUES (account_uuid, user_role_id);

    SET i = i + 1;
  END WHILE;
END//

DELIMITER ;

-- Execute the procedure
CALL create_test_users();

-- Clean up
DROP PROCEDURE IF EXISTS create_test_users;

-- =============================================
-- Verify Setup
-- =============================================
SELECT 'Admin user created:' as status, username FROM account WHERE username = 'perftest_admin';
SELECT 'Test users created:' as status, COUNT(*) as count FROM account WHERE username LIKE 'perftest_user_%';

-- =============================================
-- Create Test Products (Multiple products for orders)
-- =============================================
-- Create 3 test products with inventory

INSERT INTO product (id, name, price, created_at)
VALUES
  ('test-product-1', 'Performance Test Product 1', 49.99, NOW()),
  ('test-product-2', 'Performance Test Product 2', 79.99, NOW()),
  ('test-product-3', 'Performance Test Product 3', 99.99, NOW())
ON DUPLICATE KEY UPDATE name = VALUES(name), price = VALUES(price);

-- Create inventory records for each product (initial quantity 0, will be added by k6 setup)
INSERT INTO inventory (id, product_id, quantity, created_at)
VALUES
  (UUID(), 'test-product-1', 0, NOW()),
  (UUID(), 'test-product-2', 0, NOW()),
  (UUID(), 'test-product-3', 0, NOW())
ON DUPLICATE KEY UPDATE quantity = quantity;

-- Verify products created
SELECT 'Test products created:' as status, COUNT(*) as count
FROM product WHERE id IN ('test-product-1', 'test-product-2', 'test-product-3');
