#!/usr/bin/env bash
# Gera o relatório (Markdown) de uma execução a partir de fatos.jsonl e verificacoes.jsonl.
# Uso: relatorio.sh <diretório-da-execução>
D="$1"
F="$D/fatos.jsonl"; V="$D/verificacoes.jsonl"
fatov() { jq -r --arg k "$1" 'select(.tipo=="fato" and .chave==$k) | .valor' "$F" | tail -1; }
md() { sed 's/|/\\|/g'; }  # escapa barras verticais para células de tabela

total=$(wc -l < "$V" | tr -d ' ')
ok=$(jq -s '[.[] | select(.ok)] | length' "$V")
abortos=$(jq -r 'select(.tipo=="aborto") | .motivo' "$F")

echo "# Bancada do plugin de permissionamento: execução $(basename "$D")"
echo
if [ -n "$abortos" ]; then
  echo "**❌ EXECUÇÃO ABORTADA:** $abortos"
elif [ "$ok" = "$total" ]; then
  echo "**✅ Todas as $total verificações passaram.**"
else
  echo "**❌ $((total - ok)) de $total verificações falharam.**"
fi
echo
echo "## Ambiente"
echo
echo "| Item | Valor |"
echo "|---|---|"
for k in bancada.commit bancada.alteracoes_locais ambiente.executor ambiente.sistema ambiente.arquitetura ambiente.docker ambiente.docker_compose ambiente.node imagem.besu_inicial imagem.rbb_cli repositorio.start-network repositorio.Permissionamento repositorio.scripts-permissionamento dependencia.gen02_openzeppelin; do
  v=$(fatov "$k"); [ -n "$v" ] && echo "| $k | \`$(echo "$v" | md)\` |"
done
echo
echo "## Estados da rede"
echo
echo "| Estado | Desde o bloco | Descrição |"
echo "|---|---|---|"
jq -r 'select(.tipo=="estado") | "| **\(.estado)** | \(.bloco) | \(.descricao) |"' "$F"
echo
echo "## Verificações"
echo
echo "| | ID | Estado | Verificação | Esperado | Obtido |"
echo "|---|---|---|---|---|---|"
jq -r 'def c: tostring | gsub("\\|"; "¦"); "| \(if .ok then "✅" else "❌" end) | \(.id) | \(.estado) | \(.descricao|c) | \(.esperado|c) | \(.obtido|c) |"' "$V"
echo
echo "## Desvios deliberados em relação ao roteiro oficial da RBB"
echo
jq -r 'select(.tipo=="desvio") | "- \(.descricao)"' "$F"
echo
echo "## Fatos registrados (endereços, blocos, chaves públicas)"
echo
echo "| Chave | Valor |"
echo "|---|---|"
jq -r 'select(.tipo=="fato") | "| \(.chave) | `\(.valor)` |"' "$F" | grep -v -E '\| (ambiente|imagem|repositorio|bancada|dependencia)\.'
echo
echo "## Arquivos desta execução"
echo
echo "- \`verificacoes.jsonl\`: cada verificação com esperado, obtido e dados brutos"
echo "- \`fatos.jsonl\`: fases, estados, desvios e fatos, com horário (UTC)"
echo "- \`transacoes.jsonl\`, \`caminhos.jsonl\`: saídas brutas dos testes"
echo "- \`comandos/\`: saída completa de cada comando executado"
echo "- \`nos/\`: logs dos nós Besu (console e arquivos, incluindo \`besu_bancada.log\` com DEBUG)"
echo "- \`genesis.json\`, \`infra.json\`, \`docker-compose.yml\`, \`parameters-toy.json\`, \`diagnostico-e2.txt\`"
