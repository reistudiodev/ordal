-- A 1,000,000-row table for the Phase 1 scrolling gate.
--   psql "postgres://postgres:ordal@127.0.0.1:55432/postgres" -f scripts/seed-1m.sql
DROP TABLE IF EXISTS public.events_1m;
CREATE TABLE public.events_1m (
    id         bigint PRIMARY KEY,
    user_id    int NOT NULL,
    kind       text NOT NULL,
    amount     numeric(10, 2),
    ok         boolean NOT NULL,
    payload    jsonb,
    created_at timestamptz NOT NULL
);
INSERT INTO public.events_1m
SELECT g,
       (g * 7919) % 50000,
       (ARRAY['signup', 'login', 'purchase', 'refund', 'logout'])[1 + g % 5],
       CASE WHEN g % 5 = 2 THEN round(((g * 37) % 100000) / 100.0, 2) END,
       g % 17 <> 0,
       jsonb_build_object('session', md5(g::text), 'step', g % 12),
       timestamptz '2026-01-01' + (g || ' seconds')::interval
FROM generate_series(1::bigint, 1000000) AS g;
ANALYZE public.events_1m;
