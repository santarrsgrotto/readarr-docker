#!/bin/bash
# load-openlibrary.sh
#
# Automates the full Open Library data pipeline for the community Readarr
# metadata server (github.com/santarrsgrotto/readarr-server).
#
# What this does:
#   1. Downloads Open Library bulk data dumps from archive.org (~14.5 GB compressed)
#   2. Decompresses them (~60 GB uncompressed — ensure you have space)
#   3. Chunks them into CSV files via openlibrary_data_process.py
#   4. Loads everything into a PostgreSQL database
#   5. Downloads and loads the santarrsgrotto/mapping Goodreads ID mappings
#
# Prerequisites:
#   - Docker with a running postgres:15 container named $PG_CONTAINER
#   - github.com/LibrariesHacked/openlibrary-search cloned to $OL_SEARCH_DIR
#   - github.com/santarrsgrotto/mapping cloned to $MAPPING_DIR
#   - python3 available on the host
#   - ~100 GB free disk space
#
# Usage:
#   ./load-openlibrary.sh
#
# Override defaults via environment variables, e.g.:
#   OL_SEARCH_DIR=/data/openlibrary-search PG_CONTAINER=my-postgres ./load-openlibrary.sh

set -euo pipefail

# --- Configuration (override via env) ---
OL_SEARCH_DIR="${OL_SEARCH_DIR:-./openlibrary-search}"
MAPPING_DIR="${MAPPING_DIR:-./mapping}"
PG_CONTAINER="${PG_CONTAINER:-readarr-meta-postgres}"
PG_USER="${PG_USER:-readarr}"
PG_DB="${PG_DB:-openlibrary}"

UNPROCESSED="$OL_SEARCH_DIR/data/unprocessed"
PROCESSED="$OL_SEARCH_DIR/data/processed"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- Preflight checks ---
log "Checking prerequisites..."

if ! docker inspect "$PG_CONTAINER" &>/dev/null; then
  echo "ERROR: PostgreSQL container '$PG_CONTAINER' not found. Start it first." >&2
  exit 1
fi

if [ ! -f "$OL_SEARCH_DIR/openlibrary_data_process.py" ]; then
  echo "ERROR: openlibrary-search not found at $OL_SEARCH_DIR" >&2
  echo "  Clone it: git clone https://github.com/LibrariesHacked/openlibrary-search $OL_SEARCH_DIR" >&2
  exit 1
fi

if [ ! -f "$MAPPING_DIR/goodreads_authors.csv" ] || grep -q "git-lfs" "$MAPPING_DIR/goodreads_authors.csv" 2>/dev/null; then
  echo "ERROR: mapping CSVs not found or are LFS pointers at $MAPPING_DIR" >&2
  echo "  Clone with LFS: git clone https://github.com/santarrsgrotto/mapping $MAPPING_DIR" >&2
  echo "  Or download manually via the LFS batch API (see README)." >&2
  exit 1
fi

mkdir -p "$UNPROCESSED" "$PROCESSED"

# --- Step 1: Download Open Library dumps ---
log "Checking Open Library dumps..."
# openlibrary.org redirects to archive.org; use direct URL for reliability
OL_DATE=$(curl -sI https://openlibrary.org/data/ol_dump_authors_latest.txt.gz \
  | grep -i "^location:" | grep -oP 'ol_dump_\K\d{4}-\d{2}-\d{2}' | head -1)

if [ -z "$OL_DATE" ]; then
  # Fallback: find the latest date from archive.org listing
  OL_DATE=$(curl -s "https://archive.org/download/ol_dump_latest/" \
    | grep -oP 'ol_dump_\K\d{4}-\d{2}-\d{2}' | sort | tail -1)
fi

if [ -z "$OL_DATE" ]; then
  echo "ERROR: Could not determine current Open Library dump date." >&2
  exit 1
fi

log "Open Library dump date: $OL_DATE"
BASE_URL="https://archive.org/download/ol_dump_${OL_DATE}"

for name in authors works editions; do
  DEST="$UNPROCESSED/ol_dump_${name}_latest.txt.gz"
  if [ -f "$DEST" ] && [ "$(stat -c%s "$DEST")" -gt 1000000 ]; then
    log "Already downloaded: $name ($(du -sh "$DEST" | cut -f1))"
  else
    log "Downloading $name dump..."
    wget -q --show-progress \
      "${BASE_URL}/ol_dump_${name}_${OL_DATE}.txt.gz" \
      -O "$DEST"
    log "Done: $name"
  fi
done

# --- Step 2: Decompress ---
log "Decompressing dumps..."
for name in authors works editions; do
  TXT="$UNPROCESSED/ol_dump_${name}.txt"
  GZ="$UNPROCESSED/ol_dump_${name}_latest.txt.gz"
  if [ -f "$TXT" ]; then
    log "Already decompressed: $name"
  else
    log "Decompressing $name (~may take 10-20 min)..."
    gunzip -c "$GZ" > "$TXT"
    log "Done: $name ($(du -sh "$TXT" | cut -f1))"
  fi
done

# --- Step 3: Chunk into CSVs ---
log "Chunking into CSV files (may take 30-60 min)..."
cd "$OL_SEARCH_DIR"
python3 openlibrary_data_process.py
log "CSV chunking complete. Files in $PROCESSED:"
ls -lh "$PROCESSED/"

# --- Step 4: Set up PostgreSQL schema ---
log "Setting up PostgreSQL schema..."

docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -c "
  CREATE EXTENSION IF NOT EXISTS pg_trgm;
  SET client_encoding = 'UTF8';

  CREATE TABLE IF NOT EXISTS authors (
    type text, key text NOT NULL, revision integer,
    last_modified date, data jsonb,
    CONSTRAINT pk_author_key PRIMARY KEY (key)
  );
  CREATE TABLE IF NOT EXISTS works (
    type text, key text NOT NULL, revision integer,
    last_modified date, data jsonb,
    CONSTRAINT pk_work_key PRIMARY KEY (key)
  );
  CREATE TABLE IF NOT EXISTS author_works (author_key text, work_key text);
  CREATE TABLE IF NOT EXISTS editions (
    type text, key text NOT NULL, revision integer,
    last_modified date, data jsonb, work_key text,
    CONSTRAINT pk_edition_key PRIMARY KEY (key)
  );
  CREATE TABLE IF NOT EXISTS edition_isbns (edition_key text, isbn text);

  -- Mapping tables
  CREATE TABLE IF NOT EXISTS store (key TEXT PRIMARY KEY, value JSONB);
  CREATE TABLE IF NOT EXISTS ratings (work_key TEXT, edition_key TEXT, rating INTEGER, date DATE);
  CREATE TABLE IF NOT EXISTS goodreads_authors (id INTEGER, ol TEXT);
  CREATE TABLE IF NOT EXISTS goodreads_editions (id INTEGER, ol TEXT);
  CREATE TABLE IF NOT EXISTS goodreads_series (work_id INTEGER, series_id INTEGER, position INTEGER, title TEXT);
  CREATE TABLE IF NOT EXISTS goodreads_works (edition_id INTEGER, work_id INTEGER, work_ol TEXT);
" 2>&1 | grep -v "^$"
log "Schema ready"

# --- Step 5: Copy data into container and load ---
log "Copying processed data into container (may take a few minutes)..."
docker cp "$OL_SEARCH_DIR/." "$PG_CONTAINER:/tmp/openlibrary-search/"
log "Copy complete"

_psql() { docker exec -w /tmp/openlibrary-search "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" "$@"; }
_psql_raw() { docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" "$@"; }

load_table() {
  local table=$1 pattern=$2
  log "Loading $table..."
  _psql_raw -c "ALTER TABLE $table SET UNLOGGED;"
  docker exec -w /tmp/openlibrary-search "$PG_CONTAINER" bash -c "
    for csv in $pattern; do
      echo \"  \$csv\"
      psql -U $PG_USER -d $PG_DB -c \"\\\copy $table FROM '\$csv' DELIMITER E'\t' QUOTE '|' CSV;\"
    done
  "
  _psql_raw -c "ALTER TABLE $table SET LOGGED;"
  log "$table loaded"
}

load_table authors   "data/processed/authors_*.csv"
log "Creating author indexes..."
_psql -f db_scripts/tbl_authors_indexes.sql

load_table works     "data/processed/works_*.csv"
log "Creating works indexes..."
_psql -f db_scripts/tbl_works_indexes.sql

log "Building author_works..."
_psql_raw -c "
  ALTER TABLE author_works SET UNLOGGED;
  INSERT INTO author_works (author_key, work_key)
  SELECT DISTINCT
    jsonb_array_elements(data->'authors')->'author'->>'key',
    key
  FROM works
  WHERE key IS NOT NULL AND data->'authors'->0->'author' IS NOT NULL;
  ALTER TABLE author_works SET LOGGED;
"
_psql -f db_scripts/tbl_author_works_indexes.sql

load_table editions  "data/processed/editions_*.csv"
log "Setting work_key on editions..."
_psql_raw -c "UPDATE editions SET work_key = data->'works'->0->>'key';"
log "Creating editions indexes..."
_psql -f db_scripts/tbl_editions_indexes.sql

log "Building edition_isbns..."
_psql_raw -c "
  ALTER TABLE edition_isbns SET UNLOGGED;
  INSERT INTO edition_isbns (edition_key, isbn)
  SELECT DISTINCT edition_key, isbn FROM (
    SELECT key, jsonb_array_elements_text(data->'isbn_13') FROM editions
      WHERE jsonb_array_length(data->'isbn_13') > 0 AND key IS NOT NULL
    UNION ALL
    SELECT key, jsonb_array_elements_text(data->'isbn_10') FROM editions
      WHERE jsonb_array_length(data->'isbn_10') > 0 AND key IS NOT NULL
    UNION ALL
    SELECT key, jsonb_array_elements_text(data->'isbn') FROM editions
      WHERE jsonb_array_length(data->'isbn') > 0 AND key IS NOT NULL
  ) t(edition_key, isbn);
  ALTER TABLE edition_isbns SET LOGGED;
"
_psql -f db_scripts/tbl_edition_isbns_indexes.sql

log "VACUUM ANALYZE (reclaiming space)..."
_psql_raw -c "VACUUM ANALYZE;"
log "OpenLibrary data load complete"

# --- Step 6: Load mapping CSVs ---
log "Loading santarrsgrotto/mapping data..."
docker cp "$MAPPING_DIR/." "$PG_CONTAINER:/tmp/mapping/"

docker exec -w /tmp/mapping "$PG_CONTAINER" bash -c "
  psql -U $PG_USER -d $PG_DB -c 'TRUNCATE goodreads_authors, goodreads_editions, goodreads_works, goodreads_series, ratings;'

  echo 'Loading goodreads_authors...'
  psql -U $PG_USER -d $PG_DB -c \"\\\copy goodreads_authors (id, ol) FROM 'goodreads_authors.csv' WITH (FORMAT csv, HEADER true);\"

  echo 'Loading goodreads_editions...'
  psql -U $PG_USER -d $PG_DB -c \"\\\copy goodreads_editions (id, ol) FROM 'goodreads_editions.csv' WITH (FORMAT csv, HEADER true);\"

  echo 'Loading goodreads_works...'
  psql -U $PG_USER -d $PG_DB -c \"\\\copy goodreads_works (edition_id, work_id, work_ol) FROM 'goodreads_works.csv' WITH (FORMAT csv, HEADER true);\"

  echo 'Loading goodreads_series...'
  psql -U $PG_USER -d $PG_DB -c \"\\\copy goodreads_series (work_id, series_id, position, title) FROM 'goodreads_series.csv' WITH (FORMAT csv, HEADER true, FORCE_NULL (position));\"

  echo 'Loading ratings...'
  psql -U $PG_USER -d $PG_DB -c \"\\\copy ratings FROM 'ol_ratings.csv' WITH (FORMAT csv);\"
"
docker exec -w /tmp/mapping "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -f goodreads_indexes.sql
log "Mapping data loaded"

# --- Done ---
log "=== All done! ==="
docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -c "
  SELECT table_name, COUNT(*)::text AS rows FROM (
    SELECT 'authors' AS table_name FROM authors UNION ALL
    SELECT 'works' FROM works UNION ALL
    SELECT 'editions' FROM editions UNION ALL
    SELECT 'edition_isbns' FROM edition_isbns UNION ALL
    SELECT 'goodreads_authors' FROM goodreads_authors UNION ALL
    SELECT 'goodreads_works' FROM goodreads_works
  ) t GROUP BY table_name ORDER BY table_name;
"
log "Readarr metadata server is ready. Restart readarr-server if it was already running."
