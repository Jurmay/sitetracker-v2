# Supabase

Database schema and edge functions for SiteTracker v2.

Live project: `construction-tracker` (ref `jkrufgvevngifqkbrpja`).

## Layout

- `migrations/20260626000000_baseline_schema.sql`: the full schema as it
  was live on 2026-10-24: tables, constraints, indexes, functions, views,
  triggers, RLS policies, storage buckets and policies, report
  definitions, and pg_cron jobs. Earlier migrations (001-007) were run by
  hand in the SQL editor and never committed; this file replaces them.
- `functions/send-notification/`: emails coordinators via Resend. Called
  every 5 minutes by `fn_dispatch_pending_notifications()`.

New changes go in a new, later-dated file in `migrations/`. Don't edit
the baseline.

## Setting up a new project from scratch

1. Create a Supabase project and link it: `supabase link --project-ref <ref>`.
2. Apply the schema: `supabase db push`.
3. Deploy the email function with JWT checks off (it checks the `apikey`
   header itself):
   `supabase functions deploy send-notification --no-verify-jwt`
4. Set the function's secrets:
   `supabase secrets set RESEND_API_KEY=... ACCOUNTS_EMAIL_FROM=...`
5. Add two Vault secrets in the SQL editor (the dispatcher reads them):

   ```sql
   select vault.create_secret('https://<ref>.supabase.co/functions/v1', 'edge_function_base_url');
   select vault.create_secret('<secret key>', 'service_role_key');
   ```

   The `service_role_key` value must match the key the function compares
   the `apikey` header against (`SUPABASE_SECRET_KEYS.default`), or every
   email is rejected.

## Marking the live project as already migrated

The live project already has this schema, so don't run the baseline
against it. Record it as applied instead:

```
supabase migration repair --status applied 20260626000000
```
