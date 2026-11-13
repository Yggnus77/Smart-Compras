# Smart Compras

Orçamento de peças para quadriciclos Honda TRX 520/420, entre os mecânicos e o dono (quem recebe e responde).

- **Painel do dono**: `https://yggnus77.github.io/Smart-Compras/` (entrar / criar conta). Marca cada peça como **Tem** ou **Não tem** (com alternativa opcional) e finaliza o orçamento.
- **Link do mecânico**: `?c=<usuario>` — o mecânico informa nome, garimpo/região, modelo (TRX 520/420), marcha (na mão/no pé), nome do cliente e lista as peças com nome e referência
- **Orçamento do mecânico**: `?l=<token>` — acompanha o orçamento, adiciona peças (o dono recebe alerta) e vê o resultado final

## Estrutura
- `index.html` — app inteiro (HTML + JS, sem build). A URL e a chave pública do Supabase estão no topo do script.
- `supabase/schema.sql` — tabelas `sc_*` e funções RPC. Rodar uma vez no SQL Editor do Supabase.
- `supabase/002_melhorias.sql` — quantidade parcial, observação por item e substituto. Rodar uma vez, depois do schema.sql.
- `supabase/003_push.sql` + `supabase/functions/sc-push/index.ts` — alertas no celular com o painel fechado (Web Push). A função é criada no painel do Supabase com "Verify JWT" desligado.
- `supabase/004_pecas_trx.sql` — campos de modelo, marcha, cliente do orçamento e referência da peça; telefone passa a ser opcional. Rodar uma vez, depois do 003.
- `supabase/005_imagens.sql` — imagem de cada peça (foto tirada no app, link colado ou busca pela referência), guardada no Storage (bucket público `sc-pecas`), com conferência pelo dono (confere / não confere). Rodar uma vez, depois do 004.
- `manifest.webmanifest`, `sw.js`, `img/` — app instalável (ícone e fundo da marca).

## Publicação
GitHub Pages servindo a branch `main` (pasta raiz).
