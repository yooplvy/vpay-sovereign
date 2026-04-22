// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../CircuitBreaker.sol";
import "../SovereignNode.sol";
import "../MinerRewards.sol";
import "../AttestationBridge.sol";
import "../VPAYVault.sol";
import "../GuardianBond.sol";
import "../interfaces/ISovereignToken.sol";

/**
 * @title DeployTestnet
 * @author ANO-YOOFI-AGYEI
 * @notice Testnet deployment for VPAY Genesis v2 on Polygon Amoy.
 *
 *         Deploys the full stack using the deployer wallet as all roles
 *         (relayer, oracle, guardian) for testing. In production, these
 *         are separate wallets/multisigs.
 *
 *         RUN:
 *         ────
 *         cd contracts
 *         forge script deploy/DeployTestnet.s.sol \
 *           --rpc-url $AMOY_RPC_URL \
 *           --broadcast \
 *           --verify \
 *           --etherscan-api-key $POLYGONSCAN_API_KEY \
 *           -vvvv
 */
contract DeployTestnet is Script {
    /// @notice Deployer wallet (same as mainnet deployer for testnet).
    address constant DEPLOYER = 0xc899eCe085ffB1382c85B0f2159F100c09D5EAc0;

    /// @notice Mock USDC on Amoy (if available, or deploy own).
    ///         Set via env var; defaults to deploying a test stablecoin.
    address public stablecoinAddr;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        stablecoinAddr = vm.envOr("TESTNET_USDC", address(0));

        vm.startBroadcast(deployerKey);

        // ════════════════════════════════════════
        // STEP 0: Deploy test $SOV (testnet only)
        // ════════════════════════════════════════
        // On testnet we deploy a fresh $SOV since mainnet $SOV isn't on Amoy
        TestSOV testSov = new TestSOV();
        console.log("0. TestSOV deployed:", address(testSov));

        // Deploy test stablecoin if not provided
        if (stablecoinAddr == address(0)) {
            TestUSDC testUsdc = new TestUSDC();
            stablecoinAddr = address(testUsdc);
            console.log("0b. TestUSDC deployed:", stablecoinAddr);
        }

        // ════════════════════════════════════════
        // STEP 1: CircuitBreaker
        // ════════════════════════════════════════
        CircuitBreaker circuitBreaker = new CircuitBreaker();
        console.log("1. CircuitBreaker:", address(circuitBreaker));

        // ════════════════════════════════════════
        // STEP 2: SovereignNode
        // ════════════════════════════════════════
        SovereignNode sovereignNode = new SovereignNode(address(circuitBreaker));
        console.log("2. SovereignNode:", address(sovereignNode));

        // ════════════════════════════════════════
        // STEP 3: MinerRewards
        // ════════════════════════════════════════
        MinerRewards minerRewards = new MinerRewards(address(testSov));
        console.log("3. MinerRewards:", address(minerRewards));

        // ════════════════════════════════════════
        // STEP 4: AttestationBridge
        // ════════════════════════════════════════
        AttestationBridge bridge = new AttestationBridge(
            address(sovereignNode),
            address(testSov),
            address(circuitBreaker),
            address(minerRewards)
        );
        console.log("4. AttestationBridge:", address(bridge));

        // ════════════════════════════════════════
        // STEP 5: VPAYVault
        // ════════════════════════════════════════
        VPAYVault vault = new VPAYVault(
            stablecoinAddr,
            address(sovereignNode),
            address(testSov),
            address(circuitBreaker)
        );
        console.log("5. VPAYVault:", address(vault));

        // ════════════════════════════════════════
        // STEP 6: GuardianBond
        // ════════════════════════════════════════
        // Use deployer as ArbitrationChamber placeholder for testnet
        GuardianBond guardianBond = new GuardianBond(address(testSov), DEPLOYER);
        console.log("6. GuardianBond:", address(guardianBond));

        // ════════════════════════════════════════
        // STEP 7: Role Grants
        // ════════════════════════════════════════
        // Bridge needs MINTER_ROLE on $SOV
        testSov.grantRole(keccak256("MINTER_ROLE"), address(bridge));
        console.log("7a. MINTER_ROLE -> Bridge");

        // Bridge needs DISTRIBUTOR_ROLE on MinerRewards
        minerRewards.grantRole(minerRewards.DISTRIBUTOR_ROLE(), address(bridge));
        console.log("7b. DISTRIBUTOR_ROLE -> Bridge");

        // Deployer gets NODE_ROLE for manual testing
        sovereignNode.grantRole(sovereignNode.NODE_ROLE(), DEPLOYER);
        console.log("7c. NODE_ROLE -> Deployer (testing)");

        vm.stopBroadcast();

        // ════════════════════════════════════════
        // SUMMARY
        // ════════════════════════════════════════
        console.log("\n========================================");
        console.log("   VPAY GENESIS v2 - AMOY TESTNET");
        console.log("========================================");
        console.log("TestSOV:           ", address(testSov));
        console.log("TestUSDC:          ", stablecoinAddr);
        console.log("CircuitBreaker:    ", address(circuitBreaker));
        console.log("SovereignNode:     ", address(sovereignNode));
        console.log("MinerRewards:      ", address(minerRewards));
        console.log("AttestationBridge: ", address(bridge));
        console.log("VPAYVault:         ", address(vault));
        console.log("GuardianBond:      ", address(guardianBond));
        console.log("========================================\n");
    }
}

// ════════════════════════════════════════════════════════════════
// TEST TOKEN CONTRACTS (Testnet Only)
// ════════════════════════════════════════════════════════════════

/**
 * @notice Minimal $SOV for testnet — AccessControl + mint/burn.
 */
contract TestSOV {
    string public constant name = "Sovereign Token (Testnet)";
    string public constant symbol = "tSOV";
    uint8 public constant decimals = 18;
    uint256 public constant MAX_SUPPLY = 100_000_000e18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    mapping(bytes32 => mapping(address => bool)) private _roles;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        _roles[DEFAULT_ADMIN_ROLE][msg.sender] = true;
        _roles[MINTER_ROLE][msg.sender] = true;
        _roles[BURNER_ROLE][msg.sender] = true;
        // Mint 1M to deployer for testing
        totalSupply = 1_000_000e18;
        balanceOf[msg.sender] = 1_000_000e18;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient");
        require(allowance[from][msg.sender] >= amount, "Not approved");
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        require(_roles[MINTER_ROLE][msg.sender], "Not minter");
        require(totalSupply + amount <= MAX_SUPPLY, "Cap exceeded");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function burnFrom(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "Insufficient");
        require(allowance[from][msg.sender] >= amount, "Not approved");
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external {
        require(_roles[DEFAULT_ADMIN_ROLE][msg.sender], "Not admin");
        _roles[role][account] = true;
    }
}

contract TestUSDC {
    string public constant name = "USD Coin (Testnet)";
    string public constant symbol = "tUSDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor() {
        // Mint 10M USDC to deployer for testing
        totalSupply = 10_000_000e6;
        balanceOf[msg.sender] = 10_000_000e6;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount);
        require(allowance[from][msg.sender] >= amount);
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
}
