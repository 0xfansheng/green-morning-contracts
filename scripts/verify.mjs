import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import sha3 from 'js-sha3';
import solc from 'solc';

const root = fileURLToPath(new URL('../', import.meta.url));
const read = name => readFile(path.join(root, name), 'utf8');
const json = async name => JSON.parse(await read(name));
const keccak = bytes => '0x' + sha3.keccak256(bytes);
const manifest = await json('deployments/bsc.json');
assert.equal(solc.version(), manifest.compiler);
assert.ok(process.argv.length === 2 || (process.argv.length === 3 && process.argv[2] === '--onchain'), 'Use --onchain for historical BSC comparisons.');

async function build(role, info) {
  const input = await json('compiler-input/' + role + '.json');
  for (const [name, contents] of Object.entries(input.sources)) {
    assert.equal(await read(name), contents.content, 'Source file differs from Standard JSON: ' + name);
  }
  const output = JSON.parse(solc.compile(JSON.stringify(input)));
  const failures = (output.errors ?? []).filter(item => item.severity === 'error');
  assert.equal(failures.length, 0, failures.map(item => item.formattedMessage).join('\n'));
  const contract = output.contracts[info.source][info.name];
  assert.deepEqual(contract.abi, await json('abi/' + info.name + '.json'));
  if (info.sourceSHA256) {
    assert.equal(createHash('sha256').update(input.sources[info.source].content).digest('hex'), info.sourceSHA256);
  }
  const creation = Buffer.from(contract.evm.bytecode.object, 'hex');
  assert.equal(keccak(creation), info.creationCodeKeccak256, role + ' creation code');
  const runtime = Buffer.from(contract.evm.deployedBytecode.object, 'hex');
  // The UUPS implementation's only immutable is its own address (__self).
  // solc gives byte offsets in the creation-time runtime template.
  const references = Object.values(contract.evm.deployedBytecode.immutableReferences ?? {});
  assert.equal(references.length, role === 'implementation' ? 1 : 0);
  for (const { start, length } of references.flat()) {
    assert.equal(length, 32);
    Buffer.from(info.address.slice(2).padStart(length * 2, '0'), 'hex').copy(runtime, start);
  }
  assert.equal(runtime.length, info.runtimeBytes);
  assert.equal(keccak(runtime), info.runtimeKeccak256, role + ' deployed runtime');
  console.log(role + ' matches the manifest. Runtime Keccak-256 ' + keccak(runtime));
  return {creation: '0x' + creation.toString('hex'), runtime: '0x' + runtime.toString('hex')};
}

const implementation = await build('implementation', manifest.contracts.implementation);
const proxy = await build('proxy', manifest.contracts.proxy);
if (process.argv.includes('--onchain')) {
  let requestId = 0;
  const endpoints = ['https://bsc-rpc.publicnode.com', 'https://bsc-mainnet.public.blastapi.io'];
  async function rpc(method, params) {
    let last;
    for (const endpoint of endpoints) {
      try {
        const response = await fetch(endpoint, {method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({jsonrpc: '2.0', id: ++requestId, method, params}), signal: AbortSignal.timeout(12000)});
        const result = await response.json();
        if (!response.ok || result.error || result.result == null) throw new Error(result.error?.message || 'Missing RPC result');
        return result.result;
      } catch (error) { last = error; }
    }
    throw last;
  }
  const address = manifest.contracts.proxy.address, impl = manifest.contracts.implementation.address;
  const tag = '0x' + manifest.verifiedAtBlock.toString(16);
  const [network, block, slot, actualImpl, actualProxy, creation, created, upgrade, implCreation, implCreated] = await Promise.all([
    rpc('eth_chainId', []), rpc('eth_getBlockByNumber', [tag, false]),
    rpc('eth_getStorageAt', [address, manifest.implementationSlot, tag]),
    rpc('eth_getCode', [impl, tag]), rpc('eth_getCode', [address, tag]),
    rpc('eth_getTransactionByHash', [manifest.proxyCreationTransaction]),
    rpc('eth_getTransactionReceipt', [manifest.proxyCreationTransaction]),
    rpc('eth_getTransactionReceipt', [manifest.upgrade.transaction]),
    rpc('eth_getTransactionByHash', [manifest.implementationCreationTransaction]),
    rpc('eth_getTransactionReceipt', [manifest.implementationCreationTransaction])
  ]);
  assert.equal(Number(network), manifest.chainId);
  assert.equal(block.hash, manifest.blockHash);
  assert.equal('0x' + slot.slice(-40), impl.toLowerCase());
  assert.equal(actualImpl, implementation.runtime);
  assert.equal(actualProxy, proxy.runtime);
  assert.equal(implCreation.input, implementation.creation);
  assert.equal(Number(implCreated.blockNumber), manifest.implementationCreationBlock);
  assert.equal(implCreated.contractAddress, impl.toLowerCase());
  assert.equal(implCreated.status, '0x1');
  assert.equal(creation.input, proxy.creation + manifest.contracts.proxy.constructorArgs.slice(2));
  assert.equal(created.contractAddress, address.toLowerCase());
  assert.equal(Number(created.blockNumber), manifest.proxyCreationBlock);
  assert.equal(upgrade.status, '0x1');
  assert.equal(upgrade.to, address.toLowerCase());
  assert.equal(Number(upgrade.blockNumber), manifest.upgrade.block);
  assert.ok(upgrade.logs.some(log => log.address === address.toLowerCase() && log.topics[0] === keccak('Upgraded(address)')
    && '0x' + log.topics[1]?.slice(-40) === impl.toLowerCase()));
  console.log('BSC block ' + manifest.verifiedAtBlock + ': both deployed bytecodes, implementation slot and deployment receipts verified.');
}
