-- Smart Compras: melhorias (quantidade parcial, observação por item, substituto)
-- Rodar UMA vez no SQL Editor do Supabase, depois do schema.sql.

alter table public.sc_itens add column if not exists observacao text;
alter table public.sc_itens add column if not exists qtd_comprada numeric;
alter table public.sc_itens add column if not exists substituto text;

alter table public.sc_itens drop constraint if exists sc_itens_status_check;
alter table public.sc_itens add constraint sc_itens_status_check
  check (status in ('pendente','comprado','parcial','indisponivel'));

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
    insert into sc_itens(lista_id, produto, quantidade, unidade, adicional, observacao)
    values (p_lista, left(trim(it->>'produto'),200), q,
            left(coalesce(nullif(trim(it->>'unidade'),''),'Unidade'),30), p_adicional,
            nullif(left(trim(coalesce(it->>'observacao','')),300),''));
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
        'unidade',i.unidade,'status',i.status,'adicional',i.adicional,'criado_em',i.criado_em,
        'observacao',i.observacao,'qtd_comprada',i.qtd_comprada,'substituto',i.substituto) order by i.seq)
      from sc_itens i where i.lista_id = l.id), '[]'::jsonb))
  from sc_listas l join sc_compradores c on c.id = l.comprador_id where l.id = p_lista
$$;

drop function if exists public.sc_marcar_item(text,uuid,text);
create or replace function public.sc_marcar_item(p_chave text, p_item uuid, p_status text,
  p_qtd numeric default null, p_substituto text default null) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid; l uuid; q numeric;
begin
  v := sc__comprador(p_chave);
  select i.lista_id, i.quantidade into l, q from sc_itens i join sc_listas li on li.id=i.lista_id
   where i.id=p_item and li.comprador_id=v;
  if l is null then raise exception 'Item não encontrado.'; end if;
  if p_status not in ('pendente','comprado','parcial','indisponivel') then raise exception 'Status inválido.'; end if;
  if p_status = 'parcial' and (p_qtd is null or p_qtd <= 0 or p_qtd >= q) then
    raise exception 'Quantidade parcial deve ser maior que zero e menor que a pedida.';
  end if;
  update sc_itens set status = p_status,
    qtd_comprada = case p_status when 'parcial' then p_qtd when 'comprado' then quantidade else null end,
    substituto = case when p_status = 'pendente' then null else nullif(left(trim(coalesce(p_substituto,'')),200),'') end
  where id = p_item;
  update sc_listas set status = 'em_compra', atualizado_em = now() where id = l and status = 'enviada';
end $$;

-- contagens do painel: "parcial" conta como verificado
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
revoke execute on function public.sc_marcar_item(text,uuid,text,numeric,text), public.sc_painel(text) from public;
grant execute on function public.sc_marcar_item(text,uuid,text,numeric,text), public.sc_painel(text) to anon, authenticated;
