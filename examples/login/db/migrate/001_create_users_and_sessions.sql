CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  email_address TEXT NOT NULL UNIQUE,
  password_digest TEXT NOT NULL
);

CREATE TABLE sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users (id),
  token TEXT NOT NULL UNIQUE,
  user_agent TEXT NOT NULL,
  ip_address TEXT NOT NULL,
  last_active_at TEXT NOT NULL
);
