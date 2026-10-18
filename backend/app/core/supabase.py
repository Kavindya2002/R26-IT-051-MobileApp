"""
app/core/supabase.py — Supabase client instances.

Two clients are exposed:
  - supabase_client : uses the publishable key (respects RLS,
                       safe for anything acting "as the user").
  - supabase_admin  : uses the secret key (bypasses RLS — only
                       used server-side for admin operations such
                       as creating auth users).
"""

from supabase import create_client, Client

from app.core.config import (
    SUPABASE_URL,
    SUPABASE_PUBLISHABLE_KEY,
    SUPABASE_SECRET_KEY,
)

supabase_client: Client = create_client(
    SUPABASE_URL,
    SUPABASE_PUBLISHABLE_KEY,
)

supabase_admin: Client = create_client(
    SUPABASE_URL,
    SUPABASE_SECRET_KEY,
)
