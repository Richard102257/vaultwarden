CREATE TABLE email_code_challenges (
  uuid          VARCHAR(40)  NOT NULL PRIMARY KEY,
  email         VARCHAR(255) NOT NULL,
  purpose       VARCHAR(32)  NOT NULL,
  code_hash     VARCHAR(128) NOT NULL,
  code_salt     VARCHAR(64)  NOT NULL,
  created_at    DATETIME     NOT NULL,
  expires_at    DATETIME     NOT NULL,
  last_sent_at  DATETIME     NOT NULL,
  attempts      INT          NOT NULL DEFAULT 0,
  ip_address    VARCHAR(64)  NOT NULL,
  UNIQUE KEY email_code_challenges_email_purpose (email, purpose),
  INDEX email_code_challenges_expires_idx (expires_at)
);
