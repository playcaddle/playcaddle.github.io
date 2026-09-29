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

-- Leaderboard names: letters and numbers only (1-20), no slurs or inappropriate words.
-- The word lists are base64-encoded so they aren't sitting in plain text.
create or replace function public.name_ok(n text)
returns boolean
language plpgsql immutable set search_path = public as $$
declare
  l  text := lower(coalesce(n, ''));
  m  text := translate(l, '01345789', 'oieastbg');        -- leetspeak: 0=o 1=i 3=e 4=a 5=s 7=t 8=b 9=g
  c  text := regexp_replace(m, '(.)\1+', '\1', 'g');     -- fuuuck -> fuck
  c2 text := regexp_replace(l, '(.)\1+', '\1', 'g');
  s  text := regexp_replace(l, '[0-9]+$', '');             -- name123 -> name
  w  text;
begin
  if coalesce(n, '') !~ '^[A-Za-z0-9]{1,20}$' then return false; end if;
  foreach w in array string_to_array(convert_from(decode('ZnVjayxzaGl0LGJpdGNoLGN1bnQsbmlnZyxuaWdhLGZhZ2dvdCxmYWdnLHJldGFyZCxkaWNraGVhZCxwdXNzeSx3aG9yZSxzbHV0LHJhcGlzdCxwZW5pcyx2YWdpbmEscG9ybixuYXppLGhpdGxlcixraWtlLGNoaW5rLHdldGJhY2ssdHJhbm55LGdvb2ssYmVhbmVyLGtrayxhc3Nob2xlLGJhc3RhcmQsaml6eix0aXR0aWVzLGJvb2IsZGlsZG8saG9ybnksbWlsZixtb2xlc3QscGVkb3BoaWxlLHR3YXQsd2Fuayxib2xsb2NrLGhlaWwsY29ja3N1Y2tlcixtb3RoZXJmLGJsb3dqb2IsaGFuZGpvYixoZW50YWksbnVkZSxvcmdhc20sc2VtZW4sc3Blcm0seHh4LGtpbGx5b3Vyc2VsZixreXM=', 'base64'), 'UTF8'), ',') loop
    if position(w in l) > 0 or position(w in m) > 0 or position(w in c) > 0 or position(w in c2) > 0 then return false; end if;
  end loop;
  foreach w in array string_to_array(convert_from(decode('YXNzLGFzc2VzLGRpY2ssY29jayxmYWcscmFwZSxzZXgsc2V4eSxzcGljLGR5a2UsY29vbixjdW0sdGl0LHRpdHMsYW5hbCxwZWRvLGhvZSxob2VzLG5lZ3JvLHBha2ksbmlnLGphcCxob21vLGxlc2Jv', 'base64'), 'UTF8'), ',') loop
    if w in (l, m, c, c2, s) then return false; end if;
  end loop;
  return true;
end $$;

create or replace function public.clean_name(p text)
returns text
language sql immutable set search_path = public as $$
  select case when public.name_ok(btrim(coalesce(p, ''))) then btrim(p) else 'Anonymous' end;
$$;

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
    public.clean_name(p_name),
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

-- Change your name on every leaderboard you're on.
create or replace function public.set_name(p_player uuid, p_name text)
returns text
language plpgsql security definer set search_path = public as $$
declare n text := btrim(coalesce(p_name, ''));
begin
  if not public.name_ok(n) then
    raise exception 'That name isn''t allowed';
  end if;
  update attempts set name = n where player = p_player;
  return n;
end $$;
revoke execute on function public.set_name(uuid, text) from public;
grant  execute on function public.set_name(uuid, text) to anon, authenticated;

-- Visitor tracking: one row per device per day (anonymous ID only, nothing personal).
create table if not exists public.visits (
  day    date not null default current_date,
  player uuid not null,
  primary key (day, player)
);
alter table public.visits enable row level security;
revoke all on table public.visits from anon, authenticated;

create or replace function public.log_visit(p_player uuid)
returns void
language sql security definer set search_path = public as $$
  insert into visits (player) values (p_player) on conflict do nothing;
$$;

-- How many people finished a puzzle, and how many solved it.
create or replace function public.get_counts(p_puzzle int)
returns table (played bigint, solved bigint)
language sql stable security definer set search_path = public as $$
  select count(*) filter (where finished_at is not null),
         count(*) filter (where solved)
  from attempts where puzzle = p_puzzle;
$$;

revoke execute on function public.log_visit(uuid) from public;
revoke execute on function public.get_counts(int) from public;
grant  execute on function public.log_visit(uuid) to anon, authenticated;
grant  execute on function public.get_counts(int) to anon, authenticated;

-- Your private stats page: run   select * from daily_stats;   in the SQL Editor.
create or replace view public.daily_stats with (security_invoker = true) as
select d.day,
       coalesce(v.visitors, 0) as visitors,
       coalesce(a.started, 0)  as started,
       coalesce(a.finished, 0) as finished,
       coalesce(a.solved, 0)   as solved,
       a.fastest
from (select generate_series(date '2026-09-01', current_date, '1 day')::date as day) d
left join (select day, count(*) as visitors from visits group by day) v using (day)
left join (
  select date '2026-09-01' + (puzzle - 1) as day,
         count(*) as started,
         count(*) filter (where finished_at is not null) as finished,
         count(*) filter (where solved) as solved,
         to_char(min(finished_at - started_at) filter (where solved), 'MI:SS') as fastest
  from attempts group by puzzle
) a using (day)
order by d.day desc;
revoke all on public.daily_stats from anon, authenticated;

-- Every solve time for a puzzle (seconds), for the bell curve. No names or IDs.
create or replace function public.get_times(p_puzzle int)
returns int[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(extract(epoch from finished_at - started_at)::int
                            order by finished_at - started_at), '{}')
  from attempts where puzzle = p_puzzle and solved;
$$;
revoke execute on function public.get_times(int) from public;
grant  execute on function public.get_times(int) to anon, authenticated;
