# Bancada de testes do plugin de permissionamento da RBB

Testes automatizados, reproduzíveis e verificáveis por terceiros do
[`besu-permissioning-plugin`](https://github.com/RBBNet/besu-permissioning-plugin) numa rede
de teste montada no padrão da Rede Blockchain Brasil (RBB).

## Por que esta bancada existe

O Hyperledger Besu removeu o permissionamento on-chain nativo na versão 25.6.0. O plugin
substitui essa funcionalidade. Antes de adotá-lo, precisamos comprovar, **com evidências que
qualquer pessoa possa conferir**, que ele se comporta como o esperado com os contratos de
permissionamento da RBB (gen02), inclusive durante a atualização gradual dos nós de uma rede
em funcionamento.

## Como a comprovação funciona

1. **Tudo é código.** A rede é montada do zero, os contratos são implantados, os nós são
   atualizados e os testes são executados por scripts deste repositório. Nenhum passo manual.
2. **O resultado esperado está escrito no código**, antes da execução. Cada verificação
   imprime o esperado, o obtido e o veredito.
3. **As execuções oficiais rodam no GitHub Actions**, em máquinas do GitHub. O log de cada
   execução, o resumo e os arquivos de evidência (logs dos nós, hashes de transação, blocos)
   ficam publicados na aba *Actions*, vinculados ao commit exato do código.
4. **Qualquer pessoa pode reproduzir** a execução na própria máquina com o mesmo comando.

## Regra de dados: somente dados sintéticos

Este repositório é público. Por isso:

- **Usamos apenas dados sintéticos e descartáveis:** contas de teste de conhecimento público
  (Hardhat e roteiros da RBB) e chaves de nós geradas a cada execução.
- **É proibido incluir qualquer informação da mainnet ou da testnet da RBB:** enodes, IPs,
  portas, contas, arquivos de gênesis reais e listas de nós ou de participantes.
- **É proibido copiar ou referenciar conteúdo de repositórios privados.**
- **Nenhum segredo real.** Se um dia for necessário algum, ele entra como *secret* do
  GitHub Actions, nunca no código.

O histórico do Git é permanente: apagar um arquivo não o remove do histórico. Na dúvida,
não faça o commit. O repositório tem varredura automática de segredos (gitleaks) a cada push.

## Como executar

**Na sua máquina:** requer Docker (com Compose), Node.js 20+, git, jq, curl e python3.

```bash
./executar.sh                  # executa tudo e derruba a rede ao final
MANTER_REDE=1 ./executar.sh    # mantém a rede de pé para inspeção (RPC nas portas 20001–20003)
```

Para desenvolvimento, `TESTES="T11 T12" ./executar.sh` monta a rede e roda só os testes indicados (o filtro aparece no relatório). As execuções oficiais rodam todos.

Cada execução gera `execucoes/<data-hora>/`, com o relatório `resumo.md` e todas as
evidências. O código de saída é 0 se todas as verificações passarem.

**No GitHub:** aba *Actions* → *Bancada* → *Run workflow*. A página da execução mostra o log
de cada passo e o resumo; as evidências ficam anexadas como artefato.

## O que é executado hoje

| Etapa | O que faz | Estado resultante |
|---|---|---|
| Fase 00 | Registra o ambiente, baixa `start-network`, `Permissionamento` e `scripts-permissionamento` nos commits fixados em `versoes.env`, constrói o `rbb-cli` e instala as dependências | — |
| Fase 01 | Roteiro 1–3: chaves, gênesis (QBFT, Ingress do gen01 sem Rules), configuração e subida do validator (Besu 25.5.0, Forest) | **E0** |
| Fase 02 | Roteiro 4.1–4.4: deploy do gen01, subida do boot e do writer | **E1** |
| Fase 03 | Roteiro 4.5–4.9: deploy do gen02, cadastro dos nós, reapontamento dos Ingress | **E2** |
| T-01, T-02 | Linha de base do permissionamento **nativo**: conta permitida × conta não cadastrada | — |
| T-03 | Nativo × caminho do plugin em estados históricos (antes e depois das regras). Testa a lógica dos contratos via `eth_call`; **não** executa um nó com o plugin | — |
| T-04 | Permissionamento **nativo** de nós: um nó novo, não cadastrado, tenta conectar ao boot e é recusado (evidência: linha `Rejected enode://…` no log TRACE de permissionamento do boot). É cadastrado no NodeRulesV2 e conecta e sincroniza sozinho (linha `Permitted enode://…`) | **E3** |
| T-05 | Migração do nó "novo" para o **Besu 25.12.0 com o plugin** v1.0.0-rc.1 (jar do release, SHA-256 conferido), mantendo chave e banco: plugin registrado com os Ingress da RBB, NodeRules do gen02 resolvido, reconexão e sincronização. Rede **mista** (1 nó com plugin, 3 nativos) | **E4** |
| T-06, T-07 | Transações enviadas **pelo nó com plugin**: conta permitida → minerada e importada por todos; conta não cadastrada → recusada com **o mesmo código e mensagem do nativo** (T-02). Contadores do plugin confirmam a checagem também na importação de blocos | — |
| 🐞 T-08 | **Demonstração permanente de defeito do plugin v1.0.0-rc.1.** Nó novo ("entrante") no Besu 25.12.0 com o plugin, sincronizando desde o gênesis por static-node. O plugin do próprio entrante avalia a conexão no estado do gênesis, não resolve o NodeRules ("Could not resolve NodeRules contract address. Rejecting connection.") e recusa a própria saída — antes e depois do cadastro. Não conecta e fica no bloco 0 | **E5** |
| 🐞 T-09 | **Demonstração permanente de defeito do plugin v1.0.0-rc.1.** Nó com o plugin entrando como **observer** (boot como bootnode). Conecta pela exceção de bootnode do Besu, importa até o bloco anterior à 1ª transação da cadeia e, ao importar o bloco dela, o plugin não resolve o AccountRules ("Could not resolve AccountRules contract address. Rejecting transaction."). O Besu declara o bloco inválido ("Sender … is not on the Account Allowlist") e desconecta o par por BREACH_OF_PROTOCOL | **E6** |
| 🐞 T-10 | **Demonstração permanente de defeito do plugin v1.0.0-rc.1.** Nó com o plugin **sem** o endereço do Ingress de contas: o Besu sobe normalmente (só WARN/ERROR no log); o nó recusa transações até de conta permitida e declara **inválido** um bloco válido com transação, parando de acompanhar a cadeia. Corrigida a configuração, recupera-se sozinho | E7 → E8 |
| T-11 | **Validadores migrando para o plugin, um a um.** A rede passa a 4 validadores (os novos entram nativos, são cadastrados e votados via `qbft_proposeValidatorVote`) e cada um é migrado para o Besu 25.12.0 + plugin mantendo chave e banco. A cada passo (1/4, 2/4, 3/4, 4/4): a rede segue produzindo blocos, o migrado volta a propor blocos, tx permitida enviada a ele é minerada e tx não cadastrada é recusada | E9 → E9.4 |
| T-12 | **Boot com o plugin barrando nós e rede inteira no plugin.** Boot migrado; um nó novo nativo e não cadastrado é recusado pelo **plugin do boot** (`OnChainNodePermissioningProvider: Rejected enode://…`); após o cadastro é permitido e baixa a cadeia. Writer e candidato migrados: todos os nós no 25.12.0 com plugin; tx permitida minerada e importada por todos, tx não cadastrada recusada | E10 → E12 |
| 🔎 T-07m | Observação: as métricas existem, mas com nomes diferentes dos documentados no release (`besupermissioning_onchain_…` em vez de `besu_permissioning_…`) | — |

Os itens 🐞 esperam o comportamento **defeituoso** e passam enquanto o defeito se reproduzir; quando houver versão corrigida do plugin, testes novos a usarão esperando o comportamento correto.

Toda diferença deliberada em relação ao roteiro oficial é impressa na execução como
"DESVIO DO ROTEIRO" e listada no relatório.

## Estado

Em construção. Primeira meta: montar automaticamente a rede básica do
[roteiro de rede de teste da RBB](https://github.com/RBBNet/rbb/blob/master/roteiro_criacao_rede_teste.md)
(validator, boot e writer no Besu 25.5.0, com gen01 → gen02) e verificar a linha de base do
permissionamento nativo.

## Licença

[GPL-3.0](LICENSE), a mesma dos repositórios de permissionamento da RBB.
