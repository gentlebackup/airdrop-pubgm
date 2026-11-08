#!/usr/bin/env python3
"""Check that static PostgREST table/RPC references in the app exist in the fresh-project SQL."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "app"
SETUP = ROOT / "supabase" / "AIRDROP-PUBGM-SETUP.sql"

if not APP.is_dir() or not SETUP.is_file():
    print("App directory or consolidated SQL setup file is missing.")
    sys.exit(1)

source_files = [
    path for path in APP.rglob("*")
    if path.is_file() and path.suffix in {".js", ".jsx", ".ts", ".tsx"}
]
app_source = "\n".join(path.read_text(encoding="utf-8") for path in source_files)
sql_source = SETUP.read_text(encoding="utf-8")

app_tables = set(re.findall(r"""['"`]\/rest\/v1\/([a-zA-Z_][a-zA-Z0-9_]*)(?=[/?'`])""", app_source))
app_tables.discard("rpc")
app_functions = set(re.findall(r"""\brpc\(\s*['"]([a-zA-Z_][a-zA-Z0-9_]*)['"]""", app_source))
app_functions.update(re.findall(r"""['"`]\/rest\/v1\/rpc\/([a-zA-Z_][a-zA-Z0-9_]*)(?=[/?'`])""", app_source))

sql_tables = set(re.findall(
    r"""\bcreate\s+table\s+(?:if\s+not\s+exists\s+)?public\.([a-zA-Z_][a-zA-Z0-9_]*)""",
    sql_source, re.IGNORECASE
))
sql_functions = set(re.findall(
    r"""\bcreate\s+(?:or\s+replace\s+)?function\s+public\.([a-zA-Z_][a-zA-Z0-9_]*)\s*\(""",
    sql_source, re.IGNORECASE
))

missing_tables = sorted(app_tables - sql_tables)
missing_functions = sorted(app_functions - sql_functions)

print(f"Scanned {len(source_files)} app source files.")
print(f"Found {len(app_tables)} distinct REST table references and {len(app_functions)} RPC references.")
print(f"Consolidated SQL defines {len(sql_tables)} tables and {len(sql_functions)} functions.")

if missing_tables or missing_functions:
    if missing_tables:
        print("REST tables missing from consolidated SQL: " + ", ".join(missing_tables))
    if missing_functions:
        print("RPC functions missing from consolidated SQL: " + ", ".join(missing_functions))
    sys.exit(1)

print("AIRDROP PUBGM app-to-database contract check passed.")
