#!/usr/bin/env bash
# T-10: nó com o plugin e configuração ERRADA (endereço do Ingress de contas ausente).
#
# Especificação (o que deveria acontecer): diante de configuração obrigatória ausente, o nó deveria
# se recusar a subir, com erro claro — e não operar de forma degradada.
# Previsão (leitura do código do plugin v1.0.0-rc.1): o Besu sobe normalmente; o plugin só registra
# ERROR e entra em "fail-close" para transações. Como o plugin também é consultado na IMPORTAÇÃO de
# blocos, o nó passa a rejeitar blocos válidos que contenham transações e para de acompanhar a cadeia.
# No fim, a configuração é restaurada e verificamos se o nó se recupera.

fase "Teste T-10: nó com plugin e endereço do Ingress de contas ausente"
ESTADO_ATUAL="E6"
SN="$TRAB/start-network"
source "$RAIZ/lib/contas-teste.env"
PORTA_NOVO=${PORTA_NOVO:-20004}
REF_DEFEITO="plugin ${PLUGIN_VERSAO}: configuração obrigatória ausente não impede a subida e bloqueia a importação de blocos${ISSUE_PLUGIN_CONFIG_AUSENTE:+ — $ISSUE_PLUGIN_CONFIG_AUSENTE}"
dc_t10() { docker compose -f docker-compose.yml -f docker-compose.override.yml -f docker-compose.t10.yml "$@"; }

passo "Liberar memória: parar o observador do T-09 (já parado no bloco da 1ª transação)"
em "$SN" executar "parar observador" docker compose stop observador

passo "Reconfigurar o nó 'novo' SEM o endereço do Ingress de contas (variável vazia)"
cat > "$SN/docker-compose.t10.yml" <<'EOF'
services:
  novo:
    environment:
      BESU_PERMISSIONS_ACCOUNTS_CONTRACT_ADDRESS: ""
EOF
cp "$SN/docker-compose.t10.yml" "$EXEC_DIR/docker-compose.t10.yml"
sed 's/^/    │ /' "$SN/docker-compose.t10.yml"
em "$SN" executar "parar nó novo" docker compose stop novo
B_ANTES=$(bloco_atual "$PORTA_VALIDATOR")
em "$SN" executar "subir nó novo com a configuração errada" dc_t10 up -d novo
estado E7 "E6 com o nó 'novo' (plugin) sem BESU_PERMISSIONS_ACCOUNTS_CONTRACT_ADDRESS"
ESTADO_ATUAL="E7"

sobe=não; esperar_ate "RPC do nó novo (com configuração errada)" 120 responde "$PORTA_NOVO" && sobe=sim
sleep 5
CONSOLE=$(cd "$SN" && docker compose logs --since 3m novo 2>/dev/null)
info "linhas do plugin no console do nó novo:"
grep -E "Missing BESU_PERMISSIONS|Fail-close|fail-close|Account Ingress|Permissioning Plugin" <<<"$CONSOLE" | head -6 | cut -c1-220 | sed 's/^/    │ /'
reproduzir_defeito "$REF_DEFEITO" T-10a "com configuração obrigatória ausente, o nó SOBE e responde normalmente (especificação: recusar-se a subir)" \
  "sim" "$sobe"
verificar_que T-10b "plugin registra o problema no log (ERROR/WARN de configuração ausente)" \
  "≥ 1 linha 'Missing BESU_PERMISSIONS_ACCOUNTS_CONTRACT_ADDRESS' ou 'Account Ingress Address is unconfigured'" \
  "$(grep -c -E 'Missing BESU_PERMISSIONS_ACCOUNTS_CONTRACT_ADDRESS|Account Ingress Address is unconfigured' <<<"$CONSOLE" || true) linha(s)" \
  test "$(grep -c -E 'Missing BESU_PERMISSIONS_ACCOUNTS_CONTRACT_ADDRESS|Account Ingress Address is unconfigured' <<<"$CONSOLE" || true)" -ge 1
esperar_ate "nó novo reconectar e acompanhar a cadeia (antes de qualquer transação nova)" 180 acompanha "$PORTA_VALIDATOR" "$PORTA_NOVO" || true

passo "Conta PERMITIDA envia transação pelo nó mal configurado"
R=$(node "$RAIZ/ferramentas/tx.js" "http://localhost:${PORTA_NOVO}" "$CONTA_ADMIN_CHAVE")
echo "$R" >> "$EXEC_DIR/transacoes.jsonl"
reproduzir_defeito "$REF_DEFEITO" T-10c "transação de conta PERMITIDA é recusada pelo nó mal configurado" \
  "RECUSADA: -32007 Sender account not authorized to send transactions" \
  "$(jq -r .resumo <<<"$R")" "$R"

passo "Conta PERMITIDA envia transação pelo writer (nativo); o bloco com ela chega ao nó mal configurado"
R=$(node "$RAIZ/ferramentas/tx.js" "http://localhost:${PORTA_WRITER}" "$CONTA_ADMIN_CHAVE")
echo "$R" >> "$EXEC_DIR/transacoes.jsonl"
BTX=$(jq -r '.bloco // empty' <<<"$R")
verificar T-10d "transação de conta permitida, pelo writer (nativo), minerada normalmente" "MINERADA, status 1" \
  "$(jq -r .resumo <<<"$R")" "$R"
sleep 30
BN=$(bloco_atual "$PORTA_NOVO"); BV=$(bloco_atual "$PORTA_VALIDATOR")
CONSOLE=$(cd "$SN" && docker compose logs --since 5m novo 2>/dev/null)
info "console do nó novo — rejeição do bloco:"
grep -E "Invalid block ${BTX:-x} |BREACH_OF_PROTOCOL|fail-close" <<<"$CONSOLE" | head -4 | cut -c1-240 | sed 's/^/    │ /'
reproduzir_defeito "$REF_DEFEITO" T-10e "nó mal configurado PARA no bloco anterior ao da transação válida (bloco ${BTX:-?}); validator no $BV" \
  "$(( ${BTX:-1} - 1 ))" "${BN:-?}"
reproduzir_defeito_que "$REF_DEFEITO" T-10f "nó mal configurado declara inválido o bloco válido ${BTX:-?}" \
  "≥ 1 'Invalid block ${BTX:-?} … not on the Account Allowlist'" \
  "$(grep -c "Invalid block ${BTX:-x} .*not on the Account Allowlist" <<<"$CONSOLE" || true) linha(s)" \
  test "$(grep -c "Invalid block ${BTX:-x} .*not on the Account Allowlist" <<<"$CONSOLE" || true)" -ge 1

passo "Restaurar a configuração correta e verificar a recuperação"
mkdir -p "$EXEC_DIR/nos"; ( cd "$SN" && docker compose logs --timestamps novo > "$EXEC_DIR/nos/novo-console-t10.log" 2>&1 )
em "$SN" executar "parar nó novo" docker compose stop novo
em "$SN" executar "subir nó novo com a configuração correta" docker compose up -d novo
estado E8 "E6 restaurado: nó 'novo' (plugin) de volta à configuração correta"
ESTADO_ATUAL="E8"
esperar_ate "RPC do nó novo" 120 responde "$PORTA_NOVO" || true
t0=$SECONDS
esperar_ate "nó novo voltar a acompanhar a cadeia" 240 acompanha "$PORTA_VALIDATOR" "$PORTA_NOVO" || true
fato t10.segundos_ate_recuperar "$((SECONDS - t0))"
BN=$(bloco_atual "$PORTA_NOVO"); BV=$(bloco_atual "$PORTA_VALIDATOR")
verificar_que T-10g "com a configuração corrigida, o nó se recupera sozinho e volta a acompanhar a cadeia" \
  "diferença ≤ 1 bloco" "validator $BV, novo ${BN:-?}" acompanha "$PORTA_VALIDATOR" "$PORTA_NOVO"
