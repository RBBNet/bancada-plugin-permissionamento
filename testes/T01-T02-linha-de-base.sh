#!/usr/bin/env bash
# T-01 e T-02: linha de base do permissionamento NATIVO de contas no estado E2.
# Referência para comparar, mais adiante, com o comportamento do plugin.

fase "Testes T-01 e T-02: linha de base do permissionamento nativo de contas (estado ${ESTADO_ATUAL})"
source "$RAIZ/lib/contas-teste.env"
RPC_W="http://localhost:${PORTA_WRITER}"

passo "T-01: conta permitida (GLOBAL_ADMIN da Org 1) envia transação pelo writer"
R=$(node "$RAIZ/ferramentas/tx.js" "$RPC_W" "$CONTA_ADMIN_CHAVE")
echo "$R" >> "$EXEC_DIR/transacoes.jsonl"
verificar T-01 "transação de conta permitida, enviada pelo writer" "MINERADA, status 1" \
  "$(jq -r 'if .resultado=="MINERADA" then "MINERADA, status \(.status)" else "RECUSADA: \(.codigo) \(.erro)" end' <<<"$R")" "$R"

passo "T-02: conta nunca cadastrada (gerada na hora) envia transação pelo writer"
R=$(node "$RAIZ/ferramentas/tx.js" "$RPC_W" aleatoria)
echo "$R" >> "$EXEC_DIR/transacoes.jsonl"
verificar T-02 "transação de conta não cadastrada, enviada pelo writer" \
  'RECUSADA: -32007 Sender account not authorized to send transactions' \
  "$(jq -r 'if .resultado=="RECUSADA" then "RECUSADA: \(.codigo) \(.erro)" else "MINERADA no bloco \(.bloco)" end' <<<"$R")" "$R"
