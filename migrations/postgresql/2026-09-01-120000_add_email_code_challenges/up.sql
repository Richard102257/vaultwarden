CREATE TABLE email_code_challenges (
  uuid          VARCHAR(40)  NOT NULL PRIMARY KEY,
  email         VARCHAR(255) NOT NULL,
  purpose       VARCHAR(32)  NOT NULL,
  code_hash     VARCHAR(128) NOT NULL,
  code_salt     VARCHAR(64)  NOT NULL,
  created_at    TIMESTAMP    NOT NULL,
  expires_at    TIMESTAMP    NOT NULL,
  last_sent_at  TIMESTAMP    NOT NULL,
  attempts      INTEGER      NOT NULL DEFAULT 0,
  ip_address    VARCHAR(64)  NOT NULL,
  UNIQUE (email, purpose)
);

CREATE INDEX email_code_challenges_expires_idx ON email_code_challenges (expires_at);
