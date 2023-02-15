/*global process*/

const { ethers } = require("hardhat");
const { LedgerSigner } = require("@anders-t/ethers-ledger");

async function main() {
    const fs = require("fs");
    const globalsFile = "globals.json";
    const dataFromJSON = fs.readFileSync(globalsFile, "utf8");
    let parsedData = JSON.parse(dataFromJSON);
    const useLedger = parsedData.useLedger;
    const derivationPath = parsedData.derivationPath;
    const providerName = parsedData.providerName;
    let EOA;

    const provider = await ethers.providers.getDefaultProvider(providerName);
    const signers = await ethers.getSigners();

    if (useLedger) {
        EOA = new LedgerSigner(provider, derivationPath);
    } else {
        EOA = signers[0];
    }
    // EOA address
    const deployer = await EOA.getAddress();
    console.log("EOA is:", deployer);

    // Get all the necessary contract addresses
    const olasAddress = parsedData.olasAddress;
    const timelockAddress = parsedData.timelockAddress;
    const veOLASAddress = parsedData.veOLASAddress;
    const componentRegistryAddress = parsedData.componentRegistryAddress;
    const agentRegistryAddress = parsedData.agentRegistryAddress;
    const serviceRegistryAddress = parsedData.serviceRegistryAddress;
    const epochLen = parsedData.epochLen;
    const donatorBlacklistAddress = parsedData.donatorBlacklistAddress;
    const tokenomicsMasterAddress = parsedData.tokenomicsMasterAddress;

    // Assemble the tokenomics proxy data
    const tokenomicsMaster = await ethers.getContractAt("Tokenomics", tokenomicsMasterAddress);
    const proxyData = tokenomicsMaster.interface.encodeFunctionData("initializeTokenomics",
        [olasAddress, timelockAddress, timelockAddress, timelockAddress, veOLASAddress, epochLen,
            componentRegistryAddress, agentRegistryAddress, serviceRegistryAddress, donatorBlacklistAddress]);

    // Transaction signing and execution
    console.log("3. EOA to deploy TokenomicsProxy");
    const TokenomicsProxy = await ethers.getContractFactory("TokenomicsProxy");
    console.log("You are signing the following transaction: TokenomicsProxy.connect(EOA).deploy()");
    const tokenomicsProxy = await TokenomicsProxy.connect(EOA).deploy(tokenomicsMasterAddress, proxyData);
    const result = await tokenomicsProxy.deployed();

    // Transaction details
    console.log("Contract deployment: TokenomicsProxy");
    console.log("Contract address:", tokenomicsProxy.address);
    console.log("Transaction:", result.deployTransaction.hash);

    // Contract verification
    if (parsedData.contractVerification) {
        const execSync = require("child_process").execSync;
        execSync("npx hardhat verify --constructor-args scripts/deployment/verify_03_tokenomics_proxy.js --network " + providerName + " " + tokenomicsProxy.address, { encoding: "utf-8" });
    }

    // Writing updated parameters back to the JSON file
    parsedData.tokenomicsProxyAddress = tokenomicsProxy.address;
    fs.writeFileSync(globalsFile, JSON.stringify(parsedData));

    // Writing the proxyData to a separate file
    fs.writeFileSync("proxyData.txt", proxyData);
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
