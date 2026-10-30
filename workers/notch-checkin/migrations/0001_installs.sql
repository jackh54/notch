-- One row per install. The ID is random and made by the app; nothing here identifies a person.
CREATE TABLE installs (
  install_id TEXT PRIMARY KEY,
  version    TEXT NOT NULL,
  build      TEXT NOT NULL,
  first_seen INTEGER NOT NULL,
  last_seen  INTEGER NOT NULL
);

CREATE INDEX installs_last_seen ON installs (last_seen);
