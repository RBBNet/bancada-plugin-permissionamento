#!/usr/bin/env bash
# T-12: o BOOT com o plugin barrando nós, e a rede inteira no plugin.
#
# 1. O boot é migrado para o Besu ${BESU_VERSAO_PLUGIN} + plugin (mantendo chave e banco).
# 2. Um nó novo ("candidato"), NATIVO (Besu ${BESU_VERSAO_INICIAL}) e NÃO cadastrado, tenta conectar ao
#    boot. Especificação: o PLUGIN do boot recusa (no T-04 quem recusou foi um boot nativo; no T-08 o
#    pedido nem chegou ao destino). O candidato é nativo de propósito: um nó novo com o plugin não
#    consegue entrar na rede (T-08/T-09, issue #2 do plugin), e aqui o que se testa é o lado do boot.
# 3. Após o cadastro, o plugin do boot permite: o candidato conecta e baixa a cadeia.
# 4. Writer e candidato são migrados para o plugin: a rede inteira fica no plugin. Verificações finais.

fase "Teste T-12: boot com o plugin barrando nó não cadastrado; rede inteira no plugin"
ESTADO_ATUAL="${ESTADO_ATUAL:-E9.4}"
SN="$TRAB/start-network"
SP="$TRAB/scripts-permissionamento"
source "$RAIZ/lib/contas-teste.env"
PORTA_CAND=${PORTA_CAND:-20010}
rbbcli() { em "$SN" executar "rbb-cli $*" ./rbb-cli "$@"; }
LOG_PERM_BOOT="$SN/volumes/boot/logs/besu_permissionamento.log"
K_BOOT=$(sed 's/^0x//' "$SN/.env.configs/nodes/boot/key.pub")

migrar_no() {  # migrar_no <nome> <porta> — Besu ${BESU_VERSAO_PLUGIN} + plugin, mantendo chave e banco
  local n="$1" p="$2"
  [ -f "$SN/docker-compose.override.yml" ] || echo "services:" > "$SN/docker-compose.override.yml"
  cat >> "$SN/docker-compose.override.yml" <<EOF
  $n:
    image: ${BESU_IMAGEM_PLUGIN}
    volumes:
      - ${TRAB}/plugin/besu-plugin-permissioning.jar:/opt/besu/plugins/besu-plugin-permissioning.jar:ro
EOF
  cp "$SN/docker-compose.override.yml" "$EXEC_DIR/docker-compose.override.yml"
  em "$SN" executar "parar $n" docker compose stop "$n"
  em "$SN" executar "subir $n com o plugin" docker compose up -d "$n"
  esperar_ate "RPC de $n" 180 responde "$p" || abortar "$n não respondeu após a migração"
}

passo "Migrar o boot para o Besu ${BESU_VERSAO_PLUGIN} + plugin"
LINHAS_BOOT_ANTES=$(wc -l < "$LOG_PERM_BOOT" | tr -d ' ')
log_boot_depois() { tail -n +"$((LINHAS_BOOT_ANTES + 1))" "$LOG_PERM_BOOT" 2>/dev/null; }
conta_boot() { log_boot_depois | grep -c "$1" || true; }
migrar_no boot "$PORTA_BOOT"
estado E10 "boot no Besu ${BESU_VERSAO_PLUGIN} com o plugin (além dos validadores já migrados)"
ESTADO_ATUAL="E10"
verificar T-12a "versão do Besu no boot" "besu/v${BESU_VERSAO_PLUGIN}" "$(rpc "$PORTA_BOOT" web3_clientVersion | jq -r .result | cut -d/ -f1-2)"
esperar_ate "boot sincronizar" 180 acompanha "$PORTA_VALIDATOR" "$PORTA_BOOT" || true
esperar_ate "writer reconectar ao boot" 180 tem_pares "$PORTA_WRITER" 1 || true
esperar_ate "writer acompanhar a cadeia" 120 acompanha "$PORTA_VALIDATOR" "$PORTA_WRITER" || true
verificar_que T-12b "boot (plugin) sincronizado e writer (nativo) reconectado por ele" "boot e writer a ≤ 1 bloco do validator" \
  "validator $(bloco_atual "$PORTA_VALIDATOR"), boot $(bloco_atual "$PORTA_BOOT"), writer $(bloco_atual "$PORTA_WRITER")" \
  acompanha "$PORTA_VALIDATOR" "$PORTA_BOOT" "$PORTA_WRITER"

passo "Preparar o candidato: NATIVO (Besu ${BESU_VERSAO_INICIAL}), não cadastrado, static-node para o boot"
rbbcli node create candidato
K_CAND=$(sed 's/^0x//' "$SN/.env.configs/nodes/candidato/key.pub")
fato no.candidato.chave_publica "0x$K_CAND"
rbbcli config set "nodes.candidato.ports+=[\"${PORTA_CAND}:8545\"]"
rbbcli config set nodes.candidato.environment.BESU_DISCOVERY_ENABLED=false
rbbcli config set 'nodes.candidato.environment.BESU_DATA_STORAGE_FORMAT="FOREST"'
printf '[\n"enode://%s@boot:30303"\n]\n' "$K_BOOT" > "$SN/volumes/candidato/static-nodes.json"
rbbcli config render-templates
em "$SP" executar "consultar se o candidato está cadastrado" node node-rules-v2.js isNodeActive "0x${K_CAND:0:64}" "0x${K_CAND:64:64}"
verificar T-12c "candidato NÃO está ativo no NodeRulesV2" "ativo: false" \
  "$(grep -o 'ativo: [a-z]*' "$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log" | tail -1)"

passo "Subir o candidato (sem cadastro) e observar por 90 s"
em "$SN" executar "subir candidato" docker compose up -d candidato
esperar_ate "RPC do candidato" 180 responde "$PORTA_CAND" || abortar "candidato não respondeu"
max_pares=0
for i in $(seq 1 18); do p=$(pares "$PORTA_CAND"); [ -n "$p" ] && [ "$p" -gt "$max_pares" ] && max_pares=$p; sleep 5; done
info "log de permissionamento do boot (plugin) sobre o candidato:"
log_boot_depois | grep "enode://$K_CAND" | grep -v Checking | head -3 | cut -c1-240 | sed 's/^/    │ /'
verificar T-12d "candidato sem nenhum par durante 90 s" "0" "$max_pares"
verificar_que T-12e "PLUGIN do boot recusou o candidato (log TRACE do boot)" \
  "≥ 1 linha 'OnChainNodePermissioningProvider: Rejected enode://<candidato>'" \
  "$(conta_boot "OnChainNodePermissioningProvider: Rejected enode://$K_CAND") linha(s)" \
  test "$(conta_boot "OnChainNodePermissioningProvider: Rejected enode://$K_CAND")" -ge 1
verificar T-12f "candidato parado no bloco 0" "0" "$(bloco_atual "$PORTA_CAND")"

passo "Cadastrar o candidato e esperar ele conectar e baixar a cadeia"
em "$SP" executar "addLocalNode candidato (Writer)" node node-rules-v2.js addLocalNode "0x${K_CAND:0:64}" "0x${K_CAND:64:64}" Writer candidato
estado E11 "E10 + candidato (nativo) cadastrado no NodeRulesV2"
ESTADO_ATUAL="E11"
esperar_ate "candidato conectar" 180 tem_pares "$PORTA_CAND" 1 || true
esperar_ate "candidato baixar a cadeia" 240 acompanha "$PORTA_VALIDATOR" "$PORTA_CAND" || true
info "log de permissionamento do boot (plugin) — primeira permissão ao candidato:"
log_boot_depois | grep "Permitted enode://$K_CAND" | head -1 | cut -c1-240 | sed 's/^/    │ /'
verificar_que T-12g "plugin do boot passou a permitir o candidato (log TRACE do boot)" \
  "≥ 1 linha 'Permitted enode://<candidato>'" "$(conta_boot "Permitted enode://$K_CAND") linha(s)" \
  test "$(conta_boot "Permitted enode://$K_CAND")" -ge 1
verificar_que T-12h "candidato (nativo) conectado e com a cadeia inteira" "a ≤ 1 bloco do validator" \
  "validator $(bloco_atual "$PORTA_VALIDATOR"), candidato $(bloco_atual "$PORTA_CAND")" acompanha "$PORTA_VALIDATOR" "$PORTA_CAND"

passo "Migrar writer e candidato para o plugin: rede inteira no plugin"
migrar_no writer "$PORTA_WRITER"
migrar_no candidato "$PORTA_CAND"
estado E12 "rede inteira no Besu ${BESU_VERSAO_PLUGIN} com o plugin (validadores, boot, writer e candidato)"
ESTADO_ATUAL="E12"
esperar_ate "writer acompanhar a cadeia" 180 acompanha "$PORTA_VALIDATOR" "$PORTA_WRITER" || true
esperar_ate "candidato acompanhar a cadeia" 180 acompanha "$PORTA_VALIDATOR" "$PORTA_CAND" || true

VERSOES=""; nativos=0
for n in $(cd "$SN" && docker compose ps --services --status running); do
  p=$(cd "$SN" && docker compose port "$n" 8545 2>/dev/null | cut -d: -f2)
  [ -z "$p" ] && continue
  v=$(rpc "$p" web3_clientVersion | jq -r .result | cut -d/ -f2)
  VERSOES="$VERSOES $n=$v"; [ "$v" != "v${BESU_VERSAO_PLUGIN}" ] && nativos=$((nativos + 1))
done
fato t12.versoes_dos_nos_em_execucao "$VERSOES"
verificar T-12i "nenhum nó em execução fora do Besu ${BESU_VERSAO_PLUGIN} (rede inteira no plugin)" "0" "$nativos" "{\"versoes\":\"$VERSOES\"}"
R=$(node "$RAIZ/ferramentas/tx.js" "http://localhost:${PORTA_WRITER}" "$CONTA_ADMIN_CHAVE")
echo "$R" >> "$EXEC_DIR/transacoes.jsonl"
verificar T-12j "rede inteira no plugin: transação de conta permitida, pelo writer" "MINERADA, status 1" \
  "$(jq -r 'if .resultado=="MINERADA" then "MINERADA, status \(.status)" else "RECUSADA: \(.codigo) \(.erro)" end' <<<"$R")" "$R"
HASH=$(jq -r '.hash // empty' <<<"$R")
[ -n "$HASH" ] && verificar T-12k "candidato (plugin) importou o bloco com a transação" "status 0x1" \
  "status $(rpc "$PORTA_CAND" eth_getTransactionReceipt "[\"$HASH\"]" | jq -r '.result.status // "sem recibo"')"
R=$(node "$RAIZ/ferramentas/tx.js" "http://localhost:${PORTA_WRITER}" aleatoria)
echo "$R" >> "$EXEC_DIR/transacoes.jsonl"
verificar T-12l "rede inteira no plugin: transação de conta não cadastrada, pelo writer" \
  "RECUSADA: -32007 Sender account not authorized to send transactions" \
  "$(jq -r 'if .resultado=="RECUSADA" then "RECUSADA: \(.codigo) \(.erro)" else "MINERADA no bloco \(.bloco)" end' <<<"$R")" "$R"
