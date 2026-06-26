# -*- coding: utf-8 -*-
"""
Supabase client wrapper.

Two clients are exposed:
  - get_service_client(): uses the service role key, bypasses RLS entirely.
    Used ONLY for system-level operations (pg_cron-adjacent backend jobs,
    admin user creation via the Auth API) - never for handling a normal
    user's request, since that would defeat the entire RLS design.
  - get_user_client(jwt): uses the anon key + the user's own JWT, so every
    query through it is subject to RLS exactly as that user. This is what
    every authenticated route handler should use.

IMPORTANT - app.current_user_id for audit logging:
The audit trigger (migration 004) reads current_setting('app.current_user_id').
Supabase's supabase-py client goes through PostgREST over HTTP, not a raw
Postgres connection - so we cannot SET LOCAL on the same "connection" PostgREST
uses internally per request. PostgREST instead reads custom claims from the
JWT itself via its built-in `request.jwt.claims` mechanism, which Postgres
RLS policies and triggers CAN read via current_setting('request.jwt.claims').
We therefore standardize on auth.uid() (Postgres-Supabase's helper, used
throughout migration 005) for RLS policies, and the audit trigger has been
written to read auth.uid() directly rather than a custom session variable.
See migrations/004_reporting_system.sql - fn_audit_log_trigger uses auth.uid().
"""
from supabase import create_client, Client
from app.core.config import get_settings

settings = get_settings()


def get_service_client() -> Client:
    """Service-role client. Bypasses RLS. System/admin use only."""
    return create_client(settings.supabase_url, settings.supabase_service_role_key)


def get_user_client(access_token: str) -> Client:
    """
    Anon-key client carrying the user's own access token, so PostgREST
    (and therefore every RLS policy via auth.uid()) sees requests as that
    specific authenticated user - never the service role.
    """
    client = create_client(settings.supabase_url, settings.supabase_anon_key)
    client.postgrest.auth(access_token)
    return client
