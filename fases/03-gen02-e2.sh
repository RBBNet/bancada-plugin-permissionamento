#!/usr/bin/env bash
# Fase 03: implanta o gen02 (roteiro 4.5–4.6), cadastra os nós no NodeRulesV2 (roteiro 4.7–4.8)
# e reaponta os Ingress para as regras do gen02 (roteiro 4.9). Resultado: estado E2.

fase "Fase 03: gen02 e estado E2 (roteiro 4.5–4.9)"
ESTADO_ATUAL="E1→E2"   # verificações desta fase ocorrem durante a transição
SN="$TRAB/start-network"
G2="$TRAB/Permissionamento/gen02"
SP="$TRAB/scripts-permissionamento"
source "$RAIZ/lib/contas-teste.env"
RPC_V="http://localhost:${PORTA_VALIDATOR}"

passo "Roteiro 4.5: .env e parameters-toy.json do gen02"
cat > "$G2/.env" <<EOF
CONFIG_PARAMETERS=deploy/parameters-toy.json
ACCOUNT_ADDRESS=${CONTA_ADMIN_ENDERECO#0x}
PRIVATE_KEY=${CONTA_ADMIN_CHAVE#0x}
RPC_URL=${RPC_V}
EOF
cat > "$G2/deploy/parameters-toy.json" <<EOF
{
    "adminAddress": "${GEN01_ADMIN}",
    "organizations": [
        { "id": 0, "cnpj": "00000000000001", "name": "Org Patrono",   "orgType": "Patron",    "canVote": true },
        { "id": 0, "cnpj": "00000000000002", "name": "Org Associado", "orgType": "Associate", "canVote": true },
        { "id": 0, "cnpj": "00000000000003", "name": "Org Parceiro",  "orgType": "Partner",   "canVote": false }
    ],
    "globalAdmins": [
        "${CONTA_ADMIN_ENDERECO}",
        "${CONTA_HARDHAT0_ENDERECO}",
        "${CONTA_HARDHAT1_ENDERECO}"
    ]
}
EOF
cp "$G2/deploy/parameters-toy.json" "$EXEC_DIR/parameters-toy.json"
desvio "gen02/hardhat.config.js fixa a rede local_besu em http://127.0.0.1:8545 e ignora o RPC_URL do roteiro; usamos um arquivo de configuração adicional que reaproveita o original e troca só a URL"
cat > "$G2/hardhat.bancada.config.js" <<'EOF'
// Gerado pela bancada: igual ao hardhat.config.js, trocando só a URL de local_besu pelo RPC_URL.
const base = require('./hardhat.config.js');
base.networks.local_besu.url = process.env.RPC_URL;
module.exports = base;
EOF

passo "Roteiro 4.6: deploy do gen02"
LINHAS_SAIDA=8 em "$G2" executar "deploy do gen02" \
  npx hardhat --config hardhat.bancada.config.js run deploy/deploy-gen02.js --network local_besu
SAIDA="$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log"
extrai2() { grep "$1 implantado no endereço" "$SAIDA" | grep -o '0x[0-9a-fA-F]\{40\}' | head -1; }
GEN02_ORGANIZACAO=$(extrai2 OrganizationImpl)
GEN02_ACCOUNT_RULES=$(extrai2 AccountRulesV2Impl)
GEN02_NODE_RULES=$(extrai2 NodeRulesV2Impl)
GEN02_GOVERNANCA=$(extrai2 Governance)
fato gen02.organization "$GEN02_ORGANIZACAO"
fato gen02.account_rules_v2 "$GEN02_ACCOUNT_RULES"
fato gen02.node_rules_v2 "$GEN02_NODE_RULES"
fato gen02.governance "$GEN02_GOVERNANCA"
[ -n "$GEN02_ORGANIZACAO" ] && [ -n "$GEN02_ACCOUNT_RULES" ] && [ -n "$GEN02_NODE_RULES" ] && [ -n "$GEN02_GOVERNANCA" ] \
  || abortar "não foi possível extrair os endereços do gen02 da saída do deploy"

passo "Roteiro 4.7: .env do scripts-permissionamento"
cat > "$SP/.env" <<EOF
JSON_RPC_URL=${RPC_V}
ACCOUNT_INGRESS_ADDRESS=0x0000000000000000000000000000000000008888
NODE_INGRESS_ADDRESS=0x0000000000000000000000000000000000009999
ADMIN_ADDRESS=${GEN01_ADMIN}
ORGANIZATION_ADDRESS=${GEN02_ORGANIZACAO}
ACCOUNT_RULES_V2_ADDRESS=${GEN02_ACCOUNT_RULES}
NODE_RULES_V2_ADDRESS=${GEN02_NODE_RULES}
GOVERNANCE_ADDRESS=${GEN02_GOVERNANCA}
PRIVATE_KEY=${CONTA_ADMIN_CHAVE}
EOF

passo "Roteiro 4.8: cadastrar os nós no NodeRulesV2 (antes do reapontamento, senão a rede para)"
for spec in validator:Validator boot:Boot writer:Writer; do
  n=${spec%%:*}; t=${spec##*:}; K=$(sed 's/^0x//' "$SN/.env.configs/nodes/$n/key.pub")
  em "$SP" executar "addLocalNode $n ($t)" node node-rules-v2.js addLocalNode "0x${K:0:64}" "0x${K:64:64}" "$t" "$n"
done
em "$SP" executar "listar nós do NodeRulesV2" node node-rules-v2.js getNodes 1 10
SAIDA="$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log"
verificar E2-01 "nós ativos no NodeRulesV2" "3" "$(grep -c ';true$' "$SAIDA")"

passo "Roteiro 4.9: reapontar os Ingress para o gen02"
B_ANTES_REPOINT=$(bloco_atual "$PORTA_VALIDATOR")
PARES_ANTES="$(pares "$PORTA_VALIDATOR")/$(pares "$PORTA_BOOT")/$(pares "$PORTA_WRITER")"
em "$SP" executar "reapontar regras" node util/repoint-rules.js
R=$(node "$RAIZ/ferramentas/ingress.js" regras "$RPC_V")
verificar E2-02 "NodeIngress aponta para o NodeRulesV2" "$(minusculo "$GEN02_NODE_RULES")" "$(minusculo "$(jq -r .regras_nos <<<"$R")")"
verificar E2-03 "AccountIngress aponta para o AccountRulesV2" "$(minusculo "$GEN02_ACCOUNT_RULES")" "$(minusculo "$(jq -r .regras_contas <<<"$R")")"
sleep 12
PARES_DEPOIS="$(pares "$PORTA_VALIDATOR")/$(pares "$PORTA_BOOT")/$(pares "$PORTA_WRITER")"
verificar E2-04 "nenhum nó perdeu pares com o reapontamento" "$PARES_ANTES" "$PARES_DEPOIS"
B_DEPOIS=$(bloco_atual "$PORTA_VALIDATOR")
verificar_que E2-05 "produção de blocos continua após o reapontamento" "bloco avança" "$B_ANTES_REPOINT → $B_DEPOIS" \
  test "$B_DEPOIS" -gt "$B_ANTES_REPOINT"

passo "Diagnóstico do permissionamento (scripts-permissionamento)"
em "$SP" executar "diagnóstico" node permissioning-diagnostics.js
SAIDA="$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log"
cp "$SAIDA" "$EXEC_DIR/diagnostico-e2.txt"
verificar E2-06 "contas GLOBAL_ADMIN ativas" "3" "$(grep -c 'GLOBAL_ADMIN_ROLE.*Active true' "$SAIDA")"
estado E2 "gen02 ativo: 3 GLOBAL_ADMIN (Orgs 1–3), 3 nós na Org 1, nenhuma conta USER"
