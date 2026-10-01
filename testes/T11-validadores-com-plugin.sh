#!/usr/bin/env bash
# T-11: validadores migrando para o plugin, um a um — o caminho real da mainnet.
#
# 1. A rede passa de 1 para 4 validadores. Os novos entram NATIVOS (Besu ${BESU_VERSAO_INICIAL}):
#    um validador novo já com o plugin não consegue entrar na rede (T-08/T-09, issue do plugin).
#    Cada um é cadastrado no NodeRulesV2 (Validator) e votado pelos validadores atuais
#    (qbft_proposeValidatorVote), como no roteiro da RBB. Com 4 validadores o QBFT tolera 1 falha.
# 2. Os 4 validadores são migrados para o Besu ${BESU_VERSAO_PLUGIN} + plugin, um por vez, mantendo
#    chave e banco. Após cada migração: a rede segue produzindo blocos, o validador migrado volta a
#    PROPOR blocos (o plugin também é consultado na montagem do bloco), transação permitida enviada a
#    ele é minerada e transação de conta não cadastrada enviada a ele é recusada.

fase "Teste T-11: 4 validadores, migrados um a um para o Besu ${BESU_VERSAO_PLUGIN} com o plugin"
ESTADO_ATUAL="E8"
SN="$TRAB/start-network"
SP="$TRAB/scripts-permissionamento"
source "$RAIZ/lib/contas-teste.env"
rbbcli() { em "$SN" executar "rbb-cli $*" ./rbb-cli "$@"; }
porta_de() { case "$1" in validator) echo "$PORTA_VALIDATOR";; v2) echo 20007;; v3) echo 20008;; v4) echo 20009;; esac; }
endereco_de() { minusculo "$(cat "$SN/.env.configs/nodes/$1/node.id")"; }
validadores() { rpc "$PORTA_VALIDATOR" qbft_getValidatorsByBlockNumber '["latest"]' | jq -r '.result | length'; }
tem_validadores() { [ "$(validadores)" = "$1" ]; }
# último bloco proposto por um endereço, nos últimos 100 blocos (qbft_getSignerMetrics)
ultimo_proposto() { rpc "$PORTA_VALIDATOR" qbft_getSignerMetrics | jq -r --arg a "$1" '[.result[] | select(.address==$a) | .lastProposedBlockNumber][0] // "0x0"' | xargs printf '%d\n'; }
propos_depois_de() { [ "$(ultimo_proposto "$1")" -gt "$2" ]; }

passo "Liberar memória: parar os nós que já cumpriram seu papel (entrante, observador, novo)"
PARAR=$(cd "$SN" && docker compose config --services 2>/dev/null | grep -x -E 'entrante|observador|novo' | tr '\n' ' ')
[ -n "$PARAR" ] && em "$SN" executar "parar $PARAR" docker compose stop $PARAR

passo "Criar e cadastrar os validadores v2, v3 e v4 (nativos, Besu ${BESU_VERSAO_INICIAL})"
K_BOOT=$(sed 's/^0x//' "$SN/.env.configs/nodes/boot/key.pub")
K_VAL=$(sed 's/^0x//' "$SN/.env.configs/nodes/validator/key.pub")
anteriores="enode://${K_BOOT}@boot:30303 enode://${K_VAL}@validator:30303"
for v in v2 v3 v4; do
  rbbcli node create "$v"
  K=$(sed 's/^0x//' "$SN/.env.configs/nodes/$v/key.pub")
  fato "no.$v.endereco" "$(cat "$SN/.env.configs/nodes/$v/node.id")"
  rbbcli config set "nodes.$v.ports+=[\"$(porta_de "$v"):8545\"]"
  rbbcli config set "nodes.$v.environment.BESU_DISCOVERY_ENABLED=false"
  rbbcli config set "nodes.$v.environment.BESU_DATA_STORAGE_FORMAT=\"FOREST\""
  # static-nodes: boot e todos os validadores anteriores (os validadores da RBB se conectam entre si)
  printf '[\n%s\n]\n' "$(for e in $anteriores; do printf '"%s",\n' "$e"; done | sed '$ s/,$//')" > "$SN/volumes/$v/static-nodes.json"
  anteriores="$anteriores enode://${K}@${v}:30303"
  em "$SP" executar "addLocalNode $v (Validator)" node node-rules-v2.js addLocalNode "0x${K:0:64}" "0x${K:64:64}" Validator "$v"
done
rbbcli config render-templates

passo "Subir v2, v3 e v4 (um de cada vez) e votar em cada um"
n=1
for v in v2 v3 v4; do
  em "$SN" executar "subir $v" docker compose up -d "$v"
  esperar_ate "RPC de $v" 180 responde "$(porta_de "$v")" || abortar "$v não respondeu"
  esperar_ate "$v sincronizar" 180 acompanha "$PORTA_VALIDATOR" "$(porta_de "$v")" || abortar "$v não sincronizou"
  A=$(endereco_de "$v")
  for eleitor in validator v2 v3; do
    [ "$eleitor" = "$v" ] && break
    [ "$eleitor" != validator ] && ! rpc "$PORTA_VALIDATOR" qbft_getValidatorsByBlockNumber '["latest"]' | jq -e --arg a "$(endereco_de "$eleitor")" '.result | index($a)' >/dev/null && continue
    R=$(rpc "$(porta_de "$eleitor")" qbft_proposeValidatorVote "[\"$A\", true]" | jq -c '.result // .error')
    info "voto de $eleitor em $v ($A): $R"
  done
  n=$((n + 1))
  esperar_ate "$v entrar no conjunto de validadores ($n)" 180 tem_validadores "$n" || abortar "$v não foi aceito como validador"
done
VALS=$(rpc "$PORTA_VALIDATOR" qbft_getValidatorsByBlockNumber '["latest"]' | jq -c .result)
verificar T-11a "conjunto de validadores após os votos" "4" "$(validadores)" "{\"validadores\":$VALS}"
estado E9 "E8 + validadores v2, v3 e v4 (nativos): 4 validadores QBFT, todos no Besu ${BESU_VERSAO_INICIAL}"
ESTADO_ATUAL="E9"
B0=$(bloco_atual "$PORTA_VALIDATOR")
for v in validator v2 v3 v4; do
  esperar_ate "$v propor um bloco" 90 propos_depois_de "$(endereco_de "$v")" "$B0" || true
done
todos=sim; for v in validator v2 v3 v4; do propos_depois_de "$(endereco_de "$v")" "$B0" || todos="não ($v)"; done
verificar T-11b "os 4 validadores (nativos) propõem blocos" "sim" "$todos"

migrar_validador() {  # migrar_validador <nome> <índice>
  local v="$1" i="$2" p; p=$(porta_de "$v")
  passo "Migração $i/4: validador '$v' para o Besu ${BESU_VERSAO_PLUGIN} + plugin"
  [ -f "$SN/docker-compose.override.yml" ] || echo "services:" > "$SN/docker-compose.override.yml"
  cat >> "$SN/docker-compose.override.yml" <<EOF
  $v:
    image: ${BESU_IMAGEM_PLUGIN}
    volumes:
      - ${TRAB}/plugin/besu-plugin-permissioning.jar:/opt/besu/plugins/besu-plugin-permissioning.jar:ro
EOF
  cp "$SN/docker-compose.override.yml" "$EXEC_DIR/docker-compose.override.yml"
  em "$SN" executar "parar $v" docker compose stop "$v"
  em "$SN" executar "subir $v com o plugin" docker compose up -d "$v"
  esperar_ate "RPC de $v" 180 responde "$p" || abortar "$v não respondeu após a migração"
  estado "E9.$i" "$i de 4 validadores no Besu ${BESU_VERSAO_PLUGIN} com o plugin (último migrado: $v)"
  ESTADO_ATUAL="E9.$i"
  verificar "T-11.$i-a" "versão do Besu no validador '$v'" "besu/v${BESU_VERSAO_PLUGIN}" "$(rpc "$p" web3_clientVersion | jq -r .result | cut -d/ -f1-2)"
  esperar_ate "$v sincronizar" 180 acompanha "$PORTA_BOOT" "$p" || true
  local bm; bm=$(bloco_atual "$PORTA_BOOT")
  esperar_ate "rede produzir 3 blocos após a migração" 90 bash -c "b=\$(curl -s -X POST -H 'content-type: application/json' --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}' localhost:$PORTA_BOOT | jq -r .result); [ \$((b)) -ge $((bm + 3)) ]" || true
  verificar_que "T-11.$i-b" "rede segue produzindo blocos com $i validador(es) no plugin" "≥ 3 blocos novos" \
    "$bm → $(bloco_atual "$PORTA_BOOT")" test "$(bloco_atual "$PORTA_BOOT")" -ge $((bm + 3))
  esperar_ate "'$v' (plugin) propor um bloco" 120 propos_depois_de "$(endereco_de "$v")" "$bm" || true
  verificar_que "T-11.$i-c" "validador '$v' (plugin) volta a propor blocos" "último bloco proposto > $bm" \
    "último bloco proposto: $(ultimo_proposto "$(endereco_de "$v")")" propos_depois_de "$(endereco_de "$v")" "$bm"
  local R; R=$(node "$RAIZ/ferramentas/tx.js" "http://localhost:$p" "$CONTA_ADMIN_CHAVE")
  echo "$R" >> "$EXEC_DIR/transacoes.jsonl"
  verificar "T-11.$i-d" "transação de conta permitida enviada ao validador '$v' (plugin)" "MINERADA, status 1" \
    "$(jq -r 'if .resultado=="MINERADA" then "MINERADA, status \(.status)" else "RECUSADA: \(.codigo) \(.erro)" end' <<<"$R")" "$R"
  R=$(node "$RAIZ/ferramentas/tx.js" "http://localhost:$p" aleatoria)
  echo "$R" >> "$EXEC_DIR/transacoes.jsonl"
  verificar "T-11.$i-e" "transação de conta não cadastrada enviada ao validador '$v' (plugin)" \
    "RECUSADA: -32007 Sender account not authorized to send transactions" \
    "$(jq -r 'if .resultado=="RECUSADA" then "RECUSADA: \(.codigo) \(.erro)" else "MINERADA no bloco \(.bloco)" end' <<<"$R")" "$R"
}
migrar_validador v2 1
migrar_validador v3 2
migrar_validador v4 3
migrar_validador validator 4

passo "Estado final do T-11: os 4 validadores no plugin"
B1=$(bloco_atual "$PORTA_BOOT")
for v in validator v2 v3 v4; do esperar_ate "$v propor um bloco" 90 propos_depois_de "$(endereco_de "$v")" "$B1" || true; done
todos=sim; for v in validator v2 v3 v4; do propos_depois_de "$(endereco_de "$v")" "$B1" || todos="não ($v)"; done
verificar T-11f "os 4 validadores (todos com o plugin) propõem blocos" "sim" "$todos"
