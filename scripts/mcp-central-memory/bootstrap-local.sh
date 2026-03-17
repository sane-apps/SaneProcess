#!/usr/bin/env bash
set -euo pipefail

DB_NAME="${CENTRAL_MEMORY_DB_NAME:-central_memory}"
DB_URL="${CENTRAL_MEMORY_DATABASE_URL:-postgresql://${USER:-sj}@localhost:5432/${DB_NAME}}"
EMBED_DIM="${CENTRAL_MEMORY_EMBED_DIMENSIONS:-1536}"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required but not installed."
  exit 1
fi

BREW_PREFIX="$(brew --prefix)"
PG_BIN="${BREW_PREFIX}/opt/postgresql@17/bin"
PSQL="${PG_BIN}/psql"
CREATEDB="${PG_BIN}/createdb"
PG_ISREADY="${PG_BIN}/pg_isready"

if ! brew list --formula postgresql@17 >/dev/null 2>&1; then
  echo "Installing postgresql@17..."
  brew install postgresql@17
fi

if ! brew list --formula pgvector >/dev/null 2>&1; then
  echo "Installing pgvector..."
  brew install pgvector
fi

if ! brew services list | awk '{print $1,$2}' | grep -q '^postgresql@17 started$'; then
  echo "Starting postgresql@17 service..."
  brew services start postgresql@17
fi

echo "Waiting for PostgreSQL to accept connections..."
for _ in {1..20}; do
  if "${PG_ISREADY}" -h localhost -p 5432 >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! "${PG_ISREADY}" -h localhost -p 5432 >/dev/null 2>&1; then
  echo "PostgreSQL did not become ready in time."
  exit 1
fi

if ! "${PSQL}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  echo "Creating database ${DB_NAME}..."
  "${CREATEDB}" "${DB_NAME}"
fi

"${PSQL}" -d "${DB_NAME}" <<SQL
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS central_memories (
  id BIGSERIAL PRIMARY KEY,
  external_id TEXT UNIQUE,
  content TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL DEFAULT '',
  tags TEXT[] NOT NULL DEFAULT '{}',
  metadata JSONB NOT NULL DEFAULT '{}',
  embedding vector(${EMBED_DIM}) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS central_memories_kind_idx ON central_memories(kind);
CREATE INDEX IF NOT EXISTS central_memories_tags_gin_idx ON central_memories USING GIN(tags);
CREATE INDEX IF NOT EXISTS central_memories_metadata_gin_idx ON central_memories USING GIN(metadata);
CREATE INDEX IF NOT EXISTS central_memories_created_idx ON central_memories(created_at DESC);
CREATE INDEX IF NOT EXISTS central_memories_embedding_hnsw_idx ON central_memories USING hnsw (embedding vector_cosine_ops);
SQL

echo "Central memory database is ready."
echo "Database URL: ${DB_URL}"
echo "Next: add these env vars to your MCP config if needed:"
echo "  CENTRAL_MEMORY_DATABASE_URL=${DB_URL}"
echo "  CENTRAL_MEMORY_EMBED_DIMENSIONS=${EMBED_DIM}"
echo "  OPENAI_API_KEY=<your key>"
