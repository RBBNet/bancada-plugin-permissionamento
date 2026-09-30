#!/usr/bin/env bash
# T-09: entrada de um nó com o plugin como OBSERVER — pelo boot configurado como BOOTNODE, e não por
# static-node (é assim que observers entram na RBB, pelo observer-boot).
#
# Por que importa: o Besu libera conexões com bootnodes enquanto o nó não tem outros pares
# (InsufficientPeersPermissioningProvider), independentemente do permissionamento. Isso contorna,
# de forma legítima, o impasse de conexão do T-08 e permite ver o passo seguinte da sincronização
# FULL: importar os primeiros blocos com transações. As primeiras transações da cadeia (deploy do
# gen01) foram enviadas quando ainda NÃO havia AccountRules; o permissionamento nativo as aceitava
# (o Ingress responde "permitido" sem Rules), mas o plugin trata "Rules = 0" como recusa (T-03).
# Previsão: o nó conecta, importa até o bloco anterior à 1ª transação e rejeita o bloco seguinte.
#
# Especificação (o que deveria acontecer): conecta e baixa a cadeia inteira.
#
# DEMONSTRAÇÃO PERMANENTE DE DEFEITO do plugin (confirmado em 30/09/2026 com a v1.0.0-rc.1): o nó
# conecta pela exceção de bootnode, importa os blocos até o anterior à 1ª transação e, ao importar o
# bloco da 1ª transação, o plugin resolve AccountRules = 0 no estado do bloco anterior ("Could not
# resolve AccountRules contract address. Rejecting transaction."); o Besu declara o bloco inválido
# ("Sender ... is not on the Account Allowlist"), desconecta o par por BREACH_OF_PROTOCOL e a
# sincronização para. Os itens 🐞 esperam esse comportamento defeituoso.

fase "Teste T-09: nó com plugin entrando como observer (bootnode) não baixa a cadeia (🐞 demonstração de defeito do plugin ${PLUGIN_VERSAO})"
REF_DEFEITO="plugin ${PLUGIN_VERSAO}: AccountRules não resolvido no estado anterior às regras${ISSUE_PLUGIN_NODERULES_GENESIS:+ — $ISSUE_PLUGIN_NODERULES_GENESIS}"
ESTADO_ATUAL="E5"
SN="$TRAB/start-network"
SP="$TRAB/scripts-permissionamento"
PORTA_OBS=${PORTA_OBS:-20006}
rbbcli() { em "$SN" executar "rbb-cli $*" ./rbb-cli "$@"; }
LOG_PERM_OBS="$SN/volumes/observador/logs/besu_permissionamento.log"

passo "Localizar na cadeia o primeiro bloco com transações (deploy do gen01)"
PRIMEIRO_TX=""
for b in $(seq 1 60); do
  n=$(rpc "$PORTA_VALIDATOR" eth_getBlockTransactionCountByNumber "[\"$(printf '0x%x' "$b")\"]" | jq -r .result)
  [ "$n" != "0x0" ] && [ -n "$n" ] && [ "$n" != "null" ] && { PRIMEIRO_TX=$b; break; }
done
fato t09.primeiro_bloco_com_transacoes "${PRIMEIRO_TX:-não encontrado}"
[ -n "$PRIMEIRO_TX" ] || abortar "não achei o primeiro bloco com transações"
TX0=$(rpc "$PORTA_VALIDATOR" eth_getBlockByNumber "[\"$(printf '0x%x' "$PRIMEIRO_TX")\",true]" | jq -c '.result.transactions[0] | {hash, from, to}')
fato t09.primeira_transacao "$TX0"
R=$(node "$RAIZ/ferramentas/ingress.js" regras "http://localhost:$PORTA_VALIDATOR" $((PRIMEIRO_TX - 1)))
fato t09.regras_no_bloco_anterior "$R"

passo "Preparar o observador: Besu ${BESU_VERSAO_PLUGIN} + plugin, Forest, discovery LIGADO, bootnode = boot"
rbbcli node create observador
K_OBS=$(sed 's/^0x//' "$SN/.env.configs/nodes/observador/key.pub")
K_BOOT=$(sed 's/^0x//' "$SN/.env.configs/nodes/boot/key.pub")
fato no.observador.chave_publica "0x$K_OBS"
rbbcli config set "nodes.observador.ports+=[\"${PORTA_OBS}:8545\"]"
rbbcli config set 'nodes.observador.environment.BESU_DATA_STORAGE_FORMAT="FOREST"'
rbbcli config set "nodes.observador.environment.BESU_BOOTNODES=\"enode://${K_BOOT}@boot:30303\""
rbbcli config render-templates
cat >> "$SN/docker-compose.override.yml" <<EOF2
  observador:
    image: ${BESU_IMAGEM_PLUGIN}
    volumes:
      - ${TRAB}/plugin/besu-plugin-permissioning.jar:/opt/besu/plugins/besu-plugin-permissioning.jar:ro
EOF2
cp "$SN/docker-compose.override.yml" "$EXEC_DIR/docker-compose.override.yml"
em "$SN" executar "configuração efetiva do observador" docker compose config observador
cp "$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log" "$EXEC_DIR/compose-observador-efetivo.txt"

passo "Cadastrar o observador no NodeRulesV2 ANTES de subir (tipo Observer)"
em "$SP" executar "addLocalNode observador (Observer)" node node-rules-v2.js addLocalNode "0x${K_OBS:0:64}" "0x${K_OBS:64:64}" Observer observador
em "$SP" executar "consultar se o observador está cadastrado" node node-rules-v2.js isNodeActive "0x${K_OBS:0:64}" "0x${K_OBS:64:64}"
verificar T-09a "observador ativo no NodeRulesV2" "ativo: true" \
  "$(grep -o 'ativo: [a-z]*' "$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log" | tail -1)"
estado E6 "E5 + 'observador' (Besu ${BESU_VERSAO_PLUGIN} com plugin, entrando pelo boot como bootnode) cadastrado"

passo "Subir o observador e acompanhar por até 4 min"
em "$SN" executar "subir observador" docker compose up -d observador
esperar_ate "RPC do observador" 180 responde "$PORTA_OBS" || abortar "observador não respondeu"
cheguei_bloco() { local b; b=$(bloco_atual "$PORTA_OBS"); [ -n "$b" ] && [ "$b" -ge "$1" ]; }
esperar_ate "observador importar blocos até o anterior à 1ª transação ($((PRIMEIRO_TX - 1)))" 180 cheguei_bloco $((PRIMEIRO_TX - 1)) || true
esperar_ate "observador sincronizar (especificação)" 120 acompanha "$PORTA_VALIDATOR" "$PORTA_OBS" || true
BV=$(bloco_atual "$PORTA_VALIDATOR"); BO=$(bloco_atual "$PORTA_OBS")
fato t09.bloco_validator "$BV"
fato t09.bloco_observador "$BO"

info "log de permissionamento do observador (plugin) — decisões e erros (até 10 linhas):"
grep -v Checking "$LOG_PERM_OBS" 2>/dev/null | grep -E "Rejected|Permitted|Could not resolve|Resolved|ERROR|denied|DENIED" \
  | head -10 | cut -c1-240 | sed 's/^/    │ /'
info "console do observador — importação de blocos e erros (até 12 linhas):"
( cd "$SN" && docker compose logs observador 2>/dev/null ) \
  | grep -i -E "invalid|not authorized|permission|import|bad block|BadBlock|ERROR|Imported #|Imported block" \
  | tail -12 | cut -c1-240 | sed 's/^/    │ /'
mkdir -p "$EXEC_DIR/nos"; ( cd "$SN" && docker compose logs --timestamps observador > "$EXEC_DIR/nos/observador-console-t09.log" 2>&1 )

CONSOLE_OBS=$(cd "$SN" && docker compose logs observador 2>/dev/null)
ADMIN=$(minusculo "$(jq -r .from <<<"$TX0")")
verificar_que T-09b "observador conectou ao boot pela exceção de bootnode ('Insufficient Peers: Permitted') e importou blocos" \
  "≥ 1 linha 'Insufficient Peers: Permitted' e bloco > 0" \
  "$(grep -c 'Insufficient Peers: Permitted' "$LOG_PERM_OBS" 2>/dev/null || true) linha(s); bloco ${BO:-?}" \
  test "$(grep -c 'Insufficient Peers: Permitted' "$LOG_PERM_OBS" 2>/dev/null || true)" -ge 1 -a "${BO:-0}" -gt 0
reproduzir_defeito "$REF_DEFEITO" T-09c "observador PARA no bloco anterior à 1ª transação da cadeia (especificação: acompanhar o validator, hoje no $BV)" \
  "$((PRIMEIRO_TX - 1))" "${BO:-?}"
reproduzir_defeito_que "$REF_DEFEITO" T-09d "plugin recusa a 1ª transação da cadeia ao importar o bloco $PRIMEIRO_TX (AccountRules = 0 no estado anterior)" \
  "≥ 1 'Could not resolve AccountRules' no log do plugin e 'Invalid block $PRIMEIRO_TX' com 'Sender $ADMIN is not on the Account Allowlist'" \
  "$(grep -c 'Could not resolve AccountRules contract address' "$LOG_PERM_OBS" 2>/dev/null || true) 'Could not resolve AccountRules'; $(grep -c "Invalid block $PRIMEIRO_TX .*Sender $ADMIN is not on the Account Allowlist" <<<"$CONSOLE_OBS" || true) 'Invalid block $PRIMEIRO_TX … not on the Account Allowlist'" \
  test "$(grep -c 'Could not resolve AccountRules contract address' "$LOG_PERM_OBS" 2>/dev/null || true)" -ge 1 \
    -a "$(grep -c "Invalid block $PRIMEIRO_TX .*Sender $ADMIN is not on the Account Allowlist" <<<"$CONSOLE_OBS" || true)" -ge 1
reproduzir_defeito_que "$REF_DEFEITO" T-09e "Besu desconecta o par que enviou o bloco, por quebra de protocolo" \
  "≥ 1 'Invalid block detected (BREACH_OF_PROTOCOL). Disconnecting from sync target'" \
  "$(grep -c 'BREACH_OF_PROTOCOL). Disconnecting from sync target' <<<"$CONSOLE_OBS" || true) linha(s)" \
  test "$(grep -c 'BREACH_OF_PROTOCOL). Disconnecting from sync target' <<<"$CONSOLE_OBS" || true)" -ge 1
