import '@nomicfoundation/hardhat-ethers';
import hre from 'hardhat';

const GATEWAY_WALLET = '0xB69808E9b18B7E33Fd00c00F0166515C5Fc600E6';
const PAYMENT_SOV   = '0x3451222D576AF7Ee994915C8D2B7b09a738FBF49';
const OFF_RAMP      = '0xBd8536E2EBFD3EB54ed1E717C109a1271Ff87275';

const { ethers } = hre;

const MINTER_ROLE  = ethers.utils.keccak256(ethers.utils.toUtf8Bytes('MINTER_ROLE'));
const GATEWAY_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes('GATEWAY_ROLE'));

const ROLE_ABI = [
  'function grantRole(bytes32 role, address account) external',
  'function hasRole(bytes32 role, address account) view returns (bool)',
];

async function main() {
  const [owner] = await ethers.getSigners();
  console.log(`Signing as: ${owner.address}`);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const paymentSov = new ethers.Contract(PAYMENT_SOV, ROLE_ABI, owner as any);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const offRamp    = new ethers.Contract(OFF_RAMP,    ROLE_ABI, owner as any);

  // --- Grant MINTER_ROLE on PaymentSOV ---
  console.log('\n[1/2] Granting MINTER_ROLE on PaymentSOV...');
  const tx1 = await paymentSov.grantRole(MINTER_ROLE, GATEWAY_WALLET);
  await tx1.wait();
  console.log(`  tx: ${tx1.hash}`);

  const hasMinter = await paymentSov.hasRole(MINTER_ROLE, GATEWAY_WALLET);
  if (!hasMinter) throw new Error('MINTER_ROLE grant failed — hasRole returned false');
  console.log(`  ✅ MINTER_ROLE confirmed`);

  // --- Grant GATEWAY_ROLE on OffRampEscrow ---
  console.log('\n[2/2] Granting GATEWAY_ROLE on OffRampEscrow...');
  const tx2 = await offRamp.grantRole(GATEWAY_ROLE, GATEWAY_WALLET);
  await tx2.wait();
  console.log(`  tx: ${tx2.hash}`);

  const hasGateway = await offRamp.hasRole(GATEWAY_ROLE, GATEWAY_WALLET);
  if (!hasGateway) throw new Error('GATEWAY_ROLE grant failed — hasRole returned false');
  console.log(`  ✅ GATEWAY_ROLE confirmed`);

  console.log('\n✅ Both role grants verified on-chain. Gateway is ready to mint.');
}

main().catch(err => { console.error(err); process.exit(1); });
