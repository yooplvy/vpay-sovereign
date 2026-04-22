// SPDX-License-Identifier: VPAY-1.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../CircuitBreaker.sol";
import "../SovereignNode.sol";
import "../MinerRewards.sol";
import "../AttestationBridge.sol";
import "../VPAYVault.sol";
import "../GuardianBond.sol";
import "../interfaces/ISovereignToken.sol";

// ════════════════════════════════════════════════════════════════
// MOCK CONTRACTS FOR TESTING
// ════════════════════════════════════════════════════════════════

/**
 * @notice Minimal $SOV mock for integration testing.
 *         Implements ISovereignToken with mint/burn and role checks.
 */
contract MockSovereignToken is ISovereignToken {
    string public constant name = "Sovereign Token";
    string public constant symbol = "SOV";
    uint8 public constant decimals = 18;
    uint256 public constant MAX_SUPPLY = 100_000_000e18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    mapping(bytes32 => mapping(address => bool)) private _roles;
    address public admin;

    constructor() {
        admin = msg.sender;
        _roles[DEFAULT_ADMIN_ROLE][msg.sender] = true;
        _roles[MINTER_ROLE][msg.sender] = true;
        _roles[BURNER_ROLE][msg.sender] = true;
    }

    // ERC20
    function totalSupply() external view returns (uint256) { return _totalSupply; }
    function balanceOf(address a) external view returns (uint256) { return _balances[a]; }
    function allowance(address o, address s) external view returns (uint256) { return _allowances[o][s]; }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(_balances[msg.sender] >= amount, "Insufficient");
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_balances[from] >= amount, "Insufficient");
        require(_allowances[from][msg.sender] >= amount, "Not approved");
        _balances[from] -= amount;
        _allowances[from][msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    // ISovereignToken extensions
    function mint(address to, uint256 amount) external {
        require(_roles[MINTER_ROLE][msg.sender], "Not minter");
        require(_totalSupply + amount <= MAX_SUPPLY, "Cap exceeded");
        _totalSupply += amount;
        _balances[to] += amount;
    }

    function burn(uint256 amount) external {
        require(_balances[msg.sender] >= amount, "Insufficient");
        _balances[msg.sender] -= amount;
        _totalSupply -= amount;
    }

    function burnFrom(address from, uint256 amount) external {
        require(_balances[from] >= amount, "Insufficient");
        require(_allowances[from][msg.sender] >= amount, "Not approved");
        _balances[from] -= amount;
        _allowances[from][msg.sender] -= amount;
        _totalSupply -= amount;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external {
        require(_roles[DEFAULT_ADMIN_ROLE][msg.sender], "Not admin");
        _roles[role][account] = true;
    }

    function revokeRole(bytes32 role, address account) external {
        require(_roles[DEFAULT_ADMIN_ROLE][msg.sender], "Not admin");
        _roles[role][account] = false;
    }

    // Test helpers
    function mintDirect(address to, uint256 amount) external {
        _totalSupply += amount;
        _balances[to] += amount;
    }
}

contract MockStablecoin {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount);
        require(allowance[from][msg.sender] >= amount);
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ════════════════════════════════════════════════════════════════
// INTEGRATION TEST SUITE
// ════════════════════════════════════════════════════════════════

/**
 * @title VPAYGenesisIntegrationTest
 * @notice End-to-end integration tests for the VPAY Genesis v2 contract stack.
 *
 *         Tests cover the full lifecycle:
 *         1. Deployment & role configuration
 *         2. Node registration on SovereignNode
 *         3. Attestation submission (GSU physics data)
 *         4. AttestationBridge: confirmAndMint -> $SOV minting
 *         5. MinerRewards: credit + claim flow
 *         6. VPAYVault: lock collateral -> borrow -> repay
 *         7. CircuitBreaker: pause/resume with delay
 *         8. GuardianBond: deposit -> slash -> withdrawal
 *         9. Cross-contract pause enforcement
 *        10. Edge cases and failure modes
 */
contract VPAYGenesisIntegrationTest is Test {
    using ECDSA for bytes32;

    // ── TPM Key Pair (for ECDSA-signed attestations) ──
    uint256 constant TPM_PRIVATE_KEY = 0xA11CE;
    address tpmAddress;

    // ── Actors ──
    address deployer = address(this);
    address relayer = address(0xAA01);
    address operator1 = address(0xAA02);
    address guardian1 = address(0xAA03);
    address borrower = address(0xAA04);
    address recipient = address(0xAA05);

    // ── Contracts ──
    MockSovereignToken sov;
    MockStablecoin usdc;
    CircuitBreaker circuitBreaker;
    SovereignNode sovereignNode;
    MinerRewards minerRewards;
    AttestationBridge bridge;
    VPAYVault vault;
    GuardianBond guardianBond;

    // ── Test Data ──
    bytes32 constant NODE_ID = keccak256("GSU-ACCRA-001");
    bytes32 constant NODE_ID_2 = keccak256("GSU-KUMASI-002");

    function setUp() public {
        // Derive TPM address from private key
        tpmAddress = vm.addr(TPM_PRIVATE_KEY);

        // ── Deploy mocks ──
        sov = new MockSovereignToken();
        usdc = new MockStablecoin();

        // ── Deploy stack in order ──
        circuitBreaker = new CircuitBreaker();
        sovereignNode = new SovereignNode(address(circuitBreaker));
        minerRewards = new MinerRewards(address(sov));
        bridge = new AttestationBridge(
            address(sovereignNode),
            address(sov),
            address(circuitBreaker),
            address(minerRewards)
        );
        vault = new VPAYVault(
            address(usdc),
            address(sovereignNode),
            address(sov),
            address(circuitBreaker)
        );
        guardianBond = new GuardianBond(address(sov), deployer); // deployer as chamber for tests

        // ── Configure roles ──
        // AttestationBridge needs MINTER_ROLE on $SOV
        sov.grantRole(keccak256("MINTER_ROLE"), address(bridge));

        // AttestationBridge needs DISTRIBUTOR_ROLE on MinerRewards
        minerRewards.grantRole(minerRewards.DISTRIBUTOR_ROLE(), address(bridge));

        // Relayer needs RELAYER_ROLE on bridge
        bridge.grantRole(bridge.RELAYER_ROLE(), relayer);

        // Grant NODE_ROLE to deployer (test contract) for attestation submission
        sovereignNode.grantRole(sovereignNode.NODE_ROLE(), deployer);

        // ── Register operator for mining rewards ──
        minerRewards.registerOperator(NODE_ID, operator1);

        // ── Fund accounts ──
        usdc.mint(address(vault), 10_000_000e6); // Vault liquidity: 10M USDC
        usdc.mint(borrower, 1_000_000e6);        // Borrower funds for repayment
        sov.mintDirect(guardian1, 5000e18);       // Guardian bond deposit
        sov.mintDirect(borrower, 1000e18);        // Borrower $SOV for interest

        // ── Label addresses for trace readability ──
        vm.label(relayer, "Relayer");
        vm.label(operator1, "Operator1");
        vm.label(guardian1, "Guardian1");
        vm.label(borrower, "Borrower");
        vm.label(recipient, "Recipient");
        vm.label(tpmAddress, "TPM-Key");
    }

    // ════════════════════════════════════════════════════════════
    // HELPER: Sign attestation data with TPM private key
    // ════════════════════════════════════════════════════════════

    function _signAttestation(
        bytes32 _nodeId,
        uint256 _massGrams,
        uint256 _purityBps,
        uint256 _karatE2,
        uint256 _tempCE2,
        bool _sealIntact,
        int32 _gpsLatE6,
        int32 _gpsLonE6,
        bytes32 _spectrumHash
    ) internal pure returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Attestation(bytes32 nodeId,uint256 massGrams,uint256 purityBps,uint256 karatE2,uint256 tempCE2,bool sealIntact,int32 gpsLatE6,int32 gpsLonE6,bytes32 spectrumHash)"),
            _nodeId, _massGrams, _purityBps, _karatE2, _tempCE2, _sealIntact, _gpsLatE6, _gpsLonE6, _spectrumHash
        ));
        bytes32 ethHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TPM_PRIVATE_KEY, ethHash);
        return abi.encodePacked(r, s, v);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 1: Full Attestation -> Mint Pipeline
    // ════════════════════════════════════════════════════════════

    function test_FullAttestationToMintPipeline() public {
        // Step 1: Register GSU node with TPM public key
        sovereignNode.registerNode(
            NODE_ID,
            tpmAddress,
            1,           // tier
            5536100,     // GPS lat (Accra: 5.5361N x 1e6)
            -197000      // GPS lon (Accra: -0.197W x 1e6)
        );
        assertTrue(sovereignNode.isNodeActive(NODE_ID));

        // Step 2: Submit attestation with proper ECDSA signature
        bytes32 spectrumHash = keccak256("xrf-spectrum-data");
        bytes memory sig = _signAttestation(
            NODE_ID, 500, 9950, 2388, 2500, true, 5536100, -197000, spectrumHash
        );

        sovereignNode.submitAttestation(
            NODE_ID,
            500,         // massGrams (500g gold bar)
            9950,        // purityBps (99.50%)
            2388,        // karatE2 (23.88K)
            2500,        // tempCE2 (25.00C)
            true,        // sealIntact
            5536100,     // gpsLatE6
            -197000,     // gpsLonE6
            50,          // gpsAccuracyDm (5.0m)
            spectrumHash,
            sig
        );
        assertEq(sovereignNode.attestationCount(NODE_ID), 1);

        // Step 3: Relayer calls confirmAndMint on AttestationBridge
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);

        // Step 4: Verify $SOV was minted
        // Contract does runtime integer math: 500 * 9950 / 10000 = 497 (truncated)
        // Hardcode to match contract's runtime integer division behavior
        uint256 totalSov = 497e15; // 500*9950/10000 = 497 pure grams, /1000 for SOV
        uint256 minerShare = (totalSov * 500) / 10000; // 5%
        uint256 recipientShare = totalSov - minerShare;

        assertEq(sov.balanceOf(recipient), recipientShare);
        // Bridge mints minerShare to MinerRewards pool (tokens held, not yet credited)
        assertEq(sov.balanceOf(address(minerRewards)), minerShare);

        // Step 5: Bridge auto-credited reward via creditReward() — operator just claims
        assertEq(minerRewards.unclaimedRewards(operator1), minerShare, "Auto-credit failed");
        vm.prank(operator1);
        minerRewards.claim();
        assertEq(sov.balanceOf(operator1), minerShare);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 2: Double-Mint Prevention (same attestation hash)
    // ════════════════════════════════════════════════════════════

    function test_DoubleMintPrevention() public {
        _registerNodeAndAttest(NODE_ID, 500, 9950);

        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);

        // Second attempt with same attestation hash should revert
        vm.expectRevert(BRIDGE__AlreadyProcessed.selector);
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 2b: GPS Coordinates in Hash Verification
    // ════════════════════════════════════════════════════════════

    function test_GPSInHashVerification() public {
        // Register node with specific GPS coordinates
        sovereignNode.registerNode(NODE_ID, tpmAddress, 1, 5536100, -197000);

        // Submit attestation with coordinates
        bytes32 spectrum1 = keccak256("xrf-spectrum-1");
        bytes memory sig1 = _signAttestation(
            NODE_ID, 500, 9950, 2388, 2500, true, 5536100, -197000, spectrum1
        );

        sovereignNode.submitAttestation(
            NODE_ID, 500, 9950, 2388, 2500, true,
            5536100, -197000, 50,
            spectrum1, sig1
        );

        // Mint the first attestation
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);

        // Submit another attestation with DIFFERENT GPS coordinates but same mass/purity
        bytes32 spectrum2 = keccak256("xrf-spectrum-2");
        bytes memory sig2 = _signAttestation(
            NODE_ID, 500, 9950, 2388, 2500, true, 5537100, -207000, spectrum2
        );

        sovereignNode.submitAttestation(
            NODE_ID, 500, 9950, 2388, 2500, true,
            5537100, -207000, 50,
            spectrum2, sig2
        );

        // This should succeed (different attestation due to different spectrum)
        uint256 balBefore = sov.balanceOf(recipient);
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 1, recipient);

        // Second mint should increase recipient balance
        assertTrue(sov.balanceOf(recipient) > balBefore);
        // Verify bridge tracked both mints
        assertEq(bridge.nodeMintCount(NODE_ID), 2);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 3: Purity Threshold Enforcement
    // ════════════════════════════════════════════════════════════

    function test_BelowMinPurityRejected() public {
        _registerNodeAndAttest(NODE_ID, 500, 9000); // 90.00% < 91.50% min

        vm.expectRevert(BRIDGE__BelowMinPurity.selector);
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 4: CircuitBreaker Global Pause
    // ════════════════════════════════════════════════════════════

    function test_GlobalPauseBlocksMinting() public {
        _registerNodeAndAttest(NODE_ID, 500, 9950);

        // Pause the protocol
        circuitBreaker.setGlobalPause("Security incident detected");
        assertTrue(circuitBreaker.globalPaused());

        // Minting should be blocked
        vm.expectRevert(BRIDGE__Paused.selector);
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);

        // Resume after delay
        vm.warp(block.timestamp + 5 minutes + 1);
        circuitBreaker.globalResume();
        assertFalse(circuitBreaker.globalPaused());

        // Now minting works
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);
        assertTrue(sov.balanceOf(recipient) > 0);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 5: Node-Level Pause
    // ════════════════════════════════════════════════════════════

    function test_NodePauseBlocksSpecificNode() public {
        _registerNodeAndAttest(NODE_ID, 500, 9950);
        _registerNodeAndAttest(NODE_ID_2, 300, 9500);
        minerRewards.registerOperator(NODE_ID_2, operator1);

        // Pause only NODE_ID
        circuitBreaker.setNodePause(NODE_ID, "Seal integrity concern");

        // NODE_ID blocked
        vm.expectRevert(BRIDGE__Paused.selector);
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);

        // NODE_ID_2 still works
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID_2, 0, recipient);
        assertTrue(sov.balanceOf(recipient) > 0);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 6: Resume Delay Enforcement
    // ════════════════════════════════════════════════════════════

    function test_FlashResumeBlocked() public {
        circuitBreaker.setGlobalPause("Test pause");

        // Try to resume immediately -- should fail
        vm.expectRevert("Resume delay not met");
        circuitBreaker.globalResume();

        // Advance 4 minutes -- still too early
        vm.warp(block.timestamp + 4 minutes);
        vm.expectRevert("Resume delay not met");
        circuitBreaker.globalResume();

        // Advance past 5 minute delay -- succeeds
        vm.warp(block.timestamp + 2 minutes);
        circuitBreaker.globalResume();
        assertFalse(circuitBreaker.globalPaused());
    }

    // ════════════════════════════════════════════════════════════
    // TEST 7: VPAYVault Lending Lifecycle
    // ════════════════════════════════════════════════════════════

    function test_VaultLendingLifecycle() public {
        _registerNodeAndAttest(NODE_ID, 1000, 9950); // 1kg, 99.5%

        // Update vault attestation cache and gold price (oracle role)
        vault.updateAttestation(NODE_ID, 1000, 9950, 2500, true);
        vault.updateGoldPrice(15_300_000); // $153/gram = ~$4,760/oz (realistic)

        // Borrow against gold collateral
        // Collateral: 1000g * 9950/10000 * $153/g = $152,235
        // At 150% collateral, max borrow ~$101K. Use $50K to be safe.
        uint256 borrowAmount = 50_000e6; // $50,000 USDC
        vm.prank(borrower);
        vault.lockAndBorrow(NODE_ID, borrowAmount, 30); // 30-day term

        // Verify loan state
        (uint256 amount,,, uint32 termDays, uint64 startTime, bool isActive) = vault.loans(NODE_ID);
        assertEq(amount, borrowAmount);
        assertTrue(isActive);
        assertEq(vault.totalLoansIssued(), 1);

        // Advance 15 days and repay
        vm.warp(block.timestamp + 15 days);

        // Borrower approves stablecoin + $SOV for repayment
        vm.startPrank(borrower);
        usdc.approve(address(vault), type(uint256).max);
        sov.approve(address(vault), type(uint256).max); // Approve enough for interest

        vault.repay(NODE_ID);
        vm.stopPrank();

        // Verify loan closed
        (,,,,, bool isActiveAfter) = vault.loans(NODE_ID);
        assertFalse(isActiveAfter);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 8: Min Bond Enforcement
    // ════════════════════════════════════════════════════════════

    function test_MinBondEnforcement() public {
        address lowGuardian = address(0xAA06);
        uint256 belowMinimum = 500e18; // Below default 1000e18 minimum

        vm.deal(lowGuardian, 1 ether);
        sov.mintDirect(lowGuardian, belowMinimum);

        vm.startPrank(lowGuardian);
        sov.approve(address(guardianBond), belowMinimum);

        // Should reject deposit below minimum
        vm.expectRevert("Below minimum bond");
        guardianBond.depositBond(belowMinimum);
        vm.stopPrank();

        // Deposit at exact minimum should succeed
        uint256 atMinimum = 1000e18;
        sov.mintDirect(lowGuardian, atMinimum);
        vm.startPrank(lowGuardian);
        sov.approve(address(guardianBond), atMinimum);
        guardianBond.depositBond(atMinimum);
        vm.stopPrank();

        (,uint256 sovAmt, bool active,) = guardianBond.getBond(lowGuardian);
        assertEq(sovAmt, atMinimum);
        assertTrue(active);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 8b: GuardianBond Deposit + Slash + Withdrawal
    // ════════════════════════════════════════════════════════════

    function test_GuardianBondLifecycle() public {
        uint256 sovDeposit = 2000e18;

        // Guardian approves and deposits $SOV bond
        vm.startPrank(guardian1);
        sov.approve(address(guardianBond), sovDeposit);
        guardianBond.depositBond(sovDeposit);
        vm.stopPrank();

        // Verify bond
        (uint256 ethAmt, uint256 sovAmt, bool active,) = guardianBond.getBond(guardian1);
        assertEq(sovAmt, sovDeposit);
        assertTrue(active);
        assertEq(guardianBond.activeGuardians(), 1);

        // Partial slash (25% = 2500 bps) -- deployer has ARBITRATOR_ROLE
        guardianBond.slash(guardian1, recipient, 2500);

        // Verify partial slash
        (, uint256 sovAfterSlash,,) = guardianBond.getBond(guardian1);
        assertEq(sovAfterSlash, sovDeposit * 75 / 100); // 75% remaining

        // Request withdrawal
        vm.prank(guardian1);
        guardianBond.requestWithdrawal();

        // Can't withdraw before timelock
        vm.expectRevert("Timelock active");
        vm.prank(guardian1);
        guardianBond.withdraw();

        // Advance past 7-day timelock
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(guardian1);
        guardianBond.withdraw();

        // Verify fully withdrawn
        (,, bool activeAfter,) = guardianBond.getBond(guardian1);
        assertFalse(activeAfter);
        assertEq(guardianBond.activeGuardians(), 0);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 9: Seal Breach -> Mint Rejection
    // ════════════════════════════════════════════════════════════

    function test_SealBreachBlocksMinting() public {
        sovereignNode.registerNode(NODE_ID, tpmAddress, 1, 5536100, -197000);

        // Submit attestation with broken seal
        bytes32 specHash = keccak256("xrf");
        bytes memory sig = _signAttestation(
            NODE_ID, 500, 9950, 2388, 2500, false, 5536100, -197000, specHash
        );

        sovereignNode.submitAttestation(
            NODE_ID, 500, 9950, 2388, 2500,
            false, // sealIntact = false
            5536100, -197000, 50,
            specHash, sig
        );

        vm.expectRevert(BRIDGE__SealBroken.selector);
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 10: Vault Liquidation on Seal Breach
    // ════════════════════════════════════════════════════════════

    function test_VaultLiquidationOnSealBreach() public {
        _registerNodeAndAttest(NODE_ID, 1000, 9950);
        vault.updateAttestation(NODE_ID, 1000, 9950, 2500, true);
        vault.updateGoldPrice(15_300_000); // $153/gram

        // Borrow
        vm.prank(borrower);
        vault.lockAndBorrow(NODE_ID, 50_000e6, 30);

        // Oracle reports seal breach
        vault.updateAttestation(NODE_ID, 1000, 9950, 2500, false);

        // Anyone can trigger liquidation
        vault.liquidate(NODE_ID);

        // Verify liquidated
        (,,,,, bool isActive) = vault.loans(NODE_ID);
        assertFalse(isActive);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 11: Batch Operations
    // ════════════════════════════════════════════════════════════

    function test_BatchNodePause() public {
        bytes32[] memory nodeIds = new bytes32[](2);
        nodeIds[0] = NODE_ID;
        nodeIds[1] = NODE_ID_2;

        circuitBreaker.batchNodePause(nodeIds, "Maintenance window");

        assertTrue(circuitBreaker.nodePaused(NODE_ID));
        assertTrue(circuitBreaker.nodePaused(NODE_ID_2));
        assertFalse(circuitBreaker.isOperational(NODE_ID));
    }

    function test_BatchCreditReward() public {
        minerRewards.registerOperator(NODE_ID_2, operator1);

        bytes32[] memory nodeIds = new bytes32[](2);
        nodeIds[0] = NODE_ID;
        nodeIds[1] = NODE_ID_2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 200e18;

        minerRewards.batchCreditReward(nodeIds, amounts);
        assertEq(minerRewards.unclaimedRewards(operator1), 300e18);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 11b: Batch Size Limits
    // ════════════════════════════════════════════════════════════

    function test_BatchSizeLimitMinerRewards() public {
        // Create 101 node IDs and amounts
        bytes32[] memory nodeIds = new bytes32[](101);
        uint256[] memory amounts = new uint256[](101);

        for (uint256 i = 0; i < 101; i++) {
            nodeIds[i] = keccak256(abi.encode("node", i));
            amounts[i] = 100e18;
        }

        // Should reject batch of 101 (exceeds limit of 100)
        vm.expectRevert("Batch too large");
        minerRewards.batchCreditReward(nodeIds, amounts);
    }

    function test_BatchSizeLimitCircuitBreaker() public {
        // Create 101 node IDs
        bytes32[] memory nodeIds = new bytes32[](101);

        for (uint256 i = 0; i < 101; i++) {
            nodeIds[i] = keccak256(abi.encode("node", i));
        }

        // Should reject batch of 101 (exceeds limit of 100)
        vm.expectRevert("Batch too large");
        circuitBreaker.batchNodePause(nodeIds, "Too many nodes");
    }

    function test_BatchSizeAtLimit() public {
        // Create exactly 100 node IDs (at limit)
        bytes32[] memory nodeIds = new bytes32[](100);

        for (uint256 i = 0; i < 100; i++) {
            nodeIds[i] = keccak256(abi.encode("node", i));
        }

        // Should succeed at limit of 100
        circuitBreaker.batchNodePause(nodeIds, "Maintenance");

        // Verify a few were paused
        assertTrue(circuitBreaker.nodePaused(nodeIds[0]));
        assertTrue(circuitBreaker.nodePaused(nodeIds[99]));
    }

    // ════════════════════════════════════════════════════════════
    // TEST 12: Supply Cap Enforcement
    // ════════════════════════════════════════════════════════════

    function test_SupplyCapPreventsOverMint() public {
        // Mint close to cap
        sov.mintDirect(address(1), 99_999_999e18);

        _registerNodeAndAttest(NODE_ID, 500000, 9950); // Huge amount to exceed cap

        vm.expectRevert(BRIDGE__SupplyCapReached.selector);
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 13: Stale Attestation Rejection (Bridge)
    // ════════════════════════════════════════════════════════════

    function test_StaleAttestationRejected() public {
        _registerNodeAndAttest(NODE_ID, 500, 9950);

        // Advance past maxAttestationAge (1 hour)
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(BRIDGE__InvalidAttestation.selector);
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 13b: Oracle Freshness Check
    // ════════════════════════════════════════════════════════════

    function test_StalePriceRejected() public {
        _registerNodeAndAttest(NODE_ID, 1000, 9950);
        vault.updateAttestation(NODE_ID, 1000, 9950, 2500, true);

        // Update price to initialize lastPriceUpdate
        vault.updateGoldPrice(15_300_000); // $153/gram

        uint256 borrowAmount = 50_000e6;
        vm.prank(borrower);
        vault.lockAndBorrow(NODE_ID, borrowAmount, 30);

        // Advance past 24 hours (price becomes stale)
        vm.warp(block.timestamp + 24 hours + 1);

        // Liquidation should fail due to stale price
        vm.expectRevert("Price feed stale");
        vault.liquidate(NODE_ID);

        // Update price to make it fresh again
        vault.updateGoldPrice(15_300_000);

        // Now liquidation should work (assuming other trigger exists)
        // Advance past loan term to trigger expiry
        vm.warp(block.timestamp + 35 days);
        // Price is stale again after 35-day warp, refresh it
        vault.updateGoldPrice(15_300_000);
        vault.liquidate(NODE_ID);

        (,,,,, bool isActive) = vault.loans(NODE_ID);
        assertFalse(isActive);
    }

    function test_BorrowRejectedWithStalePrice() public {
        _registerNodeAndAttest(NODE_ID, 1000, 9950);
        vault.updateAttestation(NODE_ID, 1000, 9950, 2500, true);

        // Set a price and then make it stale
        vault.updateGoldPrice(15_300_000);

        // Advance past 24 hours to make price stale
        vm.warp(block.timestamp + 24 hours + 1);

        // Refresh attestation so it doesn't hit StaleAttestation first
        vault.updateAttestation(NODE_ID, 1000, 9950, 2500, true);

        // Borrow attempt should fail due to stale price
        vm.expectRevert("Price feed stale");
        vm.prank(borrower);
        vault.lockAndBorrow(NODE_ID, 50_000e6, 30);
    }

    // ════════════════════════════════════════════════════════════
    // TEST 14: ETH + SOV Mixed Bond
    // ════════════════════════════════════════════════════════════

    function test_MixedEthSovBond() public {
        uint256 ethDeposit = 1 ether;
        uint256 sovDeposit = 1000e18;

        vm.deal(guardian1, 2 ether);
        vm.startPrank(guardian1);
        sov.approve(address(guardianBond), sovDeposit);
        guardianBond.depositBond{value: ethDeposit}(sovDeposit);
        vm.stopPrank();

        (uint256 eth, uint256 sovAmt, bool active,) = guardianBond.getBond(guardian1);
        assertEq(eth, ethDeposit);
        assertEq(sovAmt, sovDeposit);
        assertTrue(active);
        assertEq(guardianBond.totalBondedEth(), ethDeposit);
        assertEq(guardianBond.totalBondedSov(), sovDeposit);
    }

    // ════════════════════════════════════════════════════════════
    // HELPERS
    // ════════════════════════════════════════════════════════════

    // ════════════════════════════════════════════════════════════
    // TEST 15: isProcessed() returns correct result
    // ════════════════════════════════════════════════════════════

    function test_IsProcessedMatchesConfirmAndMint() public {
        sovereignNode.registerNode(NODE_ID, tpmAddress, 1, 5536100, -197000);

        bytes32 specHash = keccak256("xrf-spectrum-check");
        bytes memory sig = _signAttestation(
            NODE_ID, 500, 9950, 2388, 2500, true, 5536100, -197000, specHash
        );

        sovereignNode.submitAttestation(
            NODE_ID, 500, 9950, 2388, 2500, true,
            5536100, -197000, 50, specHash, sig
        );

        // Before minting, isProcessed should return false
        uint64 ts = uint64(block.timestamp);
        assertFalse(bridge.isProcessed(specHash, ts, NODE_ID));

        // Mint
        vm.prank(relayer);
        bridge.confirmAndMint(NODE_ID, 0, recipient);

        // After minting, isProcessed should return true
        assertTrue(bridge.isProcessed(specHash, ts, NODE_ID));
    }

    // ════════════════════════════════════════════════════════════
    // HELPERS
    // ════════════════════════════════════════════════════════════

    function _registerNodeAndAttest(bytes32 _nodeId, uint256 _massGrams, uint256 _purityBps) internal {
        // Register if not already active
        if (!sovereignNode.isNodeActive(_nodeId)) {
            sovereignNode.registerNode(_nodeId, tpmAddress, 1, 5536100, -197000);
        }

        uint256 karatE2 = (_purityBps * 24 * 100) / 10000;
        bytes32 specHash = keccak256("xrf-spectrum");
        bytes memory sig = _signAttestation(
            _nodeId, _massGrams, _purityBps, karatE2, 2500, true, 5536100, -197000, specHash
        );

        sovereignNode.submitAttestation(
            _nodeId,
            _massGrams,
            _purityBps,
            karatE2,
            2500,        // tempCE2
            true,        // sealIntact
            5536100,     // gpsLatE6
            -197000,     // gpsLonE6
            50,          // gpsAccuracyDm
            specHash,
            sig
        );
    }
}
