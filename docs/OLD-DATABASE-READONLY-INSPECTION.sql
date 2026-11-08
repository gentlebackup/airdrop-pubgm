-- AIRDROP PUBGM: read-only inspection of the OLD CODM database.
-- Run ONLY in the old CODM project's Supabase SQL Editor.
-- This query reads metadata only. It does not read player rows or modify anything.
-- It returns one result set so the Supabase SQL Editor's 100-row display limit
-- can be handled by LIMIT/OFFSET if necessary.

WITH enum_types AS (
  SELECT
    'enum'::text AS section,
    t.typname AS object_name,
    NULL::text AS detail_name,
    jsonb_build_object(
      'labels',
      jsonb_agg(e.enumlabel ORDER BY e.enumsortorder)
    ) AS definition
  FROM pg_type t
  JOIN pg_enum e ON e.enumtypid = t.oid
  JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public'
  GROUP BY t.typname
),
constraints AS (
  SELECT
    'constraint'::text AS section,
    c.conrelid::regclass::text AS object_name,
    c.conname AS detail_name,
    jsonb_build_object(
      'type', c.contype,
      'definition', pg_get_constraintdef(c.oid, true)
    ) AS definition
  FROM pg_constraint c
  JOIN pg_class r ON r.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = r.relnamespace
  WHERE n.nspname = 'public'
),
indexes AS (
  SELECT
    'index'::text AS section,
    t.relname AS object_name,
    i.relname AS detail_name,
    jsonb_build_object('definition', pg_get_indexdef(i.oid)) AS definition
  FROM pg_index x
  JOIN pg_class t ON t.oid = x.indrelid
  JOIN pg_class i ON i.oid = x.indexrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public'
),
triggers AS (
  SELECT
    'trigger'::text AS section,
    c.relname AS object_name,
    t.tgname AS detail_name,
    jsonb_build_object(
      'definition', pg_get_triggerdef(t.oid, true),
      'function', t.tgfoid::regprocedure::text,
      'enabled', t.tgenabled
    ) AS definition
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND NOT t.tgisinternal
),
policies AS (
  SELECT
    'policy'::text AS section,
    tablename AS object_name,
    policyname AS detail_name,
    jsonb_build_object(
      'command', cmd,
      'roles', roles,
      'using', qual,
      'with_check', with_check
    ) AS definition
  FROM pg_policies
  WHERE schemaname = 'public'
),
rls AS (
  SELECT
    'rls'::text AS section,
    c.relname AS object_name,
    NULL::text AS detail_name,
    jsonb_build_object(
      'enabled', c.relrowsecurity,
      'forced', c.relforcerowsecurity
    ) AS definition
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind IN ('r', 'p')
)
SELECT section, object_name, detail_name, definition
FROM (
  SELECT * FROM enum_types
  UNION ALL SELECT * FROM constraints
  UNION ALL SELECT * FROM indexes
  UNION ALL SELECT * FROM triggers
  UNION ALL SELECT * FROM policies
  UNION ALL SELECT * FROM rls
) metadata
ORDER BY section, object_name, detail_name NULLS FIRST;
