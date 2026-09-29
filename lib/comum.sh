#!/usr/bin/env bash
# Funções comuns da bancada: registro de passos, verificações (esperado × obtido), espera com
# limite de tempo, chamadas RPC e gravação de evidências.
#
# Toda verificação grava uma linha em $EXEC_DIR/verificacoes.jsonl e todo fato relevante
# (endereço, bloco, hash, versão) grava uma linha em $EXEC_DIR/fatos.jsonl. O relatório final
# é gerado só a partir desses dois arquivos.

set -o pipefail

NO_GITHUB="${GITHUB_ACTIONS:-false}"
FALHAS=${FALHAS:-0}

agora() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# ---------------------------------------------------------------- saída
fase() {
  local titulo="$1"
  [ "$NO_GITHUB" = "true" ] && echo "::endgroup::" 2>/dev/null
  echo
  echo "════════════════════════════════════════════════════════════════════"
  echo "  $titulo"
  echo "════════════════════════════════════════════════════════════════════"
  [ "$NO_GITHUB" = "true" ] && echo "::group::$titulo"
  jq -cn --arg t "$(agora)" --arg f "$titulo" '{tipo:"fase", instante:$t, fase:$f}' >> "$EXEC_DIR/fatos.jsonl"
}

passo() { echo; echo "▶ [$(agora)] $*"; }
info()  { echo "  · $*"; }
desvio() {
  # Diferença deliberada em relação ao roteiro oficial da RBB, sempre justificada.
  echo "  ⚠ DESVIO DO ROTEIRO: $*"
  jq -cn --arg t "$(agora)" --arg d "$*" '{tipo:"desvio", instante:$t, descricao:$d}' >> "$EXEC_DIR/fatos.jsonl"
}
abortar() {
  echo "✘ ABORTADO: $*" >&2
  jq -cn --arg t "$(agora)" --arg d "$*" '{tipo:"aborto", instante:$t, motivo:$d}' >> "$EXEC_DIR/fatos.jsonl"
  exit 2
}

# Executa um comando mostrando-o, com a saída completa em $EXEC_DIR/comandos/NNN.log
# e as últimas linhas na tela. Aborta se falhar.
N_CMD=0
executar() {
  local descricao="$1"; shift
  N_CMD=$((N_CMD + 1))
  local arq; arq=$(printf '%s/comandos/%03d.log' "$EXEC_DIR" "$N_CMD")
  mkdir -p "$EXEC_DIR/comandos"
  { echo "# $descricao"; echo "# dir: $PWD"; echo "\$ $*"; echo "# início: $(agora)"; } > "$arq"
  echo "  \$ $*"
  if "$@" >> "$arq" 2>&1; then
    echo "# fim: $(agora) — saída 0" >> "$arq"
    tail -n "${LINHAS_SAIDA:-3}" "$arq" | grep -v '^# ' | sed 's/^/    │ /'
  else
    local rc=$?
    echo "# fim: $(agora) — saída $rc" >> "$arq"
    tail -n 30 "$arq" | sed 's/^/    │ /'
    abortar "$descricao (saída $rc; ver comandos/$(basename "$arq"))"
  fi
}

# ---------------------------------------------------------------- fatos e verificações
# fato <chave> <valor> — registra um dado da execução (endereço, bloco, versão...)
fato() {
  jq -cn --arg t "$(agora)" --arg k "$1" --arg v "$2" '{tipo:"fato", instante:$t, chave:$k, valor:$v}' >> "$EXEC_DIR/fatos.jsonl"
  info "$1 = $2"
}

# verificar <id> <descrição> <esperado> <obtido> [dados-json]
# Compara textos exatamente. Registra e imprime o veredito; não aborta (conta falhas).
verificar() {
  local id="$1" desc="$2" esperado="$3" obtido="$4" dados="${5:-null}"
  local ok=false
  [ "$esperado" = "$obtido" ] && ok=true
  _registrar_verificacao "$id" "$desc" "$esperado" "$obtido" "$ok" "$dados"
}

# verificar_que <id> <descrição> <esperado-legível> <obtido> <comando de teste...>
# Para condições que não são igualdade exata (ex.: "≥ 2"). O comando decide o veredito.
verificar_que() {
  local id="$1" desc="$2" esperado="$3" obtido="$4"; shift 4
  local ok=false
  "$@" && ok=true
  _registrar_verificacao "$id" "$desc" "$esperado" "$obtido" "$ok" null
}

_registrar_verificacao() {
  local id="$1" desc="$2" esperado="$3" obtido="$4" ok="$5" dados="$6"
  echo "  ┌ [$id] $desc"
  echo "  │ esperado: $esperado"
  echo "  │ obtido:   $obtido"
  # Dados brutos: a saída exata da ferramenta que fez o teste (ex.: remetente, hash, bloco)
  [ "$dados" != "null" ] && echo "  │ dados brutos: $dados"
  if [ "$ok" = true ]; then echo "  └ ✔ OK"; else echo "  └ ✘ FALHOU"; FALHAS=$((FALHAS + 1)); fi
  jq -cn --arg t "$(agora)" --arg id "$id" --arg d "$desc" --arg e "$esperado" --arg o "$obtido" \
    --argjson ok "$ok" --argjson dados "$dados" --arg estado "${ESTADO_ATUAL:-}" \
    '{instante:$t, id:$id, descricao:$d, estado:$estado, esperado:$e, obtido:$o, ok:$ok, dados:$dados}' \
    >> "$EXEC_DIR/verificacoes.jsonl"
  [ "$NO_GITHUB" = "true" ] && [ "$ok" != true ] && echo "::error title=$id::$desc — esperado: $esperado; obtido: $obtido"
  return 0
}

# estado <id> <descrição> — marca a transição da rede para um novo estado (E0, E1, ...)
estado() {
  ESTADO_ATUAL="$1"
  local bloco; bloco=$(bloco_atual "${RPC_REF:-$PORTA_VALIDATOR}")
  echo; echo "  ◆ ESTADO $1 a partir do bloco $bloco: $2"
  jq -cn --arg t "$(agora)" --arg e "$1" --arg d "$2" --argjson b "${bloco:-null}" \
    '{tipo:"estado", instante:$t, estado:$e, descricao:$d, bloco:$b}' >> "$EXEC_DIR/fatos.jsonl"
}

# ---------------------------------------------------------------- rede
rpc() {  # rpc <porta> <método> [params-json]
  curl -s -m 10 -X POST -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":${3:-[]},\"id\":1}" "localhost:$1"
}
bloco_atual() { local r; r=$(rpc "$1" eth_blockNumber | jq -r '.result // empty' 2>/dev/null); [ -n "$r" ] && echo $((r)); }
pares()       { local r; r=$(rpc "$1" net_peerCount   | jq -r '.result // empty' 2>/dev/null); [ -n "$r" ] && echo $((r)); }

# esperar_ate <descrição> <segundos> <comando...> — repete o comando até dar certo ou estourar o prazo
esperar_ate() {
  local desc="$1" limite="$2"; shift 2
  local inicio=$SECONDS
  while ! "$@" >/dev/null 2>&1; do
    if (( SECONDS - inicio >= limite )); then
      info "prazo de ${limite}s esgotado esperando: $desc"
      return 1
    fi
    sleep 2
  done
  info "ok em $((SECONDS - inicio))s: $desc"
}

# em <diretório> <comando...> — executa no diretório SEM subshell (para que abortar/contadores valham)
em() {
  local d="$1"; shift
  pushd "$d" >/dev/null || abortar "diretório inexistente: $d"
  "$@"
  local rc=$?
  popd >/dev/null
  return $rc
}

# Condições reavaliadas a cada tentativa (para usar com esperar_ate)
tem_pares()   { local n; n=$(pares "$1"); [ -n "$n" ] && [ "$n" -ge "$2" ]; }
responde()    { [ -n "$(bloco_atual "$1")" ]; }
# acompanha <porta-ref> <porta>... — cada porta está no máximo 1 bloco atrás da referência (e > 0)
acompanha() {
  local ref; ref=$(bloco_atual "$1"); shift
  [ -n "$ref" ] || return 1
  local p b
  for p in "$@"; do b=$(bloco_atual "$p"); [ -n "$b" ] && [ "$b" -gt 0 ] && [ $((ref - b)) -le 1 ] || return 1; done
}
minusculo() { echo "$1" | tr 'A-F' 'a-f'; }
