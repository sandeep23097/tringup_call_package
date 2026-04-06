-- ============================================================
-- Migration 002: Admin panel tables
-- ============================================================

SET NAMES utf8mb4;

-- Admin users table
CREATE TABLE IF NOT EXISTS admin_users (
  id            VARCHAR(36)  PRIMARY KEY DEFAULT (UUID()),
  name          VARCHAR(100) NOT NULL,
  email         VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  created_at    TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Default admin user (password: admin123)
-- Hash generated with: bcrypt.hash('admin123', 10)
INSERT IGNORE INTO admin_users (id, name, email, password_hash)
VALUES (
  UUID(),
  'Administrator',
  'admin@example.com',
  '$2a$10$rIC7BFoJo0a7M3K4JEQnp.dz2cK47g7W2xLrP8K3K3SBf9d1ZVzKi'
);

-- Application configuration table (key-value store for runtime config)
CREATE TABLE IF NOT EXISTS app_config (
  key_name   VARCHAR(100) PRIMARY KEY,
  value      TEXT,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
