#!/usr/bin/env bash
# Fase 01: cria chaves, gênesis e configuração dos nós conforme o roteiro de rede de teste da RBB
# (roteiro_criacao_rede_teste.md, seções 1 a 3) e sobe o validator. Resultado: estado E0.

fase "Fase 01: rede básica e estado E0 (roteiro 1–3)"
ESTADO_ATUAL="montagem→E0"   # verificações desta fase ocorrem durante a transição
SN="$TRAB/start-network"
rbbcli() { em "$SN" executar "rbb-cli $*" ./rbb-cli "$@"; }

passo "Roteiro 1.3: chaves dos nós validator, boot e writer"
rbbcli node create validator,boot,writer
for n in validator boot writer; do
  fato "no.$n.chave_publica" "$(cat "$SN/.env.configs/nodes/$n/key.pub")"
done
fato no.validator.endereco "$(cat "$SN/.env.configs/nodes/validator/node.id")"

passo "Roteiro 1.3: portas RPC no host"
rbbcli config set "nodes.validator.ports+=[\"${PORTA_VALIDATOR}:8545\"]"
rbbcli config set "nodes.boot.ports+=[\"${PORTA_BOOT}:8545\"]"
rbbcli config set "nodes.writer.ports+=[\"${PORTA_WRITER}:8545\"]"
desvio "portas RPC ${PORTA_VALIDATOR}/${PORTA_BOOT}/${PORTA_WRITER} em vez de 10001/10002/10003, para não colidir com outras redes na mesma máquina"

passo "Roteiro 2.1: genesis.json com o validator no extraData"
rbbcli genesis create --validators validator
G="$SN/.env.configs/genesis.json"
verificar G-01 "chainId do gênesis" "648629" "$(jq -r .config.chainId "$G")"
verificar G-02 "Ingress de contas pré-alocado no gênesis (0x…8888)" "true" \
  "$(jq -r '.alloc["0x0000000000000000000000000000000000008888"].code != null' "$G")"
verificar G-03 "Ingress de nós pré-alocado no gênesis (0x…9999)" "true" \
  "$(jq -r '.alloc["0x0000000000000000000000000000000000009999"].code != null' "$G")"
cp "$G" "$EXEC_DIR/genesis.json"

passo "Roteiro 2.2: discovery desligado no validator e no writer; static-nodes apontando para o boot"
rbbcli config set nodes.validator.environment.BESU_DISCOVERY_ENABLED=false
rbbcli config set nodes.writer.environment.BESU_DISCOVERY_ENABLED=false
ENODE_BOOT="enode://$(sed 's/^0x//' "$SN/.env.configs/nodes/boot/key.pub")@boot:30303"
for n in validator writer; do printf '[\n"%s"\n]\n' "$ENODE_BOOT" > "$SN/volumes/$n/static-nodes.json"; done
info "static-nodes: $ENODE_BOOT"

passo "Ajustes deliberados em relação ao roteiro"
desvio "BESU_DATA_STORAGE_FORMAT=FOREST nos três nós: a 25.5.0 usa BONSAI por padrão, o start-network não define o formato, e a mainnet da RBB usa Forest"
for n in validator boot writer; do
  rbbcli config set "nodes.$n.environment.BESU_DATA_STORAGE_FORMAT=\"FOREST\""
done
desvio "log.xml: console e besu_info.log passam a incluir WARN (o original só grava INFO e ERROR), o novo besu_bancada.log reúne ERROR..DEBUG com logger e thread, e o besu_permissionamento.log (sem rotação, porque os testes contam linhas a partir de uma posição no arquivo) grava TRACE dos pacotes de permissionamento (nativo e plugin), onde o Besu registra cada decisão de conexão com os enodes"
python3 - "$SN/.env.configs/log.xml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read(); orig = s
s = s.replace('<Console name="infoConsole" target="SYSTEM_OUT">\n            <LevelRangeFilter minLevel="INFO" maxLevel="INFO"',
              '<Console name="infoConsole" target="SYSTEM_OUT">\n            <LevelRangeFilter minLevel="WARN" maxLevel="INFO"')
s = s.replace('_info/app-%d{MM-dd-yyyy}-%i.log">\n            <LevelRangeFilter minLevel="INFO" maxLevel="INFO"',
              '_info/app-%d{MM-dd-yyyy}-%i.log">\n            <LevelRangeFilter minLevel="WARN" maxLevel="INFO"')
extra = '''
        <RollingFile name="bancadaLog" fileName="${LOG_BASE_PATH}/besu_bancada.log" filePattern="${LOG_BASE_PATH}/bancada/app-%d{MM-dd-yyyy}-%i.log">
            <LevelRangeFilter minLevel="ERROR" maxLevel="DEBUG" onMatch="ACCEPT" onMismatch="DENY" />
            <PatternLayout pattern="%d{yyyy-MM-dd'T'HH:mm:ss.SSSZ} %-5p [%t] %c{1} - %m%n" />
            <Policies><SizeBasedTriggeringPolicy size="50 MB" /></Policies>
            <DefaultRolloverStrategy max="50" />
        </RollingFile>

    </Appenders>'''
extra = extra.replace('\n    </Appenders>', '''
        <File name="permissionamentoLog" fileName="${LOG_BASE_PATH}/besu_permissionamento.log">
            <PatternLayout pattern="%d{yyyy-MM-dd'T'HH:mm:ss.SSSZ} %-5p [%t] %c{1} - %m%n" />
        </File>

    </Appenders>''')
s = s.replace('\n    </Appenders>', extra, 1)
s = s.replace('    </Loggers>', '''        <Logger name="org.hyperledger.besu.ethereum.permissioning" level="trace" additivity="true">
            <AppenderRef ref="permissionamentoLog" />
        </Logger>
        <Logger name="org.hyperledger.besu.plugin.permissioning" level="trace" additivity="true">
            <AppenderRef ref="permissionamentoLog" />
        </Logger>
    </Loggers>''', 1)
s = s.replace('<AppenderRef ref="debugLog" />', '<AppenderRef ref="debugLog" />\n            <AppenderRef ref="bancadaLog" />')
assert s.count('minLevel="WARN" maxLevel="INFO"') == 2 and 'bancadaLog' in s and s.count('permissionamentoLog') == 3, "log.xml com formato inesperado"
open(p, 'w').write(s)
PY
desvio "imagem do Besu fixada por digest (${BESU_IMAGEM_INICIAL}); o compose usa hyperledger/besu sem versão, o que traria a mais recente, já sem permissionamento nativo"
cat > "$SN/.env" <<EOF
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
IMAGE_BESU=${BESU_IMAGEM_INICIAL}
CPUS_LIMIT_BESU_CONTAINER=2
MEMORY_LIMIT_BESU_CONTAINER=2G
EOF
cp "$SN/infra.json" "$EXEC_DIR/infra.json"

passo "Roteiro 3: renderizar templates e subir apenas o validator"
rbbcli config render-templates
cp "$SN/docker-compose.yml" "$EXEC_DIR/docker-compose.yml"
em "$SN" executar "subir validator" docker compose up -d validator
esperar_ate "RPC do validator responder" 120 responde "$PORTA_VALIDATOR" || abortar "validator não respondeu"

verificar E0-01 "versão do Besu no validator" "besu/v${BESU_VERSAO_INICIAL}" \
  "$(rpc "$PORTA_VALIDATOR" web3_clientVersion | jq -r .result | cut -d/ -f1-2)"
esperar_ate "log do validator informar o formato de armazenamento" 60 \
  bash -c "cd '$SN' && docker compose logs validator 2>/dev/null | grep -q 'Data storage:'"
verificar E0-02 "formato de armazenamento do validator" "Forest" \
  "$(cd "$SN" && docker compose logs validator 2>/dev/null | grep -o 'Data storage: [A-Za-z]*' | head -1 | cut -d' ' -f3)"
b1=$(bloco_atual "$PORTA_VALIDATOR"); sleep 10; b2=$(bloco_atual "$PORTA_VALIDATOR")
verificar_que E0-03 "validator produz blocos (QBFT, período de 4 s)" "avanço ≥ 2 blocos em 10 s" "$b1 → $b2" \
  test $((b2 - b1)) -ge 2
fato rede.hash_genesis "$(rpc "$PORTA_VALIDATOR" eth_getBlockByNumber '["0x0",false]' | jq -r .result.hash)"
R=$(node "$RAIZ/ferramentas/ingress.js" regras "http://localhost:$PORTA_VALIDATOR")
verificar E0-04 "Ingress sem Rules apontado (nós e contas)" \
  "0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000" \
  "$(jq -r '"\(.regras_nos) \(.regras_contas)"' <<<"$R")"
estado E0 "só o validator; Ingress do gen01 no gênesis, sem Rules (tudo permitido)"
