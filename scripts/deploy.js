const hre = require("hardhat");

async function main() {
  console.log("🚀 Starting deployment...\n");

  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());
  console.log();

  // Deploy EscrowFactory
  console.log("📦 Deploying EscrowFactory...");
  const EscrowFactory = await ethers.getContractFactory("EscrowFactory");
  const factory = await EscrowFactory.deploy();
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  console.log("✅ EscrowFactory deployed to:", factoryAddress);
  console.log();

  // Deploy HookRegistry
  console.log("📦 Deploying HookRegistry...");
  const HookRegistry = await ethers.getContractFactory("HookRegistry");
  const registry = await HookRegistry.deploy();
  await registry.waitForDeployment();
  const registryAddress = await registry.getAddress();
  console.log("✅ HookRegistry deployed to:", registryAddress);
  console.log();

  // Deploy AllowlistHook (example hook)
  console.log("📦 Deploying AllowlistHook (example)...");
  const AllowlistHook = await ethers.getContractFactory("AllowlistHook");
  const allowlistHook = await AllowlistHook.deploy(deployer.address);
  await allowlistHook.waitForDeployment();
  const allowlistAddress = await allowlistHook.getAddress();
  console.log("✅ AllowlistHook deployed to:", allowlistAddress);
  console.log();

  // Register the hook in the registry
  console.log("📝 Registering AllowlistHook in HookRegistry...");
  const registerTx = await registry.registerHook(
    allowlistAddress,
    "Allowlist Hook ",
    "Compliance hook with allowlist functionality and batch operations",
    "ipfs://QmExampleAuditReport",
    "2.0.0"
  );
  await registerTx.wait();
  console.log("✅ Hook registered");
  console.log();

  // Verify the hook (since deployer is default verifier)
  console.log("✓ Verifying hook...");
  const verifyTx = await registry.verifyHook(allowlistAddress);
  await verifyTx.wait();
  console.log("✅ Hook verified");
  console.log();

  // Deploy GnosisSafeEscrowModule
  console.log("📦 Deploying GnosisSafeEscrowModule...");
  const GnosisSafeEscrowModule = await ethers.getContractFactory("GnosisSafeEscrowModule");
  const safeModule = await GnosisSafeEscrowModule.deploy(factoryAddress);
  await safeModule.waitForDeployment();
  const safeModuleAddress = await safeModule.getAddress();
  console.log("✅ GnosisSafeEscrowModule deployed to:", safeModuleAddress);
  console.log();

  // Summary
  console.log("=" .repeat(60));
  console.log("📋 DEPLOYMENT SUMMARY");
  console.log("=".repeat(60));
  console.log("EscrowFactory:           ", factoryAddress);
  console.log("HookRegistry:            ", registryAddress);
  console.log("AllowlistHook:         ", allowlistAddress);
  console.log("GnosisSafeEscrowModule:  ", safeModuleAddress);
  console.log("=".repeat(60));
  console.log();

  // Save deployment info
  const deploymentInfo = {
    network: hre.network.name,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      EscrowFactory: factoryAddress,
      HookRegistry: registryAddress,
      AllowlistHook: allowlistAddress,
      GnosisSafeEscrowModule: safeModuleAddress,
    },
  };

  console.log("💾 Deployment info:");
  console.log(JSON.stringify(deploymentInfo, null, 2));
  console.log();

  // Verification instructions
  if (hre.network.name !== "hardhat" && hre.network.name !== "localhost") {
    console.log("🔍 To verify contracts on Etherscan, run:");
    console.log(`npx hardhat verify --network ${hre.network.name} ${factoryAddress}`);
    console.log(`npx hardhat verify --network ${hre.network.name} ${registryAddress}`);
    console.log(`npx hardhat verify --network ${hre.network.name} ${allowlistAddress} "${deployer.address}"`);
    console.log(`npx hardhat verify --network ${hre.network.name} ${safeModuleAddress} "${factoryAddress}"`);
    console.log();
  }

  console.log("✨ Deployment complete!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
