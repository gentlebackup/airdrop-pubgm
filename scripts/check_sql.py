from pathlib import Path
from pglast import parse_sql

files = sorted(Path("supabase").rglob("*.sql"))
if not files:
    raise SystemExit("No SQL files found under supabase/")

failed = []
for path in files:
    try:
        parse_sql(path.read_text(encoding="utf-8"))
        print(f"PASS {path}")
    except Exception as exc:
        failed.append((path, exc))
        print(f"FAIL {path}: {exc}")

if failed:
    raise SystemExit(f"{len(failed)} SQL file(s) failed PostgreSQL parsing.")
print(f"Parsed {len(files)} SQL files successfully.")
