-- Smart Compras: alertas no celular com o painel fechado (Web Push)
-- Rodar UMA vez no SQL Editor. Funciona em conjunto com a Edge Function "sc-push" (supabase/functions/sc-push/index.ts).

create extension if not exists pg_net;

create table if not exists public.sc_config (
  k text primary key,
  v text not null
);
alter table public.sc_config enable row level security;
revoke all on public.sc_config from anon, authenticated;
-- segredo que só o banco e a função conhecem (o gatilho manda, a função confere)
insert into public.sc_config(k, v) values ('segredo', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (k) do nothing;

create table if not exists public.sc_push (
  id uuid primary key default gen_random_uuid(),
  comprador_id uuid not null references public.sc_compradores(id) on delete cascade,
  endpoint text not null unique,
  sub jsonb not null,
  criado_em timestamptz not null default now()
);
create index if not exists sc_push_comprador_idx on public.sc_push(comprador_id);
alter table public.sc_push enable row level security;
revoke all on public.sc_push from anon, authenticated;

-- o app salva a inscrição do aparelho do comprador
create or replace function public.sc_salvar_push(p_chave text, p_sub jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid; ep text;
begin
  v := sc__comprador(p_chave);
  ep := p_sub->>'endpoint';
  if ep is null or ep !~ '^https://' or p_sub->'keys'->>'p256dh' is null or p_sub->'keys'->>'auth' is null then
    raise exception 'Inscrição inválida.';
  end if;
  insert into sc_push(comprador_id, endpoint, sub) values (v, left(ep, 1000), p_sub)
  on conflict (endpoint) do update set comprador_id = excluded.comprador_id, sub = excluded.sub, criado_em = now();
end $$;

create or replace function public.sc_remover_push(p_chave text, p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  v := sc__comprador(p_chave);
  delete from sc_push where endpoint = p_endpoint and comprador_id = v;
end $$;

-- a cada alerta novo, chama a função que envia a notificação (nunca bloqueia o envio da lista)
create or replace function public.sc__alerta_push() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists(select 1 from sc_push where comprador_id = new.comprador_id) then
    begin
      perform net.http_post(
        url := 'https://ivqrabkzdzcgtqkhdrlx.supabase.co/functions/v1/sc-push',
        body := jsonb_build_object('alerta_id', new.id, 'segredo', (select v from sc_config where k = 'segredo')),
        headers := '{"Content-Type": "application/json"}'::jsonb
      );
    exception when others then null;
    end;
  end if;
  return new;
end $$;

drop trigger if exists sc_alertas_push on public.sc_alertas;
create trigger sc_alertas_push after insert on public.sc_alertas
  for each row execute function public.sc__alerta_push();

revoke execute on function public.sc__alerta_push() from public, anon, authenticated;
revoke execute on function public.sc_salvar_push(text,jsonb), public.sc_remover_push(text,text) from public;
grant execute on function public.sc_salvar_push(text,jsonb), public.sc_remover_push(text,text) to anon, authenticated;
