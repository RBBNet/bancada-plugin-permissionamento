#!/usr/bin/env bash
# T-08: um nó NOVO ("entrante"), já no Besu ${BESU_VERSAO_PLUGIN} com o plugin, entra na rede.
#   1. Sem cadastro, tenta conectar ao nó "novo" (que também usa o plugin). Especificação: o plugin
#      do "novo" recusa.
#   2. É cadastrado no NodeRulesV2 (E4 → E5). Especificação: conecta e baixa a cadeia inteira
#      (sincronização FULL a partir do gênesis, como no roteiro de adição de nós).
#
# As verificações seguem a ESPECIFICAÇÃO (o que deveria acontecer). Há indícios (T-03) de que um
# nó com o plugin não consegue processar os blocos iniciais da cadeia, anteriores à implantação
# das regras. Numa conexão com plugin nas duas pontas, CADA lado decide com base no próprio estado
# da cadeia; por isso registramos os logs de permissionamento dos dois lados.

fase "Teste T-08: nó entrante com plugin — recusa, cadastro, conexão e sincronização desde o gênesis"
ESTADO_ATUAL="E4"
SN="$TRAB/start-network"
SP="$TRAB/scripts-permissionamento"
PORTA_ENTRANTE=${PORTA_ENTRANTE:-20005}
PORTA_METRICAS_ENTRANTE=${PORTA_METRICAS_ENTRANTE:-29546}
rbbcli() { em "$SN" executar "rbb-cli $*" ./rbb-cli "$@"; }
LOG_PERM_NOVO="$SN/volumes/novo/logs/besu_permissionamento.log"
LOG_PERM_ENT="$SN/volumes/entrante/logs/besu_permissionamento.log"

passo "Preparar o nó entrante: Besu ${BESU_VERSAO_PLUGIN} + plugin, Forest, discovery desligado, static-node para o nó 'novo'"
rbbcli node create entrante
K_ENT=$(sed 's/^0x//' "$SN/.env.configs/nodes/entrante/key.pub")
K_NOVO=$(sed 's/^0x//' "$SN/.env.configs/nodes/novo/key.pub")
fato no.entrante.chave_publica "0x$K_ENT"
rbbcli config set "nodes.entrante.ports+=[\"${PORTA_ENTRANTE}:8545\"]"
rbbcli config set nodes.entrante.environment.BESU_DISCOVERY_ENABLED=false
rbbcli config set 'nodes.entrante.environment.BESU_DATA_STORAGE_FORMAT="FOREST"'
printf '[\n"enode://%s@novo:30303"\n]\n' "$K_NOVO" > "$SN/volumes/entrante/static-nodes.json"
rbbcli config render-templates
cat >> "$SN/docker-compose.override.yml" <<EOF
  entrante:
    image: ${BESU_IMAGEM_PLUGIN}
    volumes:
      - ${TRAB}/plugin/besu-plugin-permissioning.jar:/opt/besu/plugins/besu-plugin-permissioning.jar:ro
    ports:
      - ${PORTA_METRICAS_ENTRANTE}:9545
EOF
cp "$SN/docker-compose.override.yml" "$EXEC_DIR/docker-compose.override.yml"
em "$SN" executar "configuração efetiva do nó entrante" docker compose config entrante
cp "$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log" "$EXEC_DIR/compose-entrante-efetivo.txt"

em "$SP" executar "consultar se o entrante está cadastrado" node node-rules-v2.js isNodeActive "0x${K_ENT:0:64}" "0x${K_ENT:64:64}"
verificar T-08a "entrante NÃO está ativo no NodeRulesV2" "ativo: false" \
  "$(grep -o 'ativo: [a-z]*' "$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log" | tail -1)"

LINHAS_NOVO_ANTES=$(wc -l < "$LOG_PERM_NOVO" | tr -d ' ')
log_novo_depois() { tail -n +"$((LINHAS_NOVO_ANTES + 1))" "$LOG_PERM_NOVO" 2>/dev/null; }
conta_novo() { log_novo_depois | grep -c "$1" || true; }

passo "Subir o entrante (sem cadastro) e observar por 90 s"
em "$SN" executar "subir entrante" docker compose up -d entrante
esperar_ate "RPC do entrante" 180 responde "$PORTA_ENTRANTE" || abortar "entrante não respondeu"
fato t08.versao_entrante "$(rpc "$PORTA_ENTRANTE" web3_clientVersion | jq -r .result)"
max_pares=0
for i in $(seq 1 18); do p=$(pares "$PORTA_ENTRANTE"); [ -n "$p" ] && [ "$p" -gt "$max_pares" ] && max_pares=$p; sleep 5; done

info "log de permissionamento do nó 'novo' (plugin) sobre o entrante:"
log_novo_depois | grep "enode://$K_ENT" | grep -v Checking | head -3 | cut -c1-240 | sed 's/^/    │ /'
info "log de permissionamento do PRÓPRIO entrante (plugin) — decisões e erros:"
grep -v Checking "$LOG_PERM_ENT" 2>/dev/null | grep -E "Rejected|Permitted|Could not resolve|failed|Resolved|ERROR|WARN" | head -6 | cut -c1-240 | sed 's/^/    │ /'
fato t08.entrante_recusou_propria_saida_antes_do_cadastro "$(grep -c "Rejected enode://$K_ENT.*-> enode://$K_NOVO" "$LOG_PERM_ENT" 2>/dev/null || true) linha(s)"

verificar T-08b "entrante sem nenhum par durante 90 s" "0" "$max_pares"
verificar_que T-08c "plugin do nó 'novo' recusou o entrante (log TRACE do 'novo')" \
  "≥ 1 linha 'Rejected enode://<entrante>' no 'novo'" "$(conta_novo "Rejected enode://$K_ENT") linha(s)" \
  test "$(conta_novo "Rejected enode://$K_ENT")" -ge 1
verificar T-08d "entrante parado no bloco 0" "0" "$(bloco_atual "$PORTA_ENTRANTE")"

passo "Cadastrar o entrante no NodeRulesV2"
em "$SP" executar "addLocalNode entrante (Writer)" node node-rules-v2.js addLocalNode "0x${K_ENT:0:64}" "0x${K_ENT:64:64}" Writer entrante
em "$SP" executar "consultar se o entrante está cadastrado" node node-rules-v2.js isNodeActive "0x${K_ENT:0:64}" "0x${K_ENT:64:64}"
verificar T-08e "entrante ativo no NodeRulesV2 após o cadastro" "ativo: true" \
  "$(grep -o 'ativo: [a-z]*' "$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log" | tail -1)"
estado E5 "E4 + nó 'entrante' (Besu ${BESU_VERSAO_PLUGIN} com plugin, sincronizando desde o gênesis) cadastrado"
LINHAS_ENT_CADASTRO=$(wc -l < "$LOG_PERM_ENT" 2>/dev/null | tr -d ' ')

passo "Esperar o entrante conectar (até 3 min) e baixar a cadeia (até 3 min)"
t0=$SECONDS
if esperar_ate "entrante conectar" 180 tem_pares "$PORTA_ENTRANTE" 1; then
  fato t08.segundos_ate_conectar "$((SECONDS - t0))"
  esperar_ate "entrante sincronizar" 180 acompanha "$PORTA_VALIDATOR" "$PORTA_ENTRANTE" || true
fi
BV=$(bloco_atual "$PORTA_VALIDATOR"); BE=$(bloco_atual "$PORTA_ENTRANTE")
fato t08.bloco_validator "$BV"
fato t08.bloco_entrante "$BE"

info "log de permissionamento do PRÓPRIO entrante após o cadastro — decisões e erros (até 8 linhas):"
tail -n +"$(( ${LINHAS_ENT_CADASTRO:-0} + 1 ))" "$LOG_PERM_ENT" 2>/dev/null | grep -v Checking \
  | grep -E "Rejected|Permitted|Could not resolve|failed|Resolved|ERROR|WARN" | head -8 | cut -c1-240 | sed 's/^/    │ /'
info "console do entrante — importação de blocos e erros (até 10 linhas):"
( cd "$SN" && docker compose logs entrante 2>/dev/null ) | grep -i -E "invalid|not authorized|permission|Imported|import failed|BadBlock|bad block|ERROR" \
  | tail -10 | cut -c1-240 | sed 's/^/    │ /'
mkdir -p "$EXEC_DIR/nos"; ( cd "$SN" && docker compose logs --timestamps entrante > "$EXEC_DIR/nos/entrante-console-t08.log" 2>&1 )

verificar_que T-08f "entrante conectado após o cadastro" "≥ 1 par" "$(pares "$PORTA_ENTRANTE") par(es)" tem_pares "$PORTA_ENTRANTE" 1
verificar_que T-08g "plugin do nó 'novo' passou a permitir o entrante" \
  "≥ 1 linha 'Permitted enode://<entrante>' no 'novo'" "$(conta_novo "Permitted enode://$K_ENT") linha(s)" \
  test "$(conta_novo "Permitted enode://$K_ENT")" -ge 1
verificar_que T-08h "entrante baixou a cadeia inteira (FULL desde o gênesis)" \
  "entrante a ≤ 1 bloco do validator" "validator $BV, entrante ${BE:-?}" \
  test -n "$BE" -a $(( BV - ${BE:-0} )) -le 1
