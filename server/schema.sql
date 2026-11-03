CREATE TABLE app_user (
  created_at timestamptz NOT NULL,
  updated_at timestamptz(3) NOT NULL,
  deleted_at timestamptz,

  id uuid CONSTRAINT uk_app_user_id PRIMARY KEY,
  email text NOT NULL CONSTRAINT uk_app_user_email UNIQUE,

  password_hash text,
  password_updated_at timestamptz(3),

  salt bytea,
  ciphertext bytea
);

CREATE TABLE verification (
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  deleted_at timestamptz,

  id uuid CONSTRAINT uk_verification_id PRIMARY KEY,
  user_id uuid NOT NULL,

  hash bytea NOT NULL,
  expires_at timestamptz NOT NULL
);

CREATE INDEX idx_verification_expires_at ON verification(expires_at);

CREATE TABLE rate_limit (
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  deleted_at timestamptz,

  key bytea CONSTRAINT uk_rate_limit_key PRIMARY KEY,
  hit_count integer NOT NULL,
  expires_at timestamptz NOT NULL
);

CREATE INDEX idx_rate_limit_expires_at ON rate_limit(expires_at);
