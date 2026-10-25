# -*- coding: utf-8 -*-
"""
Helper for safely executing a postgrest query builder, converting an
RLS-denied INSERT/UPDATE/DELETE into a clean HTTPException instead of
letting it crash through as an unhandled 500.

BACKGROUND (found via real phone/site testing): postgrest-py raises an
APIError exception directly when a write is rejected by a row-level
security policy - it does NOT return an empty .data the way a SELECT
with no matching rows does. Code across this backend had repeatedly
written `if not result.data: raise HTTPException(403, ...)` assuming
the empty-data case, which can never run for a write, since the
exception happens first and crashes the whole request as an unhandled
500. In the browser this looks like a CORS failure (no CORS headers
get attached to a response that crashed before the middleware could
run), making it doubly confusing to diagnose from the client side.

This was confirmed against a REAL case: a non-Coordinator submitting
Master Roll crashed with exactly this signature.
"""
from fastapi import HTTPException
from postgrest.exceptions import APIError


def safe_execute(query, *, on_denied: str = "You are not permitted to perform this action."):
    """
    Wraps query.execute(), turning an RLS-denial (Postgres error code
    42501) into a clean 403 with the given message. Other database
    errors are re-raised as a 500 with the original detail, rather than
    silently relabeled as a permissions issue they may not actually be -
    only the specific, confirmed RLS-violation code gets the friendly
    403 treatment.
    """
    try:
        return query.execute()
    except APIError as e:
        if e.code == "42501":
            raise HTTPException(status_code=403, detail=on_denied)
        raise HTTPException(status_code=500, detail=f"Database error: {e.message}")


def execute_with_rules(query, *, on_denied: str):
    """
    Like safe_execute, but a rule raised by a database trigger or function
    (P0001, e.g. "Receiving 81 bag would exceed the 200 bag ordered") or a
    constraint violation (23xxx) is the user's mistake, so it comes back as
    a 400 carrying the database's own message.
    """
    try:
        return query.execute()
    except APIError as e:
        if e.code == "42501":
            raise HTTPException(status_code=403, detail=on_denied)
        if e.code == "P0001" or (e.code or "").startswith("23"):
            raise HTTPException(status_code=400, detail=e.message)
        raise HTTPException(status_code=500, detail=f"Database error: {e.message}")


def insert_once(client, table: str, data: dict, *, on_denied: str) -> dict:
    """
    Inserts one row, unless a row with the same client_ref already exists
    (a submission saved offline on a phone and sent twice), in which case
    that existing row is returned instead. Without a client_ref this is a
    plain insert.
    """
    ref = data.get("client_ref")
    if ref:
        existing = client.table(table).select("*").eq("client_ref", ref).execute().data
        if existing:
            return existing[0]
    try:
        result = client.table(table).insert(data).execute()
    except APIError as e:
        if e.code == "23505" and ref and "client_ref" in (e.message or ""):
            return client.table(table).select("*").eq("client_ref", ref).execute().data[0]
        if e.code == "42501":
            raise HTTPException(status_code=403, detail=on_denied)
        raise HTTPException(status_code=500, detail=f"Database error: {e.message}")
    if not result.data:
        raise HTTPException(status_code=403, detail=on_denied)
    return result.data[0]
