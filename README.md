# Smart Compras

Lista de compras compartilhada entre o comprador e seus clientes.

- **Painel do comprador**: `https://yggnus77.github.io/Smart-Compras/` (entrar / criar conta)
- **Link do cliente**: `?c=<usuario>` — o cliente preenche nome, local/garimpo, data, telefone e os itens
- **Lista do cliente**: `?l=<token>` — acompanha a compra, adiciona itens (o comprador recebe alerta) e vê o relatório final

## Estrutura
- `index.html` — app inteiro (HTML + JS, sem build). A URL e a chave pública do Supabase estão no topo do script.
- `supabase/schema.sql` — tabelas `sc_*` e funções RPC. Rodar uma vez no SQL Editor do Supabase.
- `supabase/002_melhorias.sql` — quantidade parcial, observação por item e substituto. Rodar uma vez, depois do schema.sql.
- `supabase/003_push.sql` + `supabase/functions/sc-push/index.ts` — alertas no celular com o painel fechado (Web Push). A função é criada no painel do Supabase com "Verify JWT" desligado.
- `manifest.webmanifest`, `sw.js`, `img/` — app instalável (ícone e fundo da marca).

## Publicação
GitHub Pages servindo a branch `main` (pasta raiz).
