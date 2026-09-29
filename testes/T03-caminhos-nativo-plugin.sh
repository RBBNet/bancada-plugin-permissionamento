#!/usr/bin/env bash
# T-03: compara, em estados históricos da própria cadeia, o que respondem o caminho do
# permissionamento NATIVO do Besu (Ingress.connectionAllowed / transactionAllowed) e o caminho
# que o PLUGIN usa (Ingress.getContractAddress("rules") + Rules; Rules = 0 → recusa).
#
# ATENÇÃO: testa a lógica dos contratos via eth_call. NÃO executa um nó com o plugin.
# Possível porque os nós usam Forest, que guarda o estado histórico.

fase "Teste T-03: nativo × plugin em blocos anteriores e posteriores às regras (consulta a estados históricos)"
SN="$TRAB/start-network"
V=$(cat "$SN/.env.configs/nodes/validator/key.pub"); B=$(cat "$SN/.env.configs/nodes/boot/key.pub")
fatov() { jq -r --arg k "$1" 'select(.tipo=="fato" and .chave==$k) | .valor' "$EXEC_DIR/fatos.jsonl" | tail -1; }
BN=$(fatov bloco.primeiro_com_regras_nos); BC=$(fatov bloco.primeiro_com_regras_contas)
B_E2=$(bloco_atual "$PORTA_VALIDATOR")
info "NodeIngress com regras a partir do bloco $BN; AccountIngress a partir do bloco $BC"

caso() {  # caso <id> <bloco> <descrição> <esperado: nativo_no nativo_tx plugin_no plugin_tx>
  local R; R=$(node "$RAIZ/ferramentas/ingress.js" caminhos "http://localhost:$PORTA_VALIDATOR" "$2" "$V" "$B")
  echo "$R" >> "$EXEC_DIR/caminhos.jsonl"
  verificar "$1" "bloco $2 — $3 (nativo nó/tx | plugin nó/tx)" "$4" \
    "$(jq -r '"\(.nativo_no)/\(.nativo_tx) | \(.plugin_no)/\(.plugin_tx)"' <<<"$R")" "$R"
}
caso T-03a $((BN - 1)) "antes de qualquer regra"           "permite/permite | recusa/recusa"
if [ "$BC" -gt "$BN" ]; then
  caso T-03b "$BN"     "só NodeRules apontado"             "permite/permite | permite/recusa"
fi
caso T-03c "$BC"       "gen01 completo"                    "permite/recusa | permite/recusa"
caso T-03d "$B_E2"     "gen02 (estado E2)"                 "permite/recusa | permite/recusa"
