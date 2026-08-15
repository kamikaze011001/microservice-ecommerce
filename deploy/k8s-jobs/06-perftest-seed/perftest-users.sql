-- =============================================
-- K6 Performance Test - USERS-ONLY Seed (in-cluster safe)
-- =============================================
-- Seeds only authorization-server tables: `user`, `account`, `account_role`.
-- Schema (from authorization-server JPA entities + docker/ecommerce.sql):
--   user(id PK, email UNIQUE NOT NULL, name, gender, address, avatar_url)
--   account(id PK, username UNIQUE NOT NULL, password NOT NULL,
--           is_activated NOT NULL, user_id NOT NULL -> user.id)
--   account_role(id PK, account_id NOT NULL, role_id NOT NULL)
--   role(id PK, name)        -- existing roles: EMPLOYEE, ADMIN, MERCHANT
-- Insert order matters: user -> account (FK user_id) -> account_role.
--
-- Authorization model (docker/api_role.json): the order/payment endpoints the
-- k6 flow hits require AUTHORIZED (any authenticated account), so the 100 load
-- users need NO role row -- only a valid account to log in. perftest_admin gets
-- the ADMIN role because the k6 setup() phase tops up stock via
-- PATCH /inventory-service/v1/inventories/** which requires ADMIN. There is no
-- "USER" role in this schema.
--
-- Products are NOT seeded here (catalog lives in MongoDB; the k6 test points
-- PRODUCT_IDS at real seeded catalog IDs).
--
-- Passwords (bcrypt cost 10, verified with htpasswd against this exact hash):
--   perftest_admin  = Admin@123456
--   perftest_user_N = Test@123456
-- Idempotent: `email`/`username` are UNIQUE so INSERT IGNORE is a no-op on
-- re-run; the admin role link is guarded by a pre-counted variable. The
-- 06-perftest-seed Job additionally skips the whole script if perftest_admin
-- already exists (see seed.sh).
-- =============================================

-- ---- admin: user -> account -> ADMIN role ----
INSERT IGNORE INTO `user` (id, email)
VALUES (UUID(), 'perftest_admin@test.com');

SET @admin_user_id = (SELECT id FROM `user` WHERE email = 'perftest_admin@test.com');

INSERT IGNORE INTO `account` (id, username, password, is_activated, user_id)
VALUES (
  UUID(),
  'perftest_admin',
  '$2a$10$4piyvE7LAoy8KVqhbcwN1.hUxQTkP9eOU.4ZvlPFJlMwPgaIYS3MG', -- Admin@123456
  1,
  @admin_user_id
);

SET @admin_account_id = (SELECT id FROM `account` WHERE username = 'perftest_admin');

-- Ensure the ADMIN role exists. docker/ecommerce.sql seeds it, but in k8s the
-- mysql-seed runs before Hibernate creates the tables (data-only dump), so that
-- INSERT fails and `role` ends up empty -> @admin_role_id would be NULL and the
-- link below would be silently skipped (perftest_admin gets no role -> the k6
-- setup() inventory top-up 403s -> stock never refills -> test runs dry). Make
-- this seed self-sufficient instead of depending on ecommerce.sql ordering.
INSERT INTO `role` (id, name)
SELECT UUID(), 'ADMIN' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM `role` WHERE name = 'ADMIN');

SET @admin_role_id    = (SELECT id FROM `role` WHERE name = 'ADMIN' LIMIT 1);
SET @admin_link_count = (SELECT COUNT(*) FROM `account_role`
                         WHERE account_id = @admin_account_id AND role_id = @admin_role_id);

-- account_role has no UNIQUE(account_id, role_id), so guard via the pre-counted
-- variable (FROM DUAL avoids referencing the target table in the INSERT-SELECT).
INSERT INTO `account_role` (id, account_id, role_id)
SELECT UUID(), @admin_account_id, @admin_role_id
FROM DUAL
WHERE @admin_role_id IS NOT NULL AND @admin_link_count = 0;

-- ---- 100 load users: user + account only (AUTHORIZED = authenticated) ----
DELIMITER //
DROP PROCEDURE IF EXISTS create_perftest_users//
CREATE PROCEDURE create_perftest_users()
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE v_user_id VARCHAR(36);
  DECLARE uname VARCHAR(50);
  DECLARE uemail VARCHAR(100);

  WHILE i <= 100 DO
    SET uname  = CONCAT('perftest_user_', i);
    SET uemail = CONCAT('perftest_user_', i, '@test.com');

    INSERT IGNORE INTO `user` (id, email) VALUES (UUID(), uemail);
    SET v_user_id = (SELECT id FROM `user` WHERE email = uemail);

    INSERT IGNORE INTO `account` (id, username, password, is_activated, user_id)
    VALUES (
      UUID(),
      uname,
      '$2a$10$p0YRQWiVtDe8ioifDNLyI.y9rbjl/5aWWYR.q3bFb5tSNhs5DTtZC', -- Test@123456
      1,
      v_user_id
    );

    SET i = i + 1;
  END WHILE;
END//
DELIMITER ;

CALL create_perftest_users();
DROP PROCEDURE IF EXISTS create_perftest_users;

SELECT 'perftest admin:'  AS status, COUNT(*) AS n FROM `account` WHERE username = 'perftest_admin';
SELECT 'perftest users:'  AS status, COUNT(*) AS n FROM `account` WHERE username LIKE 'perftest_user_%';
SELECT 'admin ADMIN link:' AS status, COUNT(*) AS n
  FROM `account_role` ar
  JOIN `account` a ON a.id = ar.account_id
  JOIN `role` r    ON r.id = ar.role_id
  WHERE a.username = 'perftest_admin' AND r.name = 'ADMIN';
