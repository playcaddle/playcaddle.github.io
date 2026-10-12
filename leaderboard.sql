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

revoke execute on function public.finish_attempt(int, uuid, int, boolean, boolean, text) from public;
revoke execute on function public.get_board(int, uuid) from public;
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

-- 1) Bell-curve data: every solve time for a puzzle (seconds). No names or IDs.
create or replace function public.get_times(p_puzzle int)
returns int[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(extract(epoch from finished_at - started_at)::int
                            order by finished_at - started_at), '{}')
  from attempts where puzzle = p_puzzle and solved;
$$;
revoke execute on function public.get_times(int) from public;
grant  execute on function public.get_times(int) to anon, authenticated;

-- 2) Hard puzzles use ID = day + 10000, so today's Hard puzzle can be ranked too.
create or replace function public.start_attempt(p_puzzle int, p_player uuid, p_name text, p_software text)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  today int := (current_date - date '2026-09-01') + 1;
  day_no int := p_puzzle % 10000;
  ts timestamptz;
begin
  if p_puzzle not between 1 and 19999 or day_no < today - 1 or day_no > today + 1 then
    raise exception 'Only today''s puzzle can be ranked';
  end if;
  insert into attempts (puzzle, player, name, software)
  values (
    p_puzzle, p_player,
    public.clean_name(p_name),
    case when p_software in ('Onshape','Fusion','SOLIDWORKS') then p_software else 'Other' end
  )
  on conflict (puzzle, player) do nothing;
  select started_at into ts from attempts where puzzle = p_puzzle and player = p_player;
  return ts;
end $$;

-- 3) Your stats page, now split into Easy and Hard:   select * from daily_stats;
drop view if exists public.daily_stats;
create view public.daily_stats with (security_invoker = true) as
with a as (
  select date '2026-09-01' + (puzzle % 10000 - 1) as day,
         case when puzzle >= 10000 then 'hard' else 'easy' end as diff,
         count(*) as started,
         count(*) filter (where solved) as solved,
         to_char(min(finished_at - started_at) filter (where solved), 'MI:SS') as fastest
  from attempts group by 1, 2
)
select d.day,
       coalesce(v.visitors, 0)  as visitors,
       coalesce(e.started, 0)   as easy_played,
       coalesce(e.solved, 0)    as easy_solved,
       e.fastest                as easy_fastest,
       coalesce(h.started, 0)   as hard_played,
       coalesce(h.solved, 0)    as hard_solved,
       h.fastest                as hard_fastest
from (select generate_series(date '2026-09-01', current_date, '1 day')::date as day) d
left join (select day, count(*) as visitors from visits group by day) v using (day)
left join a e on e.day = d.day and e.diff = 'easy'
left join a h on h.day = d.day and h.diff = 'hard'
order by d.day desc;
revoke all on public.daily_stats from anon, authenticated;
revoke execute on function public.start_attempt(int, uuid, text, text) from public;
grant  execute on function public.start_attempt(int, uuid, text, text) to anon, authenticated;

-- ===== Usage tracking: every play counts, not just ranked runs =====
-- Anonymous: a random device ID only. No names, emails, or IP addresses.

create table if not exists public.events (
  id     bigint generated always as identity primary key,
  at     timestamptz not null default now(),
  player uuid not null,
  kind   text not null check (kind in ('session','practice_start','practice_finish','practice_solve','share','learn')),
  ref    text check (char_length(ref) <= 24),
  secs   int  check (secs between 0 and 86400)
);
create index if not exists events_player_at on public.events (player, at);
create index if not exists events_kind on public.events (kind);
alter table public.events enable row level security;
revoke all on table public.events from anon, authenticated;

create or replace function public.log_event(p_player uuid, p_kind text, p_ref text default null, p_secs int default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_kind not in ('session','practice_start','practice_finish','practice_solve','share','learn') then return; end if;
  -- flood guard: one device can't log more than 300 events a day
  if (select count(*) from events where player = p_player and at > now() - interval '1 day') >= 300 then return; end if;
  insert into events (player, kind, ref, secs)
  values (p_player, p_kind, left(p_ref, 24), case when p_secs between 0 and 86400 then p_secs end);
end $$;

-- Real totals for the on-site counter: everyone who has used the site, every finished and solved puzzle
create or replace function public.get_public_stats()
returns table (players bigint, played bigint, solved bigint)
language sql stable security definer set search_path = public as $$
  select
    (select count(distinct p) from (select player as p from visits union select player from attempts union select player from events) u),
    (select count(*) from attempts where finished_at is not null) + (select count(*) from events where kind = 'practice_finish'),
    (select count(*) from attempts where solved) + (select count(*) from events where kind = 'practice_solve');
$$;

revoke execute on function public.log_event(uuid, text, text, int) from public;
revoke execute on function public.get_public_stats() from public;
grant  execute on function public.log_event(uuid, text, text, int) to anon, authenticated;
grant  execute on function public.get_public_stats() to anon, authenticated;

-- Your headline numbers:   select * from usage_summary;
-- Modeling time counts each run up to 2 hours, so a tab left open overnight doesn't pad it.
create or replace view public.usage_summary with (security_invoker = true) as
select
  (select count(distinct p) from (select player as p from visits union select player from attempts union select player from events) u) as unique_players,
  (select count(*) from visits)                                                          as daily_visits,
  (select count(*) from events where kind = 'session')                                   as sessions,
  (select count(*) from attempts) + (select count(*) from events where kind = 'practice_start')                          as puzzles_started,
  (select count(*) from attempts where finished_at is not null) + (select count(*) from events where kind = 'practice_finish') as puzzles_finished,
  (select count(*) from attempts where solved) + (select count(*) from events where kind = 'practice_solve')            as puzzles_solved,
  (select count(*) from attempts where solved)                                           as ranked_solves,
  round(((select coalesce(sum(least(extract(epoch from finished_at - started_at), 7200)), 0) from attempts where finished_at is not null)
       + (select coalesce(sum(least(secs, 7200)), 0) from events where kind = 'practice_finish')) / 3600.0, 1) as hours_of_modeling,
  (select count(*) from events where kind = 'share')                                     as results_shared,
  (select count(*) from events where kind = 'learn')                                     as learn_page_visits,
  (select min(day) from visits)                                                          as first_day;
revoke all on public.usage_summary from anon, authenticated;

-- Day by day, everything included:   select * from usage_by_day;
create or replace view public.usage_by_day with (security_invoker = true) as
select d.day,
       (select count(distinct p) from (select player as p from visits where day = d.day
                                       union select player from events where at::date = d.day
                                       union select player from attempts where started_at::date = d.day) u) as active_players,
       (select count(*) from events where kind = 'session' and at::date = d.day) as sessions,
       (select count(*) from attempts where started_at::date = d.day and finished_at is not null)
         + (select count(*) from events where kind = 'practice_finish' and at::date = d.day) as puzzles_finished,
       (select count(*) from attempts where started_at::date = d.day and solved)
         + (select count(*) from events where kind = 'practice_solve' and at::date = d.day) as puzzles_solved
from (select generate_series(date '2026-09-01', current_date, '1 day')::date as day) d
order by d.day desc;
revoke all on public.usage_by_day from anon, authenticated;

-- ===== Completions and unique visitors by period (Pacific time) =====
-- select * from usage_periods;   -> Today / This week / This month / This year / All time
-- select * from usage_history;   -> every day, week, month, and year so far
create or replace view public.usage_activity with (security_invoker = true) as
  select player, day as d from visits
  union all select player, (at at time zone 'America/Los_Angeles')::date from events
  union all select player, (started_at at time zone 'America/Los_Angeles')::date from attempts;

create or replace view public.usage_periods with (security_invoker = true) as
with t as (select (now() at time zone 'America/Los_Angeles')::date as today),
p(sort, period, since) as (
  select 1, 'Today',      today                              from t union all
  select 2, 'This week',  date_trunc('week',  today)::date   from t union all
  select 3, 'This month', date_trunc('month', today)::date   from t union all
  select 4, 'This year',  date_trunc('year',  today)::date   from t union all
  select 5, 'All time',   date '2026-09-01'                  from t
)
select p.period, p.since,
  (select count(*) from attempts where finished_at is not null and (finished_at at time zone 'America/Los_Angeles')::date >= p.since)
  + (select count(*) from events where kind = 'practice_finish' and (at at time zone 'America/Los_Angeles')::date >= p.since) as completions,
  (select count(*) from attempts where solved and (finished_at at time zone 'America/Los_Angeles')::date >= p.since)
  + (select count(*) from events where kind = 'practice_solve' and (at at time zone 'America/Los_Angeles')::date >= p.since) as solves,
  (select count(distinct player) from usage_activity a where a.d >= p.since) as unique_visitors
from p order by p.sort;

create or replace view public.usage_history with (security_invoker = true) as
with fin as (
  select (finished_at at time zone 'America/Los_Angeles')::date as d, solved from attempts where finished_at is not null
  union all select (at at time zone 'America/Los_Angeles')::date, false from events where kind = 'practice_finish'
), sol as (
  select (finished_at at time zone 'America/Los_Angeles')::date as d from attempts where solved
  union all select (at at time zone 'America/Los_Angeles')::date from events where kind = 'practice_solve'
), g(grain, ord, unit) as (values ('day',1,'day'),('week',2,'week'),('month',3,'month'),('year',4,'year'))
select g.grain, s.start,
  (select count(*) from fin where date_trunc(g.unit, fin.d)::date = s.start) as completions,
  (select count(*) from sol where date_trunc(g.unit, sol.d)::date = s.start) as solves,
  (select count(distinct player) from usage_activity a where date_trunc(g.unit, a.d)::date = s.start) as unique_visitors
from g
cross join lateral (select distinct date_trunc(g.unit, d)::date as start from usage_activity) s
order by g.ord, s.start desc;

revoke all on public.usage_activity, public.usage_periods, public.usage_history from anon, authenticated;

-- ===== Every play, broken down by mode and result (Pacific time) =====
-- select * from play_totals;                       -> all time, one row per mode + ALL
-- select * from play_stats where day = current_date; -> one day, one row per mode + ALL
-- select * from play_stats;                         -> every day

-- One row per puzzle run: ranked daily runs + every practice/unlimited run
create or replace view public.play_log with (security_invoker = true) as
select (a.started_at at time zone 'America/Los_Angeles')::date as day,
       case when a.puzzle >= 10000 then 'Daily Hard (ranked)' else 'Daily Easy (ranked)' end as mode,
       case when a.finished_at is null then 'unfinished'
            when a.solved then 'solved'
            when a.gave_up then 'gave up'
            when a.finished_at - a.started_at < interval '20 seconds' then 'disqualified'
            else 'out of tries' end as result,
       a.player,
       a.started_at as at
from attempts a
union all
select (s.at at time zone 'America/Los_Angeles')::date,
       case left(s.ref, 1) when 'd' then 'Daily ' else 'Unlimited ' end
         || case substr(s.ref, 2, 1) when 'h' then 'Hard' else 'Easy' end
         || case left(s.ref, 1) when 'd' then ' (unranked)' else '' end,
       case when exists (select 1 from events f where f.kind = 'practice_solve'  and f.player = s.player and f.ref = s.ref and f.at >= s.at) then 'solved'
            when exists (select 1 from events f where f.kind = 'practice_finish' and f.player = s.player and f.ref = s.ref and f.at >= s.at) then 'not solved'
            else 'unfinished' end,
       s.player,
       s.at
from events s
where s.kind = 'practice_start';

-- Per day and mode, plus an ALL row for each day
create or replace view public.play_stats with (security_invoker = true) as
select day,
       coalesce(mode, 'ALL') as mode,
       count(*)                                                        as attempts,
       count(*) filter (where result = 'solved')                       as solved,
       count(*) filter (where result in ('gave up','out of tries','not solved','disqualified')) as not_solved,
       count(*) filter (where result = 'unfinished')                   as unfinished,
       count(distinct player)                                          as players
from play_log
group by grouping sets ((day, mode), (day))
order by day desc, (mode is null), mode;

-- All time, per mode, plus ALL
create or replace view public.play_totals with (security_invoker = true) as
select coalesce(mode, 'ALL') as mode,
       count(*)                                                        as attempts,
       count(*) filter (where result = 'solved')                       as solved,
       count(*) filter (where result in ('gave up','out of tries','not solved','disqualified')) as not_solved,
       count(*) filter (where result = 'unfinished')                   as unfinished,
       round(100.0 * count(*) filter (where result = 'solved') / nullif(count(*), 0)) as solve_rate_pct,
       count(distinct player)                                          as players
from play_log
group by grouping sets ((mode), ())
order by (mode is null), mode;

revoke all on public.play_log, public.play_stats, public.play_totals from anon, authenticated;
