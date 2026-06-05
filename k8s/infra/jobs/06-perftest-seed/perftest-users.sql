-- =============================================
-- K6 Performance Test - USERS-ONLY Seed (in-cluster safe)
-- =============================================
-- Seeds only authorization-server tables (account/user/role/account_role).
-- Products are NOT seeded here: in this microservice architecture the catalog
-- lives in MongoDB (product-service) and stock in inventory-service. The k6
-- payment-flow test points PRODUCT_IDS at real seeded catalog IDs instead.
-- Passwords: perftest_admin = Admin@123456 ; perftest_user_N = Test@123456
-- BCrypt cost factor 10. Idempotent: INSERT IGNORE / ON DUPLICATE KEY UPDATE.
-- Consumed by the 06-perftest-seed Job (see seed.sh).
-- =============================================

-- Admin user (setup phase: tops up inventory, needs ADMIN role)
INSERT INTO account (id, username, password, is_activated, created_at)
VALUES (
  UUID(),
  'perftest_admin',
  '$2a$10$dXJ3SW6G7P50lGmMkkmwe.20cQQubK3.HZWzG3YB1tlRy.fqvM/BG', -- Admin@123456
  true,
  NOW()
) ON DUPLICATE KEY UPDATE is_activated = true;

SET @admin_account_id = (SELECT id FROM account WHERE username = 'perftest_admin');

INSERT INTO user (id, email, account_id)
VALUES (UUID(), 'perftest_admin@test.com', @admin_account_id)
ON DUPLICATE KEY UPDATE email = 'perftest_admin@test.com';

INSERT INTO account_role (account_id, role_id)
SELECT @admin_account_id, r.id FROM role r WHERE r.name = 'ADMIN'
ON DUPLICATE KEY UPDATE account_id = account_id;

INSERT INTO account_role (account_id, role_id)
SELECT @admin_account_id, r.id FROM role r WHERE r.name = 'USER'
ON DUPLICATE KEY UPDATE account_id = account_id;

-- 100 load-test users (USER role)
DELIMITER //
DROP PROCEDURE IF EXISTS create_test_users//
CREATE PROCEDURE create_test_users()
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE account_uuid VARCHAR(36);
  DECLARE user_uuid VARCHAR(36);
  DECLARE uname VARCHAR(50);
  DECLARE uemail VARCHAR(100);
  DECLARE user_role_id VARCHAR(36);

  SELECT id INTO user_role_id FROM role WHERE name = 'USER' LIMIT 1;

  WHILE i <= 100 DO
    SET account_uuid = UUID();
    SET user_uuid = UUID();
    SET uname = CONCAT('perftest_user_', i);
    SET uemail = CONCAT('perftest_user_', i, '@test.com');

    INSERT IGNORE INTO account (id, username, password, is_activated, created_at)
    VALUES (
      account_uuid,
      uname,
      '$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZRGdjGj/n3.nL/9Rcf6/1sJwBaHHi', -- Test@123456
      true,
      NOW()
    );

    SELECT id INTO account_uuid FROM account WHERE username = uname;

    INSERT IGNORE INTO user (id, email, account_id)
    VALUES (user_uuid, uemail, account_uuid);

    INSERT IGNORE INTO account_role (account_id, role_id)
    VALUES (account_uuid, user_role_id);

    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;

CALL create_test_users();
DROP PROCEDURE IF EXISTS create_test_users;

SELECT 'perftest admin:' AS status, COUNT(*) AS n FROM account WHERE username = 'perftest_admin';
SELECT 'perftest users:' AS status, COUNT(*) AS n FROM account WHERE username LIKE 'perftest_user_%';
