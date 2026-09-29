// Envia uma transação simples (valor 0, gasPrice 0) e imprime o resultado em JSON.
// Uso: node tx.js <url-rpc> <chave-privada | aleatoria>
// Saída: {remetente, resultado: "MINERADA"|"RECUSADA", hash?, bloco?, status?, erro?, codigo?}
const { ethers } = require('ethers');

(async () => {
  const [rpc, chave] = process.argv.slice(2);
  const provedor = new ethers.JsonRpcProvider(rpc, undefined, { staticNetwork: true });
  const carteira = chave === 'aleatoria'
    ? ethers.Wallet.createRandom().connect(provedor)
    : new ethers.Wallet(chave, provedor);
  const saida = { instante: new Date().toISOString(), rpc, remetente: carteira.address };
  try {
    const tx = await carteira.sendTransaction({
      to: '0x000000000000000000000000000000000000dEaD', value: 0, gasPrice: 0, gasLimit: 21000, type: 0,
    });
    const recibo = await tx.wait(1, 60000);
    Object.assign(saida, { resultado: 'MINERADA', hash: tx.hash, bloco: recibo.blockNumber, status: recibo.status });
  } catch (e) {
    Object.assign(saida, {
      resultado: 'RECUSADA',
      erro: (e.error && e.error.message) || (e.info && e.info.error && e.info.error.message) || e.shortMessage || e.message,
      codigo: (e.error && e.error.code) || (e.info && e.info.error && e.info.error.code) || null,
    });
  }
  console.log(JSON.stringify(saida));
})();
