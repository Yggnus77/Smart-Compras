-- Smart Compras: adaptação para orçamento de peças Honda TRX 520/420
-- Rodar UMA vez no SQL Editor do Supabase, depois do 003_push.sql.
-- Não apaga nada: as listas antigas continuam aparecendo normalmente.
--
-- Mapeamento dos campos:
--   sc_listas.cliente_nome = nome do mecânico (quem preenche o link)
--   sc_listas.local        = garimpo ou região
--   sc_listas.modelo       = 'TRX 520' | 'TRX 420'           (novo)
--   sc_listas.marcha       = 'Na mão' | 'No pé'              (novo)
--   sc_listas.cliente_final= cliente do orçamento             (novo)
--   sc_listas.telefone     = WhatsApp do mecânico (agora opcional)
--   sc_itens.produto       = nome da peça
--   sc_itens.referencia    = referência / código da peça      (novo)

alter table public.sc_listas add column if not exists modelo text;
alter table public.sc_listas add column if not exists marcha text;
alter table public.sc_listas add column if not exists cliente_final text;
alter table public.sc_listas alter column telefone drop not null;
alter table public.sc_itens add column if not exists referencia text;

create or replace function public.sc__inserir_itens(p_lista uuid, p_itens jsonb, p_adicional boolean) returns int
language plpgsql security definer set search_path = public as $$
declare it jsonb; n int := 0; q numeric;
begin
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' then raise exception 'Itens inválidos.'; end if;
  if jsonb_array_length(p_itens) > 300 then raise exception 'Máximo de 300 peças por envio.'; end if;
  for it in select * from jsonb_array_elements(p_itens) loop
    if coalesce(trim(it->>'produto'),'') = '' then continue; end if;
    begin q := (it->>'quantidade')::numeric; exception when others then q := 1; end;
    if q is null or q <= 0 then q := 1; end if;
    insert into sc_itens(lista_id, produto, referencia, quantidade, unidade, adicional, observacao)
    values (p_lista, left(trim(it->>'produto'),200),
            nullif(left(trim(coalesce(it->>'referencia','')),80),''), q,
            left(coalesce(nullif(trim(it->>'unidade'),''),'Unidade'),30), p_adicional,
            nullif(left(trim(coalesce(it->>'observacao','')),300),''));
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'Adicione pelo menos uma peça.'; end if;
  return n;
end $$;

create or replace function public.sc__lista_json(p_lista uuid) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'id', l.id, 'token', l.token, 'cliente_nome', l.cliente_nome, 'local', l.local,
    'data_lista', l.data_lista, 'telefone', l.telefone, 'observacao', l.observacao,
    'modelo', l.modelo, 'marcha', l.marcha, 'cliente_final', l.cliente_final,
    'status', l.status, 'criado_em', l.criado_em, 'finalizada_em', l.finalizada_em,
    'comprador_nome', c.nome,
    'itens', coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'produto',i.produto,'referencia',i.referencia,'quantidade',i.quantidade,
        'unidade',i.unidade,'status',i.status,'adicional',i.adicional,'criado_em',i.criado_em,
        'observacao',i.observacao,'qtd_comprada',i.qtd_comprada,'substituto',i.substituto) order by i.seq)
      from sc_itens i where i.lista_id = l.id), '[]'::jsonb))
  from sc_listas l join sc_compradores c on c.id = l.comprador_id where l.id = p_lista
$$;

create or replace function public.sc_criar_lista(p_usuario text, p_cliente jsonb, p_itens jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_comp uuid; v_lista sc_listas; n int; v_modelo text; v_marcha text;
begin
  select id into v_comp from sc_compradores where usuario = lower(trim(p_usuario));
  if v_comp is null then raise exception 'Link inválido.'; end if;
  v_modelo := nullif(trim(coalesce(p_cliente->>'modelo','')),'');
  v_marcha := nullif(trim(coalesce(p_cliente->>'marcha','')),'');
  if coalesce(trim(p_cliente->>'nome'),'') = '' or coalesce(trim(p_cliente->>'local'),'') = ''
     or coalesce(trim(p_cliente->>'cliente_final'),'') = '' or v_modelo is null or v_marcha is null then
    raise exception 'Preencha nome do mecânico, garimpo/região, modelo, marcha e nome do cliente.';
  end if;
  if v_modelo not in ('TRX 520','TRX 420') then raise exception 'Modelo inválido.'; end if;
  if v_marcha not in ('Na mão','No pé') then raise exception 'Tipo de marcha inválido.'; end if;
  insert into sc_listas(comprador_id, cliente_nome, local, data_lista, telefone, observacao, modelo, marcha, cliente_final)
  values (v_comp, left(trim(p_cliente->>'nome'),120), left(trim(p_cliente->>'local'),160),
          coalesce(nullif(p_cliente->>'data','')::date, current_date),
          nullif(left(trim(coalesce(p_cliente->>'telefone','')),30),''),
          nullif(left(trim(coalesce(p_cliente->>'observacao','')),500),''),
          v_modelo, v_marcha, left(trim(p_cliente->>'cliente_final'),120))
  returning * into v_lista;
  n := sc__inserir_itens(v_lista.id, p_itens, false);
  insert into sc_alertas(comprador_id, lista_id, tipo, mensagem)
  values (v_comp, v_lista.id, 'nova_lista',
          'Novo orçamento de ' || v_lista.cliente_nome || ' (' || v_lista.local || ') · ' || v_modelo
          || ' · cliente ' || v_lista.cliente_final || ' · ' || n || case when n=1 then ' peça' else ' peças' end);
  return v_lista.token;
end $$;

create or replace function public.sc_adicionar_itens(p_token text, p_itens jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare l sc_listas; n int;
begin
  select * into l from sc_listas where token = p_token;
  if l.id is null then raise exception 'Orçamento não encontrado.'; end if;
  if l.status = 'finalizada' then raise exception 'Este orçamento já foi finalizado. Não é possível adicionar peças.'; end if;
  n := sc__inserir_itens(l.id, p_itens, true);
  update sc_listas set atualizado_em = now() where id = l.id;
  insert into sc_alertas(comprador_id, lista_id, tipo, mensagem)
  values (l.comprador_id, l.id, 'itens_adicionados',
          l.cliente_nome || ' adicionou ' || n || case when n=1 then ' peça' else ' peças' end
          || ' ao orçamento' || coalesce(' de ' || l.cliente_final, ''));
  return n;
end $$;

create or replace function public.sc_painel(p_chave text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  v := sc__comprador(p_chave);
  return jsonb_build_object(
    'comprador', (select jsonb_build_object('nome',nome,'usuario',usuario) from sc_compradores where id=v),
    'listas', coalesce((select jsonb_agg(x order by x->>'criado_em' desc) from (
        select jsonb_build_object('id',l.id,'token',l.token,'cliente_nome',l.cliente_nome,'local',l.local,'data_lista',l.data_lista,
          'telefone',l.telefone,'status',l.status,'criado_em',l.criado_em,'atualizado_em',l.atualizado_em,'finalizada_em',l.finalizada_em,
          'modelo',l.modelo,'marcha',l.marcha,'cliente_final',l.cliente_final,
          'total',(select count(*) from sc_itens i where i.lista_id=l.id),
          'comprados',(select count(*) from sc_itens i where i.lista_id=l.id and i.status='comprado'),
          'parciais',(select count(*) from sc_itens i where i.lista_id=l.id and i.status='parcial'),
          'indisponiveis',(select count(*) from sc_itens i where i.lista_id=l.id and i.status='indisponivel'),
          'novos',(select count(*) from sc_alertas a where a.lista_id=l.id and not a.lido)) x
        from sc_listas l where l.comprador_id=v) s), '[]'::jsonb),
    'alertas', coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'lista_id',a.lista_id,'tipo',a.tipo,'mensagem',a.mensagem,'criado_em',a.criado_em) order by a.criado_em desc)
        from sc_alertas a where a.comprador_id=v and not a.lido), '[]'::jsonb));
end $$;

revoke execute on function public.sc__inserir_itens(uuid,jsonb,boolean), public.sc__lista_json(uuid) from public, anon, authenticated;
revoke execute on function public.sc_criar_lista(text,jsonb,jsonb), public.sc_adicionar_itens(text,jsonb), public.sc_painel(text) from public;
grant execute on function public.sc_criar_lista(text,jsonb,jsonb), public.sc_adicionar_itens(text,jsonb), public.sc_painel(text) to anon, authenticated;
