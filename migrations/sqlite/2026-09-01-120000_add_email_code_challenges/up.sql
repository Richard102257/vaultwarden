CREATE TABLE email_code_challenges (
  uuid          TEXT     NOT NULL PRIMARY KEY,
  email         TEXT     NOT NULL,
  purpose       TEXT     NOT NULL,
  code_hash     TEXT     NOT NULL,
  code_salt     TEXT     NOT NULL,
  created_at    DATETIME NOT NULL,
  expires_at    DATETIME NOT NULL,
  last_sent_at  DATETIME NOT NULL,
  attempts      INTEGER  NOT NULL DEFAULT 0,
  ip_address    TEXT     NOT NULL,
  UNIQUE (email, purpose)
);

CREATE INDEX email_code_challenges_expires_idx ON email_code_challenges (expires_at);
