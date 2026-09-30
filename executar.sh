#!/usr/bin/env bash
# Executa a bancada do início ao fim: prepara o ambiente, monta a rede no padrão da RBB,
# aplica o permissionamento (gen01 → gen02) e roda os testes. Ao final, sempre guarda os logs
# dos nós e gera o relatório em execucoes/<id>/resumo.md.
#
# Uso: ./executar.sh
#   MANTER_REDE=1 ./executar.sh    mantém a rede de pé ao final (para inspeção manual)
#
# Código de saída: 0 = todas as verificações passaram; 1 = alguma falhou; 2 = execução abortada.

set -u
RAIZ="$(cd "$(dirname "$0")" && pwd)"
source "$RAIZ/versoes.env"
source "$RAIZ/lib/comum.sh"

EXEC_ID="$(date -u '+%Y%m%d-%H%M%S')"
EXEC_DIR="$RAIZ/execucoes/$EXEC_ID"
TRAB="$EXEC_DIR/trabalho"        # clones, dependências e dados dos nós (não vai para os artefatos)
mkdir -p "$TRAB"
: > "$EXEC_DIR/fatos.jsonl"; : > "$EXEC_DIR/verificacoes.jsonl"

export COMPOSE_PROJECT_NAME="bancada-$(echo "$EXEC_ID" | tr -d '-')"
PORTA_VALIDATOR=${PORTA_VALIDATOR:-20001}
PORTA_BOOT=${PORTA_BOOT:-20002}
PORTA_WRITER=${PORTA_WRITER:-20003}

finalizar() {
  local rc=$?
  [ "$NO_GITHUB" = "true" ] && echo "::endgroup::"
  echo; echo "── Finalização ────────────────────────────────────────────────────"
  if [ -f "$TRAB/start-network/docker-compose.yml" ]; then
    mkdir -p "$EXEC_DIR/nos"
    for n in $(ls "$TRAB/start-network/volumes" 2>/dev/null); do
      (cd "$TRAB/start-network" && docker compose logs --timestamps "$n" > "$EXEC_DIR/nos/$n-console.log" 2>&1)
      [ -d "$TRAB/start-network/volumes/$n/logs" ] && cp -r "$TRAB/start-network/volumes/$n/logs" "$EXEC_DIR/nos/$n-arquivos"
    done
    echo "  · logs dos nós guardados em execucoes/$EXEC_ID/nos/"
    if [ "${MANTER_REDE:-0}" = "1" ]; then
      echo "  · MANTER_REDE=1: rede mantida de pé (projeto $COMPOSE_PROJECT_NAME, portas $PORTA_VALIDATOR/$PORTA_BOOT/$PORTA_WRITER)"
    else
      (cd "$TRAB/start-network" && docker compose down -v >/dev/null 2>&1)
      echo "  · rede derrubada"
      # clones, dependências e dados dos nós não são evidência e ocupam ~1 GB por execução
      rm -rf "$TRAB" 2>/dev/null && echo "  · pasta de trabalho removida (evidências preservadas)"
    fi
  fi
  bash "$RAIZ/lib/relatorio.sh" "$EXEC_DIR" > "$EXEC_DIR/resumo.md"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$EXEC_DIR/resumo.md" >> "$GITHUB_STEP_SUMMARY"
  local total ok
  total=$(jq -s '[.[] | select(.observacao != true)] | length' "$EXEC_DIR/verificacoes.jsonl")
  ok=$(jq -s '[.[] | select(.observacao != true and .ok)] | length' "$EXEC_DIR/verificacoes.jsonl")
  local obs; obs=$(jq -s '[.[] | select(.observacao == true)] | length' "$EXEC_DIR/verificacoes.jsonl")
  echo
  echo "════════════════════════════════════════════════════════════════════"
  if [ "$rc" -eq 2 ]; then
    echo "  EXECUÇÃO ABORTADA — $ok de $total verificações passaram antes da interrupção"
  elif [ "$ok" = "$total" ]; then
    echo "  RESULTADO: todas as $total verificações passaram"
  else
    echo "  RESULTADO: $((total - ok)) de $total verificações FALHARAM"; rc=1
  fi
  [ "$obs" -gt 0 ] && echo "  + $obs observação(ões) sobre componentes testados (ver relatório; não contam como falha)"
  echo "  relatório: execucoes/$EXEC_ID/resumo.md"
  echo "════════════════════════════════════════════════════════════════════"
  exit "$rc"
}
trap finalizar EXIT

echo "Bancada do plugin de permissionamento da RBB — execução $EXEC_ID"
for f in fases/00-preparar.sh fases/01-rede-e0.sh fases/02-gen01-e1.sh fases/03-gen02-e2.sh \
         testes/T01-T02-linha-de-base.sh testes/T03-caminhos-nativo-plugin.sh \
         testes/T04-permissionamento-no.sh testes/T05-T07-no-com-plugin.sh \
         testes/T08-no-entrante-com-plugin.sh testes/T09-observer-com-plugin.sh; do
  source "$RAIZ/$f"
done
