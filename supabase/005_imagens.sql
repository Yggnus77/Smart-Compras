-- Smart Compras: foto/imagem ilustrativa de cada peça, com conferência pelo dono.
-- Rodar UMA vez no SQL Editor do Supabase, depois do 004_pecas_trx.sql.
-- Não apaga nada.
--
--   sc_itens.imagem    = endereço (https) da foto da peça
--   sc_itens.imagem_ok = null: ainda não conferida · true: confere com a peça · false: não confere
--
-- As fotos tiradas no app ficam no Storage, no bucket público "sc-pecas"
-- (até 5 MB por foto, só JPEG/PNG/WebP). O app reduz a foto para no máximo 1600 px antes de enviar.

alter table public.sc_itens add column if not exists imagem text;
alter table public.sc_itens add column if not exists imagem_ok boolean;

-- ===== Storage: bucket das fotos =====
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sc-pecas', 'sc-pecas', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "sc_pecas_enviar" on storage.objects;
create policy "sc_pecas_enviar" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'sc-pecas' and name ~ '^[0-9a-f-]{36}\.(jpg|png|webp)$');

-- ===== helper: valida o endereço da imagem =====
create or replace function public.sc__url_imagem(p text) returns text
language plpgsql immutable set search_path = public as $$
declare u text := nullif(trim(coalesce(p,'')),'');
begin
  if u is null then return null; end if;
  if length(u) > 1000 or u !~* '^https?://[^\s"''<>]+$' then raise exception 'Endereço de imagem inválido.'; end if;
  return u;
end $$;

-- ===== itens passam a aceitar "imagem" =====
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
    insert into sc_itens(lista_id, produto, referencia, quantidade, unidade, adicional, observacao, imagem)
    values (p_lista, left(trim(it->>'produto'),200),
            nullif(left(trim(coalesce(it->>'referencia','')),80),''), q,
            left(coalesce(nullif(trim(it->>'unidade'),''),'Unidade'),30), p_adicional,
            nullif(left(trim(coalesce(it->>'observacao','')),300),''),
            sc__url_imagem(it->>'imagem'));
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
        'observacao',i.observacao,'qtd_comprada',i.qtd_comprada,'substituto',i.substituto,
        'imagem',i.imagem,'imagem_ok',i.imagem_ok) order by i.seq)
      from sc_itens i where i.lista_id = l.id), '[]'::jsonb))
  from sc_listas l join sc_compradores c on c.id = l.comprador_id where l.id = p_lista
$$;

-- ===== dono: troca/remove a imagem (a imagem escolhida pelo dono já fica "confere") =====
create or replace function public.sc_item_imagem(p_chave text, p_item uuid, p_url text) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid; u text;
begin
  v := sc__comprador(p_chave);
  if not exists(select 1 from sc_itens i join sc_listas l on l.id=i.lista_id where i.id=p_item and l.comprador_id=v) then
    raise exception 'Item não encontrado.'; end if;
  u := sc__url_imagem(p_url);
  update sc_itens set imagem = u, imagem_ok = case when u is null then null else true end where id = p_item;
end $$;

-- ===== dono: confere se a imagem é a peça descrita =====
create or replace function public.sc_conferir_imagem(p_chave text, p_item uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  v := sc__comprador(p_chave);
  update sc_itens i set imagem_ok = p_ok from sc_listas l
   where i.id = p_item and l.id = i.lista_id and l.comprador_id = v and i.imagem is not null;
  if not found then raise exception 'Item não encontrado.'; end if;
end $$;

-- ===== mecânico: envia/troca a foto de uma peça já enviada (até o orçamento ser finalizado) =====
create or replace function public.sc_item_imagem_cliente(p_token text, p_item uuid, p_url text) returns void
language plpgsql security definer set search_path = public as $$
declare l sc_listas; u text; nome text;
begin
  select * into l from sc_listas where token = p_token;
  if l.id is null then raise exception 'Orçamento não encontrado.'; end if;
  if l.status = 'finalizada' then raise exception 'Este orçamento já foi finalizado.'; end if;
  u := sc__url_imagem(p_url);
  update sc_itens set imagem = u, imagem_ok = null where id = p_item and lista_id = l.id returning produto into nome;
  if nome is null then raise exception 'Peça não encontrada.'; end if;
  update sc_listas set atualizado_em = now() where id = l.id;
  if u is not null then
    insert into sc_alertas(comprador_id, lista_id, tipo, mensagem)
    values (l.comprador_id, l.id, 'imagem', l.cliente_nome || ' enviou a foto da peça ' || left(nome,80)
            || coalesce(' (orçamento de ' || l.cliente_final || ')', ''));
  end if;
end $$;

revoke execute on function public.sc__inserir_itens(uuid,jsonb,boolean), public.sc__lista_json(uuid), public.sc__url_imagem(text)
  from public, anon, authenticated;
revoke execute on function public.sc_item_imagem(text,uuid,text), public.sc_conferir_imagem(text,uuid,boolean),
  public.sc_item_imagem_cliente(text,uuid,text) from public;
grant execute on function public.sc_item_imagem(text,uuid,text), public.sc_conferir_imagem(text,uuid,boolean),
  public.sc_item_imagem_cliente(text,uuid,text) to anon, authenticated;
