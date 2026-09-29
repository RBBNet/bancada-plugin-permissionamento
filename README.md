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

## Estado

Em construção. Primeira meta: montar automaticamente a rede básica do
[roteiro de rede de teste da RBB](https://github.com/RBBNet/rbb/blob/master/roteiro_criacao_rede_teste.md)
(validator, boot e writer no Besu 25.5.0, com gen01 → gen02) e verificar a linha de base do
permissionamento nativo.

## Licença

[GPL-3.0](LICENSE), a mesma dos repositórios de permissionamento da RBB.
