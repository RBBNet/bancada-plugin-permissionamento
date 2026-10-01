// Envia uma transação simples (valor 0, gasPrice 0) e imprime o resultado em JSON.
// Uso: node tx.js <url-rpc> <chave-privada | aleatoria>
// Saída: {remetente, resultado: "MINERADA"|"RECUSADA"|"ERRO", hash?, bloco?, status?, erro?, codigo?, resumo}
//   RECUSADA = o nó respondeu com erro JSON-RPC (tem código); ERRO = tempo esgotado, rede etc.
//   resumo = texto curto para as verificações: "MINERADA, status 1" | "RECUSADA: <código> <mensagem>" | "ERRO: <mensagem>"
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
    if (e.receipt) {  // minerada com status 0 (ethers lança CALL_EXCEPTION)
      Object.assign(saida, { resultado: 'MINERADA', hash: e.receipt.hash, bloco: e.receipt.blockNumber, status: e.receipt.status });
    } else {
      const codigo = (e.error && e.error.code) || (e.info && e.info.error && e.info.error.code) || null;
      Object.assign(saida, {
        resultado: codigo !== null ? 'RECUSADA' : 'ERRO',
        erro: (e.error && e.error.message) || (e.info && e.info.error && e.info.error.message) || e.shortMessage || e.message || e.code || String(e),
        codigo,
      });
    }
  }
  saida.resumo = saida.resultado === 'MINERADA' ? `MINERADA, status ${saida.status}`
    : saida.resultado === 'RECUSADA' ? `RECUSADA: ${saida.codigo} ${saida.erro}` : `ERRO: ${saida.erro}`;
  console.log(JSON.stringify(saida));
  process.exit(0);  // o provedor do ethers mantém tentativas de conexão pendentes
})();
