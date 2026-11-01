-- Smart Compras: tabelas (prefixo sc_) + funções RPC
-- Acesso público só via funções SECURITY DEFINER; tabelas com RLS e sem políticas.

create table public.sc_compradores (
  id uuid primary key default gen_random_uuid(),
  usuario text not null unique check (usuario ~ '^[a-z0-9_-]{3,30}$'),
  nome text not null,
  senha_hash text not null,
  chave text not null unique default encode(extensions.gen_random_bytes(24),'hex'),
  criado_em timestamptz not null default now()
);
create table public.sc_listas (
  id uuid primary key default gen_random_uuid(),
  comprador_id uuid not null references public.sc_compradores(id) on delete cascade,
  token text not null unique default encode(extensions.gen_random_bytes(16),'hex'),
  cliente_nome text not null,
  local text not null,
  data_lista date not null,
  telefone text not null,
  observacao text,
  status text not null default 'enviada' check (status in ('enviada','em_compra','finalizada')),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  finalizada_em timestamptz
);
create index sc_listas_comprador_idx on public.sc_listas(comprador_id, criado_em desc);
create table public.sc_itens (
  id uuid primary key default gen_random_uuid(),
  seq bigint generated always as identity,
  lista_id uuid not null references public.sc_listas(id) on delete cascade,
  produto text not null,
  quantidade numeric not null check (quantidade > 0),
  unidade text not null,
  status text not null default 'pendente' check (status in ('pendente','comprado','indisponivel')),
  adicional boolean not null default false,
  criado_em timestamptz not null default now()
);
create index sc_itens_lista_idx on public.sc_itens(lista_id, seq);
create table public.sc_alertas (
  id uuid primary key default gen_random_uuid(),
  comprador_id uuid not null references public.sc_compradores(id) on delete cascade,
  lista_id uuid references public.sc_listas(id) on delete cascade,
  tipo text not null,
  mensagem text not null,
  lido boolean not null default false,
  criado_em timestamptz not null default now()
);
create index sc_alertas_comprador_idx on public.sc_alertas(comprador_id, lido);
create index sc_alertas_lista_idx on public.sc_alertas(lista_id);

alter table public.sc_compradores enable row level security;
alter table public.sc_listas enable row level security;
alter table public.sc_itens enable row level security;
alter table public.sc_alertas enable row level security;
revoke all on public.sc_compradores, public.sc_listas, public.sc_itens, public.sc_alertas from anon, authenticated;

-- ===== helpers internos =====
create or replace function public.sc__comprador(p_chave text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from sc_compradores where chave = p_chave;
  if v is null then raise exception 'Acesso inválido. Entre novamente.'; end if;
  return v;
end $$;

create or replace function public.sc__inserir_itens(p_lista uuid, p_itens jsonb, p_adicional boolean) returns int
language plpgsql security definer set search_path = public as $$
declare it jsonb; n int := 0; q numeric;
begin
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' then raise exception 'Itens inválidos.'; end if;
  if jsonb_array_length(p_itens) > 300 then raise exception 'Máximo de 300 itens por envio.'; end if;
  for it in select * from jsonb_array_elements(p_itens) loop
    if coalesce(trim(it->>'produto'),'') = '' then continue; end if;
    begin q := (it->>'quantidade')::numeric; exception when others then q := 1; end;
    if q is null or q <= 0 then q := 1; end if;
    insert into sc_itens(lista_id, produto, quantidade, unidade, adicional)
    values (p_lista, left(trim(it->>'produto'),200), q,
            left(coalesce(nullif(trim(it->>'unidade'),''),'Unidade'),30), p_adicional);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Adicione pelo menos um item.'; end if;
  return n;
end $$;

create or replace function public.sc__lista_json(p_lista uuid) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'id', l.id, 'token', l.token, 'cliente_nome', l.cliente_nome, 'local', l.local,
    'data_lista', l.data_lista, 'telefone', l.telefone, 'observacao', l.observacao,
    'status', l.status, 'criado_em', l.criado_em, 'finalizada_em', l.finalizada_em,
    'comprador_nome', c.nome,
    'itens', coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'produto',i.produto,'quantidade',i.quantidade,
        'unidade',i.unidade,'status',i.status,'adicional',i.adicional,'criado_em',i.criado_em) order by i.seq)
      from sc_itens i where i.lista_id = l.id), '[]'::jsonb))
  from sc_listas l join sc_compradores c on c.id = l.comprador_id where l.id = p_lista
$$;

-- ===== conta do comprador =====
create or replace function public.sc_criar_comprador(p_usuario text, p_nome text, p_senha text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r sc_compradores;
begin
  if length(coalesce(p_senha,'')) < 4 then raise exception 'A senha precisa ter pelo menos 4 caracteres.'; end if;
  if coalesce(trim(p_nome),'') = '' then raise exception 'Informe seu nome.'; end if;
  if lower(trim(coalesce(p_usuario,''))) !~ '^[a-z0-9_-]{3,30}$' then
    raise exception 'O usuário deve ter de 3 a 30 caracteres: letras minúsculas, números, - ou _.';
  end if;
  if exists(select 1 from sc_compradores where usuario = lower(trim(p_usuario))) then raise exception 'Esse usuário já existe.'; end if;
  insert into sc_compradores(usuario, nome, senha_hash)
  values (lower(trim(p_usuario)), left(trim(p_nome),120), extensions.crypt(p_senha, extensions.gen_salt('bf')))
  returning * into r;
  return jsonb_build_object('usuario', r.usuario, 'nome', r.nome, 'chave', r.chave);
end $$;

create or replace function public.sc_entrar(p_usuario text, p_senha text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r sc_compradores;
begin
  select * into r from sc_compradores where usuario = lower(trim(coalesce(p_usuario,'')));
  if r.id is null or r.senha_hash <> extensions.crypt(coalesce(p_senha,''), r.senha_hash) then
    perform pg_sleep(0.5);
    raise exception 'Usuário ou senha incorretos.';
  end if;
  return jsonb_build_object('usuario', r.usuario, 'nome', r.nome, 'chave', r.chave);
end $$;

-- ===== lado do cliente (link) =====
create or replace function public.sc_info_comprador(p_usuario text) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object('nome', nome, 'usuario', usuario) from sc_compradores where usuario = lower(trim(p_usuario))
$$;

create or replace function public.sc_criar_lista(p_usuario text, p_cliente jsonb, p_itens jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_comp uuid; v_lista sc_listas; n int;
begin
  select id into v_comp from sc_compradores where usuario = lower(trim(p_usuario));
  if v_comp is null then raise exception 'Link inválido.'; end if;
  if coalesce(trim(p_cliente->>'nome'),'') = '' or coalesce(trim(p_cliente->>'local'),'') = ''
     or coalesce(trim(p_cliente->>'telefone'),'') = '' or coalesce(p_cliente->>'data','') = '' then
    raise exception 'Preencha nome, local, data e telefone.';
  end if;
  insert into sc_listas(comprador_id, cliente_nome, local, data_lista, telefone, observacao)
  values (v_comp, left(trim(p_cliente->>'nome'),120), left(trim(p_cliente->>'local'),160), (p_cliente->>'data')::date,
          left(trim(p_cliente->>'telefone'),30), nullif(left(trim(coalesce(p_cliente->>'observacao','')),500),''))
  returning * into v_lista;
  n := sc__inserir_itens(v_lista.id, p_itens, false);
  insert into sc_alertas(comprador_id, lista_id, tipo, mensagem)
  values (v_comp, v_lista.id, 'nova_lista',
          'Nova lista de ' || v_lista.cliente_nome || ' (' || v_lista.local || ') com ' || n || case when n=1 then ' item' else ' itens' end);
  return v_lista.token;
end $$;

create or replace function public.sc_ver_lista(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  select id into v from sc_listas where token = p_token;
  if v is null then raise exception 'Lista não encontrada.'; end if;
  return sc__lista_json(v) - 'id';
end $$;

create or replace function public.sc_adicionar_itens(p_token text, p_itens jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare l sc_listas; n int;
begin
  select * into l from sc_listas where token = p_token;
  if l.id is null then raise exception 'Lista não encontrada.'; end if;
  if l.status = 'finalizada' then raise exception 'Esta lista já foi finalizada pelo comprador. Não é possível adicionar itens.'; end if;
  n := sc__inserir_itens(l.id, p_itens, true);
  update sc_listas set atualizado_em = now() where id = l.id;
  insert into sc_alertas(comprador_id, lista_id, tipo, mensagem)
  values (l.comprador_id, l.id, 'itens_adicionados',
          l.cliente_nome || ' adicionou ' || n || case when n=1 then ' item' else ' itens' end || ' à lista');
  return n;
end $$;

-- ===== lado do comprador =====
create or replace function public.sc_painel(p_chave text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  v := sc__comprador(p_chave);
  return jsonb_build_object(
    'comprador', (select jsonb_build_object('nome',nome,'usuario',usuario) from sc_compradores where id=v),
    'listas', coalesce((select jsonb_agg(x order by x->>'criado_em' desc) from (
        select jsonb_build_object('id',l.id,'token',l.token,'cliente_nome',l.cliente_nome,'local',l.local,'data_lista',l.data_lista,
          'telefone',l.telefone,'status',l.status,'criado_em',l.criado_em,'atualizado_em',l.atualizado_em,
          'total',(select count(*) from sc_itens i where i.lista_id=l.id),
          'comprados',(select count(*) from sc_itens i where i.lista_id=l.id and i.status='comprado'),
          'indisponiveis',(select count(*) from sc_itens i where i.lista_id=l.id and i.status='indisponivel'),
          'novos',(select count(*) from sc_alertas a where a.lista_id=l.id and not a.lido)) x
        from sc_listas l where l.comprador_id=v) s), '[]'::jsonb),
    'alertas', coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'lista_id',a.lista_id,'tipo',a.tipo,'mensagem',a.mensagem,'criado_em',a.criado_em) order by a.criado_em desc)
        from sc_alertas a where a.comprador_id=v and not a.lido), '[]'::jsonb));
end $$;

create or replace function public.sc_lista_comprador(p_chave text, p_lista uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  v := sc__comprador(p_chave);
  if not exists(select 1 from sc_listas where id=p_lista and comprador_id=v) then raise exception 'Lista não encontrada.'; end if;
  update sc_alertas set lido = true where lista_id = p_lista and not lido;
  return sc__lista_json(p_lista);
end $$;

create or replace function public.sc_marcar_item(p_chave text, p_item uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid; l uuid;
begin
  v := sc__comprador(p_chave);
  select i.lista_id into l from sc_itens i join sc_listas li on li.id=i.lista_id where i.id=p_item and li.comprador_id=v;
  if l is null then raise exception 'Item não encontrado.'; end if;
  if p_status not in ('pendente','comprado','indisponivel') then raise exception 'Status inválido.'; end if;
  update sc_itens set status = p_status where id = p_item;
  update sc_listas set status = 'em_compra', atualizado_em = now() where id = l and status = 'enviada';
end $$;

create or replace function public.sc_definir_status(p_chave text, p_lista uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  v := sc__comprador(p_chave);
  if p_status not in ('enviada','em_compra','finalizada') then raise exception 'Status inválido.'; end if;
  update sc_listas set status = p_status, atualizado_em = now(),
    finalizada_em = case when p_status='finalizada' then now() else null end
  where id = p_lista and comprador_id = v;
  if not found then raise exception 'Lista não encontrada.'; end if;
end $$;

create or replace function public.sc_excluir_lista(p_chave text, p_lista uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  v := sc__comprador(p_chave);
  delete from sc_listas where id = p_lista and comprador_id = v;
end $$;

create or replace function public.sc_marcar_alertas_lidos(p_chave text) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  v := sc__comprador(p_chave);
  update sc_alertas set lido = true where comprador_id = v and not lido;
end $$;

revoke execute on function public.sc__comprador(text), public.sc__inserir_itens(uuid,jsonb,boolean), public.sc__lista_json(uuid)
  from public, anon, authenticated;
revoke execute on function public.sc_criar_comprador(text,text,text), public.sc_entrar(text,text), public.sc_info_comprador(text),
  public.sc_criar_lista(text,jsonb,jsonb), public.sc_ver_lista(text), public.sc_adicionar_itens(text,jsonb),
  public.sc_painel(text), public.sc_lista_comprador(text,uuid), public.sc_marcar_item(text,uuid,text),
  public.sc_definir_status(text,uuid,text), public.sc_excluir_lista(text,uuid), public.sc_marcar_alertas_lidos(text)
  from public;
grant execute on function public.sc_criar_comprador(text,text,text), public.sc_entrar(text,text), public.sc_info_comprador(text),
  public.sc_criar_lista(text,jsonb,jsonb), public.sc_ver_lista(text), public.sc_adicionar_itens(text,jsonb),
  public.sc_painel(text), public.sc_lista_comprador(text,uuid), public.sc_marcar_item(text,uuid,text),
  public.sc_definir_status(text,uuid,text), public.sc_excluir_lista(text,uuid), public.sc_marcar_alertas_lidos(text)
  to anon, authenticated;
