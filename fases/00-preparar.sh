#!/usr/bin/env bash
# Fase 00: registra o ambiente, baixa os repositórios da RBB nos commits fixados, constrói a
# imagem do rbb-cli e instala as dependências. Não altera nenhuma rede.

fase "Fase 00: preparação do ambiente"

passo "Ambiente de execução"
fato ambiente.executor "$([ "$NO_GITHUB" = true ] && echo "GitHub Actions (${RUNNER_NAME:-?}, ${RUNNER_OS:-?})" || echo "máquina local")"
fato ambiente.sistema "$(uname -s) $(uname -r)"
fato ambiente.arquitetura "$(uname -m)"
for f in docker git jq curl node npm; do command -v "$f" >/dev/null || abortar "ferramenta ausente: $f"; done
fato ambiente.docker "$(docker version --format '{{.Server.Version}}')"
fato ambiente.docker_compose "$(docker compose version --short)"
fato ambiente.node "$(node --version)"
node -e "process.exit(parseInt(process.versions.node) >= ${NODE_VERSAO_MINIMA} ? 0 : 1)" \
  || abortar "Node.js ${NODE_VERSAO_MINIMA}+ necessário"
fato bancada.commit "$(git -C "$RAIZ" rev-parse HEAD 2>/dev/null || echo desconhecido)"
if [ -n "$(git -C "$RAIZ" status --porcelain 2>/dev/null)" ]; then
  fato bancada.alteracoes_locais "SIM (código com alterações não versionadas; execução não reproduzível a partir do commit)"
else
  fato bancada.alteracoes_locais "não"
fi

passo "Repositórios da RBB nos commits fixados (versoes.env)"
clonar() {  # clonar <url> <commit> <destino>
  mkdir -p "$3"
  git -C "$3" init -q
  git -C "$3" fetch -q --depth 1 "$1" "$2"
  git -C "$3" checkout -q FETCH_HEAD
  fato "repositorio.$(basename "$3")" "$1 @ $(git -C "$3" rev-parse HEAD)"
}
clonar "$START_NETWORK_REPO" "$START_NETWORK_COMMIT" "$TRAB/start-network"
clonar "$PERMISSIONAMENTO_REPO" "$PERMISSIONAMENTO_COMMIT" "$TRAB/Permissionamento"
clonar "$SCRIPTS_PERMISSIONAMENTO_REPO" "$SCRIPTS_PERMISSIONAMENTO_COMMIT" "$TRAB/scripts-permissionamento"

passo "Imagem do rbb-cli construída a partir do start-network, sobre o Besu ${BESU_VERSAO_INICIAL}"
desvio "a imagem bndes/rbb:latest do Docker Hub é de 2023 e anterior ao start-network atual; construímos a imagem localmente (start-network/build.sh faz o mesmo, sem fixar a versão do Besu)"
RBB_IMAGE="bancada/rbb-cli:${START_NETWORK_COMMIT:0:7}-besu${BESU_VERSAO_INICIAL}"
export RBB_IMAGE
em "$TRAB/start-network" executar "construir imagem do rbb-cli" \
    docker build --build-arg "BESU_IMAGE=${BESU_IMAGEM_INICIAL}" --build-arg NODE_VERSION=22 --tag "$RBB_IMAGE" .
fato imagem.rbb_cli "$RBB_IMAGE"
executar "baixar imagem do Besu dos nós" docker pull -q "$BESU_IMAGEM_INICIAL"
fato imagem.besu_inicial "$BESU_IMAGEM_INICIAL"

passo "Plugin de permissionamento ${PLUGIN_VERSAO} (jar do release, conferido pelo SHA-256)"
mkdir -p "$TRAB/plugin"
executar "baixar o jar do plugin" curl -sSL -o "$TRAB/plugin/besu-plugin-permissioning.jar" "$PLUGIN_URL"
SHA_OBTIDO=$(shasum -a 256 "$TRAB/plugin/besu-plugin-permissioning.jar" | cut -d' ' -f1)
verificar P-01 "SHA-256 do jar do plugin confere com o fixado em versoes.env" "$PLUGIN_SHA256" "$SHA_OBTIDO"
[ "$SHA_OBTIDO" = "$PLUGIN_SHA256" ] || abortar "jar do plugin diferente do esperado"
fato plugin.versao "$PLUGIN_VERSAO"
fato plugin.url "$PLUGIN_URL"
fato plugin.sha256 "$SHA_OBTIDO"
executar "baixar imagem do Besu do nó com plugin" docker pull -q "$BESU_IMAGEM_PLUGIN"
fato imagem.besu_plugin "$BESU_IMAGEM_PLUGIN"

passo "Dependências Node.js"
em "$TRAB/Permissionamento/gen01" executar "gen01: yarn install (yarn.lock do repositório)" \
    npx --yes "yarn@${YARN_VERSAO}" install --frozen-lockfile --non-interactive
desvio "gen02 e scripts-permissionamento não versionam package-lock.json; usamos os lockfiles de dependencias/. No gen02, o OpenZeppelin fica em 5.3.0 (a faixa ^5.2.0 resolve hoje para 5.6.1, que usa a instrução mcopy do Cancun e não compila para 'paris')"
cp "$RAIZ/dependencias/gen02/package-lock.json" "$TRAB/Permissionamento/gen02/"
em "$TRAB/Permissionamento/gen02" executar "gen02: npm ci" npm ci --no-audit --no-fund
fato dependencia.gen02_openzeppelin "$(jq -r .version "$TRAB/Permissionamento/gen02/node_modules/@openzeppelin/contracts/package.json")"
cp "$RAIZ/dependencias/scripts-permissionamento/package-lock.json" "$TRAB/scripts-permissionamento/"
em "$TRAB/scripts-permissionamento" executar "scripts-permissionamento: npm ci" npm ci --no-audit --no-fund
em "$RAIZ/ferramentas" executar "ferramentas da bancada: npm ci" npm ci --no-audit --no-fund
