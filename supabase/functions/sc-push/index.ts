// Smart Compras — Edge Function "sc-push"
// GET  → devolve a chave pública VAPID (cria o par de chaves na primeira vez e guarda em sc_config)
// POST {alerta_id, segredo} → chamado pelo banco quando nasce um alerta; envia a notificação
//      para todos os aparelhos inscritos do comprador.
// Configuração: criar no painel do Supabase com o nome "sc-push" e DESLIGAR "Verify JWT".
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function cfg(k: string): Promise<string | null> {
  const { data } = await db.from("sc_config").select("v").eq("k", k).maybeSingle();
  return data?.v ?? null;
}
async function chaves() {
  let pub = await cfg("vapid_pub"), priv = await cfg("vapid_priv");
  if (!pub || !priv) {
    const k = webpush.generateVAPIDKeys();
    // ignoreDuplicates: se duas chamadas criarem ao mesmo tempo, vale a primeira
    await db.from("sc_config").upsert([{ k: "vapid_pub", v: k.publicKey }, { k: "vapid_priv", v: k.privateKey }],
      { onConflict: "k", ignoreDuplicates: true });
    pub = await cfg("vapid_pub"); priv = await cfg("vapid_priv");
  }
  return { pub: pub!, priv: priv! };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const { pub, priv } = await chaves();
    if (req.method === "GET") return json({ publicKey: pub });

    const { alerta_id, segredo } = await req.json();
    if (!segredo || segredo !== await cfg("segredo")) return json({ erro: "não autorizado" }, 401);

    const { data: a } = await db.from("sc_alertas").select("id, comprador_id, lista_id, tipo, mensagem")
      .eq("id", alerta_id).maybeSingle();
    if (!a) return json({ erro: "alerta não encontrado" }, 404);
    const { data: subs } = await db.from("sc_push").select("id, sub").eq("comprador_id", a.comprador_id);

    webpush.setVapidDetails("mailto:avisos@smart-compras.app", pub, priv);
    const payload = JSON.stringify({
      title: a.tipo === "itens_adicionados" ? "Itens adicionados" : "Nova lista de compras",
      body: a.mensagem,
      lista_id: a.lista_id,
    });
    let enviados = 0;
    for (const s of subs ?? []) {
      try {
        await webpush.sendNotification(s.sub, payload, { TTL: 86400, urgency: "high" });
        enviados++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await db.from("sc_push").delete().eq("id", s.id); // aparelho saiu
        else console.error("push falhou", code, (e as Error).message);
      }
    }
    return json({ enviados });
  } catch (e) {
    console.error(e);
    return json({ erro: (e as Error).message }, 500);
  }
});
