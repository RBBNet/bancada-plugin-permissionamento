#!/usr/bin/env bash
# T-05 a T-07: migração do nó "novo" (último a entrar) para o Besu ${BESU_VERSAO_PLUGIN} com o plugin
# de permissionamento, mantendo chave e banco de dados; depois, transações enviadas por ele.
# Estado E3 → E4 (rede mista: "novo" com plugin; validator, boot e writer com permissionamento nativo).

fase "Testes T-05 a T-07: nó 'novo' migrado para o Besu ${BESU_VERSAO_PLUGIN} com o plugin (E3 → E4)"
ESTADO_ATUAL="E3→E4"
SN="$TRAB/start-network"
source "$RAIZ/lib/contas-teste.env"
PORTA_NOVO=${PORTA_NOVO:-20004}
PORTA_METRICAS_NOVO=${PORTA_METRICAS_NOVO:-29545}
LOG_NOVO="$SN/volumes/novo/logs"
K_NOVO=$(sed 's/^0x//' "$SN/.env.configs/nodes/novo/key.pub")
K_BOOT=$(sed 's/^0x//' "$SN/.env.configs/nodes/boot/key.pub")

passo "Estado do nó 'novo' antes da migração"
B_ANTES=$(bloco_atual "$PORTA_NOVO")
fato t05.bloco_novo_antes_da_migracao "$B_ANTES"
fato t05.versao_novo_antes "$(rpc "$PORTA_NOVO" web3_clientVersion | jq -r .result)"

passo "Parar o nó 'novo' (banco de dados e chave são mantidos)"
em "$SN" executar "parar nó novo" docker compose stop novo
mkdir -p "$EXEC_DIR/nos"
cp -r "$LOG_NOVO" "$EXEC_DIR/nos/novo-arquivos-antes-da-migracao" 2>/dev/null
( cd "$SN" && docker compose logs --timestamps novo > "$EXEC_DIR/nos/novo-console-antes-da-migracao.log" 2>&1 )

# O arquivo de log fica no volume do nó e sobrevive à migração: guardamos quantas linhas ele tinha,
# para que as verificações considerem só o que foi escrito DEPOIS da migração (pelo plugin).
LINHAS_PERM_ANTES=$(wc -l < "$LOG_NOVO/besu_permissionamento.log" 2>/dev/null | tr -d ' ' || echo 0)
fato t05.linhas_log_permissionamento_antes_da_migracao "${LINHAS_PERM_ANTES:-0}"
perm_depois() { tail -n +"$(( ${LINHAS_PERM_ANTES:-0} + 1 ))" "$LOG_NOVO/besu_permissionamento.log" 2>/dev/null; }

passo "Configuração do nó 'novo' para o Besu ${BESU_VERSAO_PLUGIN} + plugin (docker-compose.override.yml)"
# O docker compose aplica automaticamente o docker-compose.override.yml da mesma pasta.
# Só o serviço "novo" é alterado; os demais continuam no Besu ${BESU_VERSAO_INICIAL} nativo.
# O plugin lê BESU_PERMISSIONS_ACCOUNTS_CONTRACT_ADDRESS, BESU_PERMISSIONS_NODES_CONTRACT_ADDRESS e
# BESU_PERMISSIONS_NODES_CONTRACT_VERSION, que o compose do start-network já define para todos os nós
# (0x…8888, 0x…9999 e 1) — exatamente os Ingress da RBB e a interface de nós do gen02.
# As variáveis BESU_PERMISSIONS_*_CONTRACT_ENABLED do compose não correspondem a nenhuma opção na
# 25.12 (o permissionamento nativo foi removido na 25.6.0); em experimento, a 25.12.0 as ignorou em
# silêncio, sem aviso no log. Por isso não precisam ser removidas.
cat > "$SN/docker-compose.override.yml" <<EOF
services:
  novo:
    image: ${BESU_IMAGEM_PLUGIN}
    volumes:
      - ${TRAB}/plugin/besu-plugin-permissioning.jar:/opt/besu/plugins/besu-plugin-permissioning.jar:ro
    ports:
      - ${PORTA_METRICAS_NOVO}:9545
EOF
cp "$SN/docker-compose.override.yml" "$EXEC_DIR/docker-compose.override.yml"
sed 's/^/    │ /' "$SN/docker-compose.override.yml"
em "$SN" executar "configuração efetiva do nó novo (compose + override)" docker compose config novo
cp "$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log" "$EXEC_DIR/compose-novo-efetivo.txt"

passo "Subir o nó 'novo' migrado"
em "$SN" executar "subir nó novo (Besu ${BESU_VERSAO_PLUGIN} + plugin)" docker compose up -d novo
esperar_ate "RPC do nó novo" 180 responde "$PORTA_NOVO" || abortar "nó novo não respondeu após a migração"
estado E4 "rede mista: 'novo' no Besu ${BESU_VERSAO_PLUGIN} com o plugin; validator, boot e writer no ${BESU_VERSAO_INICIAL} nativo"

sleep 3
CONSOLE_NOVO=$(cd "$SN" && docker compose logs novo 2>/dev/null)   # lido uma vez (grep -q numa pipeline com pipefail dá falso negativo)
verificar T-05a "versão do Besu no nó novo após a migração" "besu/v${BESU_VERSAO_PLUGIN}" \
  "$(rpc "$PORTA_NOVO" web3_clientVersion | jq -r .result | cut -d/ -f1-2)"
verificar_que T-05b "bloco do nó novo preservado (banco reaproveitado, sem sincronizar do zero)" \
  "bloco inicial ≥ $B_ANTES" "$(bloco_atual "$PORTA_NOVO")" test "$(bloco_atual "$PORTA_NOVO")" -ge "$B_ANTES"
info "linhas do plugin no console do nó novo:"
grep -E "Permissioning Plugin|Ingress Address|contract interface version|Simulation gas" <<<"$CONSOLE_NOVO" | head -8 | cut -c1-220 | sed 's/^/    │ /'
verificar T-05c "plugin registrado pelo Besu" "sim" \
  "$(grep -c 'Registering On-Chain Permissioning Plugin' <<<"$CONSOLE_NOVO" | grep -q '^[1-9]' && echo sim || echo não)"
verificar T-05d "plugin configurado com o Ingress de contas da RBB" "0x0000000000000000000000000000000000008888" \
  "$(grep -o 'Account Permissioning Ingress Address set to: 0x[0-9a-fA-F]*' <<<"$CONSOLE_NOVO" | tail -1 | grep -o '0x.*')"
verificar T-05e "plugin configurado com o Ingress de nós da RBB" "0x0000000000000000000000000000000000009999" \
  "$(grep -o 'Node Permissioning Ingress Address set to: 0x[0-9a-fA-F]*' <<<"$CONSOLE_NOVO" | tail -1 | grep -o '0x.*')"
verificar T-05f "interface de nós configurada no plugin" "1" \
  "$(grep -o 'Node contract interface version set to [0-9]*' <<<"$CONSOLE_NOVO" | tail -1 | grep -o '[0-9]*$')"

passo "Reconexão e sincronização do nó novo"
t0=$SECONDS
esperar_ate "nó novo reconectar ao boot" 180 tem_pares "$PORTA_NOVO" 1
fato t05.segundos_ate_reconectar "$((SECONDS - t0))"
esperar_ate "nó novo sincronizar" 120 acompanha "$PORTA_VALIDATOR" "$PORTA_NOVO"
verificar_que T-05g "nó novo (plugin) reconectado ao boot" "≥ 1 par" "$(pares "$PORTA_NOVO") par(es)" tem_pares "$PORTA_NOVO" 1
bv=$(bloco_atual "$PORTA_VALIDATOR"); bn=$(bloco_atual "$PORTA_NOVO")
verificar_que T-05h "nó novo (plugin) sincronizado com o validator" "diferença ≤ 1 bloco" "validator $bv, novo $bn" \
  acompanha "$PORTA_VALIDATOR" "$PORTA_NOVO"
info "log de permissionamento do nó novo, só linhas escritas após a migração (plugin): regras e decisão sobre o boot"
perm_depois | grep -E "Resolved (AccountRules|NodeRules)|enode://$K_BOOT" \
  | grep -v Checking | head -4 | cut -c1-240 | sed 's/^/    │ /'
verificar T-05i "plugin resolveu o NodeRules do gen02 pelo Ingress" "$(minusculo "$(jq -r 'select(.chave=="gen02.node_rules_v2") | .valor' "$EXEC_DIR/fatos.jsonl" | tail -1)")" \
  "$(minusculo "$(perm_depois | grep -o 'Resolved NodeRules contract address: 0x[0-9a-fA-F]*' | tail -1 | grep -o '0x.*')")"
verificar T-05j "após a migração, o permissionamento do nó novo permitiu a conexão com o boot" "sim" \
  "$(perm_depois | grep -c "Permitted enode://$K_NOVO.*-> enode://$K_BOOT\|Permitted enode://$K_BOOT.*-> enode://$K_NOVO" | grep -q '^[1-9]' && echo sim || echo não)"

passo "T-06: conta permitida (GLOBAL_ADMIN da Org 1) envia transação pelo nó com plugin"
R=$(node "$RAIZ/ferramentas/tx.js" "http://localhost:${PORTA_NOVO}" "$CONTA_ADMIN_CHAVE")
echo "$R" >> "$EXEC_DIR/transacoes.jsonl"
verificar T-06 "transação de conta permitida, enviada pelo nó com plugin" "MINERADA, status 1" \
  "$(jq -r .resumo <<<"$R")" "$R"
HASH=$(jq -r '.hash // empty' <<<"$R")
# Que o nó com plugin importou o bloco já está garantido pelo T-06: o tx.js obteve o recibo por ele.
if [ -n "$HASH" ]; then
  esperar_ate "writer importar o bloco da transação" 30 tem_recibo "$PORTA_WRITER" "$HASH" || true
  verificar T-06c "writer (nativo) importou o mesmo bloco (recibo disponível nele)" "status 0x1" \
    "status $(rpc "$PORTA_WRITER" eth_getTransactionReceipt "[\"$HASH\"]" | jq -r '.result.status // "sem recibo"')"
fi

passo "T-07: conta nunca cadastrada envia transação pelo nó com plugin"
R=$(node "$RAIZ/ferramentas/tx.js" "http://localhost:${PORTA_NOVO}" aleatoria)
echo "$R" >> "$EXEC_DIR/transacoes.jsonl"
verificar T-07 "transação de conta não cadastrada, enviada pelo nó com plugin — mesma recusa do nativo (T-02)" \
  'RECUSADA: -32007 Sender account not authorized to send transactions' \
  "$(jq -r .resumo <<<"$R")" "$R"

passo "Métricas do plugin (o release v1.0.0-rc.1 documenta besu_permissioning_transactions_total_checked etc.)"
METRICAS=$(curl -s -m 10 "localhost:${PORTA_METRICAS_NOVO}/metrics" | grep -i "permissioning" | grep -v '^#')
sed 's/^/    │ /' <<<"$METRICAS" | head -8
NOMES=$(cut -d'{' -f1 <<<"$METRICAS" | cut -d' ' -f1 | sort -u | tr '\n' ' ')
observar T-07m "nomes das métricas de permissionamento" \
  "besu_permissioning_transactions_total_checked (e demais nomes do release)" \
  "$(grep -q '^besu_permissioning_transactions_total_checked' <<<"$METRICAS" && echo "besu_permissioning_transactions_total_checked (e demais nomes do release)" || echo "${NOMES:-nenhuma métrica com 'permissioning'}")"
metrica() { grep "^[a-z_]*$1 " <<<"$METRICAS" | awk '{print int($2)}' | head -1; }
NEG=$(metrica onchain_transaction_check_count_denied_total); PER=$(metrica onchain_transaction_check_count_permitted_total)
verificar_que T-07n "contadores do plugin refletem os testes: 1 recusa (T-07) e ≥ 2 permissões (T-06 no pool + na importação do bloco)" \
  "recusadas = 1, permitidas ≥ 2" "recusadas = ${NEG:-?}, permitidas = ${PER:-?}" \
  test "${NEG:-0}" -eq 1 -a "${PER:-0}" -ge 2
