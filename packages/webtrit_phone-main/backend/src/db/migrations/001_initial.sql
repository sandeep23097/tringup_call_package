SET NAMES utf8mb4;
SET time_zone = '+00:00';

CREATE TABLE IF NOT EXISTS users (
  id            CHAR(36)     NOT NULL,
  tenant_id     VARCHAR(100) NOT NULL DEFAULT '',
  email         VARCHAR(255) NULL,
  password_hash VARCHAR(255) NULL,
  first_name    VARCHAR(100) NULL,
  last_name     VARCHAR(100) NULL,
  alias_name    VARCHAR(100) NULL,
  company_name  VARCHAR(200) NULL,
  time_zone     VARCHAR(50)  NOT NULL DEFAULT 'UTC',
  status        VARCHAR(20)  NOT NULL DEFAULT 'active',
  phone_main    VARCHAR(30)  NULL,
  ext           VARCHAR(20)  NULL,
  sip_username  VARCHAR(100) NULL,
  sip_password  VARCHAR(100) NULL,
  created_at    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_email        (email),
  UNIQUE KEY uq_users_phone_main   (phone_main),
  UNIQUE KEY uq_users_ext          (ext),
  UNIQUE KEY uq_users_sip_username (sip_username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS sessions (
  id          CHAR(36)     NOT NULL,
  user_id     CHAR(36)     NOT NULL,
  token       TEXT         NOT NULL,
  app_type    VARCHAR(20)  NOT NULL DEFAULT 'unknown',
  bundle_id   VARCHAR(200) NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_sessions_user_id (user_id),
  CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS push_tokens (
  id          CHAR(36)    NOT NULL,
  user_id     CHAR(36)    NOT NULL,
  session_id  CHAR(36)    NULL,
  type        VARCHAR(20) NOT NULL,
  value       TEXT        NOT NULL,
  updated_at  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_push_tokens_user_type (user_id, type),
  CONSTRAINT fk_push_tokens_user    FOREIGN KEY (user_id)    REFERENCES users(id)    ON DELETE CASCADE,
  CONSTRAINT fk_push_tokens_session FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS otp_codes (
  id          CHAR(36)    NOT NULL,
  user_id     CHAR(36)    NOT NULL,
  code        VARCHAR(10) NOT NULL,
  expires_at  DATETIME    NOT NULL,
  used        TINYINT(1)  NOT NULL DEFAULT 0,
  created_at  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  CONSTRAINT fk_otp_codes_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS provision_tokens (
  id          CHAR(36)     NOT NULL,
  user_id     CHAR(36)     NOT NULL,
  token       VARCHAR(255) NOT NULL,
  used        TINYINT(1)   NOT NULL DEFAULT 0,
  expires_at  DATETIME     NOT NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_provision_token (token),
  CONSTRAINT fk_provision_tokens_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS app_status (
  user_id     CHAR(36)   NOT NULL,
  registered  TINYINT(1) NOT NULL DEFAULT 0,
  updated_at  DATETIME   NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id),
  CONSTRAINT fk_app_status_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS call_records (
  id                CHAR(36)     NOT NULL,
  call_id           VARCHAR(100) NOT NULL,
  caller_user_id    CHAR(36)     NULL,
  callee_user_id    CHAR(36)     NULL,
  caller            VARCHAR(50)  NOT NULL,
  callee            VARCHAR(50)  NOT NULL,
  direction         VARCHAR(5)   NOT NULL,
  status            VARCHAR(20)  NOT NULL,
  connect_time      DATETIME     NULL,
  disconnect_time   DATETIME     NULL,
  duration          INT          NOT NULL DEFAULT 0,
  disconnect_reason VARCHAR(50)  NULL,
  recording_id      CHAR(36)     NULL,
  created_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_call_records_call_id (call_id),
  KEY idx_call_records_caller (caller_user_id),
  KEY idx_call_records_callee (callee_user_id),
  CONSTRAINT fk_call_records_caller FOREIGN KEY (caller_user_id) REFERENCES users(id) ON DELETE SET NULL,
  CONSTRAINT fk_call_records_callee FOREIGN KEY (callee_user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS voicemails (
  id          CHAR(36)      NOT NULL,
  user_id     CHAR(36)      NOT NULL,
  sender      VARCHAR(50)   NOT NULL,
  receiver    VARCHAR(50)   NOT NULL,
  duration    DECIMAL(10,2) NULL,
  seen        TINYINT(1)    NOT NULL DEFAULT 0,
  file_path   TEXT          NULL,
  file_size   INT           NULL,
  created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_voicemails_user (user_id),
  CONSTRAINT fk_voicemails_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS notifications (
  id          INT          NOT NULL AUTO_INCREMENT,
  user_id     CHAR(36)     NOT NULL,
  title       VARCHAR(200) NOT NULL,
  content     TEXT         NOT NULL,
  type        VARCHAR(30)  NOT NULL DEFAULT 'announcement',
  seen        TINYINT(1)   NOT NULL DEFAULT 0,
  read_at     DATETIME     NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_notifications_user (user_id),
  CONSTRAINT fk_notifications_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Default test users (password: test1234)
INSERT IGNORE INTO users (id, email, password_hash, first_name, last_name, phone_main, ext, sip_username, status)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'alice@example.com', '$2a$10$A61sCnQfK7CZhWdb2s5pW.db8/aDjSo3OBCQhXnMlbOAfsu5Ofoqm', 'Alice', 'Smith', '+15551111111', '101', 'alice', 'active'),
  ('22222222-2222-2222-2222-222222222222', 'bob@example.com',   '$2a$10$A61sCnQfK7CZhWdb2s5pW.db8/aDjSo3OBCQhXnMlbOAfsu5Ofoqm', 'Bob',   'Jones', '+15552222222', '102', 'bob',   'active');
