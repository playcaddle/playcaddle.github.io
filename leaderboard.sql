-- Caddle leaderboard setup.
-- Run this once in Supabase: SQL Editor > New query > paste > Run.
-- Players can't touch the table directly. The page can only call the
-- three functions below, and the server does all the timing.

create table if not exists public.attempts (
  id          bigint generated always as identity primary key,
  puzzle      int         not null,
  player      uuid        not null,
  name        text        not null default 'Anonymous' check (char_length(name) between 1 and 20),
  software    text        not null default 'Other' check (software in ('Onshape','Fusion','SOLIDWORKS','Other')),
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  tries       int,
  solved      boolean     not null default false,
  gave_up     boolean     not null default false,
  unique (puzzle, player)            -- one run per player per puzzle
);

alter table public.attempts enable row level security;   -- no policies = no direct access
revoke all on table public.attempts from anon, authenticated;

-- Puzzle #1 is 2026-09-01. Only today's puzzle (±1 day for time zones) can be started.
create or replace function public.start_attempt(p_puzzle int, p_player uuid, p_name text, p_software text)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  today int := (current_date - date '2026-09-01') + 1;
  ts timestamptz;
begin
  if p_puzzle < today - 1 or p_puzzle > today + 1 then
    raise exception 'Only today''s puzzle can be ranked';
  end if;
  insert into attempts (puzzle, player, name, software)
  values (
    p_puzzle, p_player,
    left(coalesce(nullif(btrim(p_name), ''), 'Anonymous'), 20),
    case when p_software in ('Onshape','Fusion','SOLIDWORKS') then p_software else 'Other' end
  )
  on conflict (puzzle, player) do nothing;          -- a refresh can't restart the clock
  select started_at into ts from attempts where puzzle = p_puzzle and player = p_player;
  return ts;
end $$;

create or replace function public.finish_attempt(p_puzzle int, p_player uuid, p_tries int, p_solved boolean, p_gave_up boolean, p_software text)
returns int
language plpgsql security definer set search_path = public as $$
declare secs int;
begin
  update attempts set
    finished_at = now(),
    tries       = greatest(1, least(5, coalesce(p_tries, 5))),
    gave_up     = coalesce(p_gave_up, false),
    -- a solve under 20 seconds isn't humanly possible, so it isn't ranked
    solved      = coalesce(p_solved, false) and not coalesce(p_gave_up, false)
                  and now() - started_at >= interval '20 seconds',
    software    = case when p_software in ('Onshape','Fusion','SOLIDWORKS') then p_software else 'Other' end
  where puzzle = p_puzzle and player = p_player and finished_at is null;   -- can only finish once
  select extract(epoch from finished_at - started_at)::int into secs
  from attempts where puzzle = p_puzzle and player = p_player;
  return secs;
end $$;

-- Top 25 plus your own row. Player IDs are never returned.
create or replace function public.get_board(p_puzzle int, p_player uuid default null)
returns table (rank bigint, name text, software text, seconds int, tries int, is_me boolean, total bigint)
language sql stable security definer set search_path = public as $$
  with s as (
    select a.name, a.software, a.tries, a.player,
           extract(epoch from a.finished_at - a.started_at)::int as secs,
           rank()   over (order by a.finished_at - a.started_at, a.tries) as rk,
           count(*) over () as tot
    from attempts a
    where a.puzzle = p_puzzle and a.solved
  )
  select rk, s.name, s.software, secs, s.tries, (s.player = p_player), tot
  from s
  where rk <= 25 or s.player = p_player
  order by rk;
$$;

revoke execute on function public.start_attempt(int, uuid, text, text) from public;
revoke execute on function public.finish_attempt(int, uuid, int, boolean, boolean, text) from public;
revoke execute on function public.get_board(int, uuid) from public;
grant  execute on function public.start_attempt(int, uuid, text, text) to anon, authenticated;
grant  execute on function public.finish_attempt(int, uuid, int, boolean, boolean, text) to anon, authenticated;
grant  execute on function public.get_board(int, uuid) to anon, authenticated;
