// Consultas aos contratos Ingress do permissionamento (0x…9999 nós, 0x…8888 contas).
//
//   node ingress.js regras <rpc> [bloco]
//       -> {bloco, regras_nos, regras_contas}  (getContractAddress("rules") em cada Ingress)
//
//   node ingress.js localizar <rpc> <de> <ate>
//       -> primeiro bloco em que cada Ingress passou a apontar para algum Rules
//
//   node ingress.js caminhos <rpc> <bloco> <chave-publica-origem> <chave-publica-destino>
//       -> compara, no estado daquele bloco, o que responde o caminho do permissionamento
//          NATIVO do Besu (chama o Ingress: connectionAllowed / transactionAllowed) com o
//          caminho do PLUGIN (resolve o Rules via getContractAddress("rules") e chama o
//          Rules; Rules = 0 é recusa, conforme PermissioningPlugin.get*RulesAddress).
const { ethers } = require('ethers');

const INGRESS_NOS = '0x0000000000000000000000000000000000009999';
const INGRESS_CONTAS = '0x0000000000000000000000000000000000008888';
const RULES = ethers.encodeBytes32String('rules');
const IFACE_NOS = new ethers.Interface([
  'function connectionAllowed(bytes32,bytes32,bytes16,uint16,bytes32,bytes32,bytes16,uint16) view returns (bytes32)',
  'function getContractAddress(bytes32) view returns (address)',
]);
const IFACE_CONTAS = new ethers.Interface([
  'function transactionAllowed(address,address,uint256,uint256,uint256,bytes) view returns (bool)',
  'function getContractAddress(bytes32) view returns (address)',
]);
const PERMITIDO = '0x' + 'f'.repeat(64);
const NEGADO = '0x7' + 'f'.repeat(63);

const [modo, rpc, ...args] = process.argv.slice(2);
const provedor = new ethers.JsonRpcProvider(rpc, undefined, { staticNetwork: true });
const chamar = (to, data, bloco) => provedor.call({ to, data, blockTag: bloco });

async function regras(bloco) {
  const n = IFACE_NOS.decodeFunctionResult('getContractAddress',
    await chamar(INGRESS_NOS, IFACE_NOS.encodeFunctionData('getContractAddress', [RULES]), bloco))[0];
  const c = IFACE_CONTAS.decodeFunctionResult('getContractAddress',
    await chamar(INGRESS_CONTAS, IFACE_CONTAS.encodeFunctionData('getContractAddress', [RULES]), bloco))[0];
  return { regras_nos: n, regras_contas: c };
}

const traduzNo = (r) => (r === PERMITIDO ? 'permite' : r === NEGADO ? 'recusa' : `inesperado(${r})`);
const traduzTx = (b) => (b ? 'permite' : 'recusa');

async function main() {
  if (modo === 'regras') {
    const bloco = args[0] !== undefined ? Number(args[0]) : 'latest';
    console.log(JSON.stringify({ bloco, ...(await regras(bloco)) }));
  } else if (modo === 'localizar') {
    const [de, ate] = args.map(Number);
    let nos = null, contas = null;
    for (let b = de; b <= ate && (nos === null || contas === null); b++) {
      const r = await regras(b);
      if (nos === null && r.regras_nos !== ethers.ZeroAddress) nos = b;
      if (contas === null && r.regras_contas !== ethers.ZeroAddress) contas = b;
    }
    console.log(JSON.stringify({ primeiro_bloco_regras_nos: nos, primeiro_bloco_regras_contas: contas }));
  } else if (modo === 'caminhos') {
    const [blocoTxt, pubOrigem, pubDestino] = args;
    const bloco = Number(blocoTxt);
    const o = pubOrigem.replace(/^0x/, ''), d = pubDestino.replace(/^0x/, '');
    const ip = '0x00000000000000000000ffff7f000001', porta = 30303;
    const argsNo = ['0x' + o.slice(0, 64), '0x' + o.slice(64), ip, porta, '0x' + d.slice(0, 64), '0x' + d.slice(64), ip, porta];
    const remetente = ethers.Wallet.createRandom().address;  // conta nunca cadastrada
    const argsTx = [remetente, '0x000000000000000000000000000000000000dEaD', 0, 0, 21000, '0x'];

    const nativoNo = traduzNo(await chamar(INGRESS_NOS, IFACE_NOS.encodeFunctionData('connectionAllowed', argsNo), bloco));
    const nativoTx = traduzTx(IFACE_CONTAS.decodeFunctionResult('transactionAllowed',
      await chamar(INGRESS_CONTAS, IFACE_CONTAS.encodeFunctionData('transactionAllowed', argsTx), bloco))[0]);

    const r = await regras(bloco);
    const pluginNo = r.regras_nos === ethers.ZeroAddress ? 'recusa'
      : traduzNo(await chamar(r.regras_nos, IFACE_NOS.encodeFunctionData('connectionAllowed', argsNo), bloco));
    const pluginTx = r.regras_contas === ethers.ZeroAddress ? 'recusa'
      : traduzTx(IFACE_CONTAS.decodeFunctionResult('transactionAllowed',
          await chamar(r.regras_contas, IFACE_CONTAS.encodeFunctionData('transactionAllowed', argsTx), bloco))[0]);

    console.log(JSON.stringify({ bloco, ...r, remetente_teste: remetente,
      nativo_no: nativoNo, nativo_tx: nativoTx, plugin_no: pluginNo, plugin_tx: pluginTx }));
  } else {
    console.error('modo inválido; use regras | localizar | caminhos');
    process.exit(1);
  }
}
main().catch((e) => { console.error(e.message || e); process.exit(1); });
