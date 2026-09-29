#!/usr/bin/env bash
# T-04: permissionamento NATIVO de nós (estado E2 → E3).
#
# Sobe um nó novo ("novo", tipo Writer), NÃO cadastrado no NodeRulesV2, apontando para o boot.
# Espera-se que o boot recuse a conexão. Depois o nó é cadastrado pela conta administradora e
# espera-se que ele conecte e sincronize sozinho, sem reiniciar nada.
#
# Evidência: o Besu 25.5.0 registra em TRACE cada decisão de permissionamento de nó, com os enodes
# de origem e destino (NodePermissioningController.java): "Node permissioning - <controlador>:
# Rejected enode://A -> enode://B" e "Node permissioning: Permitted enode://A -> enode://B".
# O besu_permissionamento.log do boot (ver log.xml na fase 01) guarda essas linhas.

fase "Teste T-04: permissionamento de nós — nó novo recusado, cadastrado e aceito"
SN="$TRAB/start-network"
SP="$TRAB/scripts-permissionamento"
PORTA_NOVO=${PORTA_NOVO:-20004}
LOG_BOOT="$SN/volumes/boot/logs/besu_permissionamento.log"
rbbcli() { em "$SN" executar "rbb-cli $*" ./rbb-cli "$@"; }

passo "Preparar o nó novo (mesma receita do writer: discovery desligado, static-node para o boot, Forest)"
rbbcli node create novo
K_NOVO=$(sed 's/^0x//' "$SN/.env.configs/nodes/novo/key.pub")
fato no.novo.chave_publica "0x$K_NOVO"
rbbcli config set "nodes.novo.ports+=[\"${PORTA_NOVO}:8545\"]"
rbbcli config set nodes.novo.environment.BESU_DISCOVERY_ENABLED=false
rbbcli config set 'nodes.novo.environment.BESU_DATA_STORAGE_FORMAT="FOREST"'
ENODE_BOOT="enode://$(sed 's/^0x//' "$SN/.env.configs/nodes/boot/key.pub")@boot:30303"
printf '[\n"%s"\n]\n' "$ENODE_BOOT" > "$SN/volumes/novo/static-nodes.json"
rbbcli config render-templates
cp "$SN/infra.json" "$EXEC_DIR/infra-com-novo.json"

em "$SP" executar "consultar se o nó novo está cadastrado" node node-rules-v2.js isNodeActive "0x${K_NOVO:0:64}" "0x${K_NOVO:64:64}"
SAIDA="$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log"
verificar T-04a "nó novo NÃO está ativo no NodeRulesV2 antes do cadastro" "ativo: false" "$(grep -o 'ativo: [a-z]*' "$SAIDA" | tail -1)"

passo "Subir o nó novo e observar por 90 s (o Besu tenta de novo os static-nodes a cada ~60 s)"
em "$SN" executar "subir nó novo" docker compose up -d novo
esperar_ate "RPC do nó novo" 120 responde "$PORTA_NOVO" || abortar "nó novo não respondeu"
PARES_BOOT_ANTES=$(pares "$PORTA_BOOT")
max_pares_novo=0
for i in $(seq 1 18); do   # 18 × 5 s = 90 s
  p=$(pares "$PORTA_NOVO"); [ -n "$p" ] && [ "$p" -gt "$max_pares_novo" ] && max_pares_novo=$p
  sleep 5
done
conta() { grep -c "$1" "$LOG_BOOT" 2>/dev/null || true; }
RECUSAS=$(conta "Rejected enode://$K_NOVO")
PERMISSOES_ANTES=$(conta "Permitted enode://$K_NOVO")
info "log de permissionamento do boot — decisões sobre o nó novo (primeiras 3):"
grep "enode://$K_NOVO" "$LOG_BOOT" | grep -v "Checking" | head -3 | cut -c1-260 | sed 's/^/    │ /'

verificar T-04b "nó novo sem nenhum par durante 90 s (máximo observado)" "0" "$max_pares_novo"
verificar_que T-04c "permissionamento do boot recusou o nó novo (log TRACE)" \
  "≥ 1 linha 'Rejected enode://<nó novo>'" "$RECUSAS linha(s) Rejected" test "$RECUSAS" -ge 1
verificar T-04c2 "permissionamento do boot nunca permitiu o nó novo antes do cadastro" "0" "$PERMISSOES_ANTES"
verificar T-04d "nó novo não aparece entre os pares do boot" "ausente" \
  "$(rpc "$PORTA_BOOT" admin_peers | jq -r --arg id "$K_NOVO" '[.result[].enode | select(contains($id))] | if length>0 then "presente" else "ausente" end')"
verificar T-04e "nó novo parado no bloco 0 (não recebeu blocos)" "0" "$(bloco_atual "$PORTA_NOVO")"
verificar T-04f "boot mantém seus pares de antes (validator e writer)" "2" "$(pares "$PORTA_BOOT")"

passo "Cadastrar o nó novo no NodeRulesV2 (conta administradora da Org 1)"
em "$SP" executar "addLocalNode novo (Writer)" node node-rules-v2.js addLocalNode "0x${K_NOVO:0:64}" "0x${K_NOVO:64:64}" Writer novo
em "$SP" executar "consultar se o nó novo está cadastrado" node node-rules-v2.js isNodeActive "0x${K_NOVO:0:64}" "0x${K_NOVO:64:64}"
SAIDA="$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log"
verificar T-04g "nó novo ativo no NodeRulesV2 após o cadastro" "ativo: true" "$(grep -o 'ativo: [a-z]*' "$SAIDA" | tail -1)"
estado E3 "E2 + nó 'novo' (Writer, Org 1) cadastrado no NodeRulesV2"

passo "Esperar o nó novo conectar e sincronizar sozinho (sem reiniciar nada)"
t0=$SECONDS
esperar_ate "nó novo conectar ao boot" 180 tem_pares "$PORTA_NOVO" 1
fato t04.segundos_ate_conectar "$((SECONDS - t0))"
esperar_ate "nó novo sincronizar" 120 acompanha "$PORTA_VALIDATOR" "$PORTA_NOVO"
verificar_que T-04h "nó novo conectado após o cadastro" "≥ 1 par" "$(pares "$PORTA_NOVO") par(es)" tem_pares "$PORTA_NOVO" 1
verificar T-04i "nó novo aparece entre os pares do boot" "presente" \
  "$(rpc "$PORTA_BOOT" admin_peers | jq -r --arg id "$K_NOVO" '[.result[].enode | select(contains($id))] | if length>0 then "presente" else "ausente" end')"
bv=$(bloco_atual "$PORTA_VALIDATOR"); bn=$(bloco_atual "$PORTA_NOVO")
verificar_que T-04j "nó novo sincronizado com o validator" "diferença ≤ 1 bloco" "validator $bv, novo $bn" \
  test $((bv - bn)) -le 1 -a "$bn" -gt 0
verificar T-04k "boot com 3 pares (validator, writer e novo)" "3" "$(pares "$PORTA_BOOT")"
PERMISSOES=$(conta "Permitted enode://$K_NOVO")
info "log de permissionamento do boot — primeira permissão ao nó novo:"
grep "Permitted enode://$K_NOVO" "$LOG_BOOT" | head -1 | cut -c1-260 | sed 's/^/    │ /'
verificar_que T-04l "permissionamento do boot passou a permitir o nó novo (log TRACE)" \
  "≥ 1 linha 'Permitted enode://<nó novo>'" "$PERMISSOES linha(s) Permitted" test "$PERMISSOES" -ge 1
