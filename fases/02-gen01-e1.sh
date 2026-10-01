#!/usr/bin/env bash
# Fase 02: implanta o permissionamento gen01 (roteiro 4.1–4.3), sobe boot e writer (roteiro 4.4)
# e verifica a rede. Resultado: estado E1.

fase "Fase 02: gen01 e estado E1 (roteiro 4.1–4.4)"
ESTADO_ATUAL="E0→E1"   # verificações desta fase ocorrem durante a transição
SN="$TRAB/start-network"
G1="$TRAB/Permissionamento/gen01"
source "$RAIZ/lib/contas-teste.env"
B_ANTES_GEN01=$(bloco_atual "$PORTA_VALIDATOR")
fato bloco.antes_gen01 "$B_ANTES_GEN01"

passo "Roteiro 4.2: .env do deploy do gen01"
pub() { sed 's/^0x//' "$SN/.env.configs/nodes/$1/key.pub"; }
cat > "$G1/.env" <<EOF
NODE_INGRESS_CONTRACT_ADDRESS=0x0000000000000000000000000000000000009999
ACCOUNT_INGRESS_CONTRACT_ADDRESS=0x0000000000000000000000000000000000008888
BESU_NODE_PERM_ACCOUNT=${CONTA_ADMIN_ENDERECO#0x}
BESU_NODE_PERM_KEY=${CONTA_ADMIN_CHAVE#0x}
BESU_NODE_PERM_ENDPOINT=http://localhost:${PORTA_VALIDATOR}
CHAIN_ID=648629
INITIAL_ALLOWLISTED_NODES=enode://$(pub boot)|0|0x000000000000|boot|BANCADA,enode://$(pub validator)|1|0x000000000000|validator|BANCADA,enode://$(pub writer)|2|0x000000000000|writer|BANCADA
EOF
desvio "BESU_NODE_PERM_ENDPOINT usa a porta mapeada no host, e não o IP do contêiner sugerido pelo roteiro (no macOS a rede dos contêineres não é acessível pelo host)"

passo "Roteiro 4.3: deploy do gen01"
LINHAS_SAIDA=12 em "$G1" executar "deploy do gen01" npx --yes "yarn@${YARN_VERSAO}" deploy --network besu
SAIDA="$EXEC_DIR/comandos/$(printf '%03d' "$N_CMD").log"
extrai() { grep -o "$1 *= *0x[0-9a-fA-F]\{40\}" "$SAIDA" | head -1 | grep -o '0x[0-9a-fA-F]\{40\}'; }
GEN01_ADMIN=$(extrai "Admin contract deployed with address")
GEN01_NODE_RULES=$(extrai "Updated NodeIngress contract with NodeRules address")
GEN01_ACCOUNT_RULES=$(extrai "Updated AccountIngress contract with Rules address")
fato gen01.admin "$GEN01_ADMIN"
fato gen01.node_rules "$GEN01_NODE_RULES"
fato gen01.account_rules "$GEN01_ACCOUNT_RULES"
[ -n "$GEN01_ADMIN" ] && [ -n "$GEN01_NODE_RULES" ] && [ -n "$GEN01_ACCOUNT_RULES" ] \
  || abortar "não foi possível extrair os endereços do gen01 da saída do deploy"

# O script de deploy do gen01 imprime "Updated ... Rules address" logo após ENVIAR a transação
# (ethers v6: await setContractAddress() espera o envio, não a mineração) e termina com a última
# transação ainda pendente. Por isso esperamos a mineração antes de verificar.
aponta_para() {  # aponta_para <campo: regras_nos|regras_contas> <endereço>
  [ "$(minusculo "$(node "$RAIZ/ferramentas/ingress.js" regras "http://localhost:$PORTA_VALIDATOR" | jq -r ".$1")")" = "$(minusculo "$2")" ]
}
t0=$SECONDS
esperar_ate "AccountIngress apontar para o AccountRules (última transação do deploy)" 30 aponta_para regras_contas "$GEN01_ACCOUNT_RULES"
fato gen01.espera_ultima_tx_s "$((SECONDS - t0))"
R=$(node "$RAIZ/ferramentas/ingress.js" regras "http://localhost:$PORTA_VALIDATOR")
verificar E1-01 "NodeIngress aponta para o NodeRules do gen01" "$(minusculo "$GEN01_NODE_RULES")" "$(minusculo "$(jq -r .regras_nos <<<"$R")")"
verificar E1-02 "AccountIngress aponta para o AccountRules do gen01" "$(minusculo "$GEN01_ACCOUNT_RULES")" "$(minusculo "$(jq -r .regras_contas <<<"$R")")"
L=$(node "$RAIZ/ferramentas/ingress.js" localizar "http://localhost:$PORTA_VALIDATOR" "$B_ANTES_GEN01" "$(bloco_atual "$PORTA_VALIDATOR")")
fato bloco.primeiro_com_regras_nos "$(jq -r .primeiro_bloco_regras_nos <<<"$L")"
fato bloco.primeiro_com_regras_contas "$(jq -r .primeiro_bloco_regras_contas <<<"$L")"

passo "Roteiro 4.4: subir boot e writer"
em "$SN" executar "subir boot e writer" docker compose up -d boot writer
esperar_ate "RPC do boot" 120 responde "$PORTA_BOOT" || abortar "boot não respondeu"
esperar_ate "RPC do writer" 120 responde "$PORTA_WRITER" || abortar "writer não respondeu"
if esperar_ate "validator conectar ao boot" 90 tem_pares "$PORTA_VALIDATOR" 1; then
  fato roteiro_4_4.reinicio_validator "não foi necessário"
else
  info "validator sem pares: aplicando o roteiro 4.4 (\"caso os nós não se conectem, reinicie o validator\")"
  info "causa conhecida: o validator resolveu o nome 'boot' antes de o contêiner existir e ficou tentando 127.0.0.1"
  em "$SN" executar "reiniciar validator (roteiro 4.4)" docker compose restart validator
  fato roteiro_4_4.reinicio_validator "sim"
fi
esperar_ate "boot com 2 pares" 120 tem_pares "$PORTA_BOOT" 2
esperar_ate "writer com 1 par" 120 tem_pares "$PORTA_WRITER" 1
verificar E1-03 "pares (validator/boot/writer)" "1/2/1" "$(pares "$PORTA_VALIDATOR")/$(pares "$PORTA_BOOT")/$(pares "$PORTA_WRITER")"
esperar_ate "boot e writer sincronizados com o validator" 120 acompanha "$PORTA_VALIDATOR" "$PORTA_BOOT" "$PORTA_WRITER"
bv=$(bloco_atual "$PORTA_VALIDATOR"); bb=$(bloco_atual "$PORTA_BOOT"); bw=$(bloco_atual "$PORTA_WRITER")
verificar_que E1-04 "boot e writer acompanham o validator" "diferença ≤ 1 bloco" "validator $bv, boot $bb, writer $bw" \
  acompanha "$PORTA_VALIDATOR" "$PORTA_BOOT" "$PORTA_WRITER"
verificar E1-05 "versão do Besu no boot" "besu/v${BESU_VERSAO_INICIAL}" "$(rpc "$PORTA_BOOT" web3_clientVersion | jq -r .result | cut -d/ -f1-2)"
verificar E1-06 "versão do Besu no writer" "besu/v${BESU_VERSAO_INICIAL}" "$(rpc "$PORTA_WRITER" web3_clientVersion | jq -r .result | cut -d/ -f1-2)"
estado E1 "gen01 ativo: validator, boot e writer permitidos; admin master ${CONTA_ADMIN_ENDERECO}"
