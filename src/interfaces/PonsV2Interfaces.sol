// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * Minimal interfaces for the deployed Pons V2 contracts on Robinhood Chain (chainId 4663), plus the
 * GLD beacon's compliance surface. Hand-written from the verified sources in reference/pons and
 * checked against reference/pons/factory_abi.json. Shared by the fork tests and the scripts.
 *
 * NOTE: the deployed TokenParams has a trailing `bytes32 salt` (CREATE2 salt, namespaced per
 * deployer) that the research brief's original field list omitted: eleven fields in total.
 */

struct PonsSocials {
    string twitter;
    string telegram;
    string discord;
    string website;
    string farcaster;
}

struct PonsTokenParams {
    string name;
    string symbol;
    string logo;
    string description;
    PonsSocials socials;
    address creatorFeeRecipient;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    bytes32 expectedEconomics; // 0 waives the economics pin
    bytes32 salt;
}

/// @dev PonsV2MemeHook.currentFeePolicy() / the policy snapshot frozen into every launch.
struct PonsFeePolicySnapshot {
    address protocolFeeRecipient;
    uint16 protocolFeeShareBps;
    uint16 buybackBurnBps;
    uint16 hookFeeBps;
    uint16 maxInternalPriceImpactBps;
}

/// @dev PonsV2LaunchDeployer.LaunchDeployment; contract-typed fields are plain addresses here (same ABI).
struct PonsLaunchDeployment {
    address pairToken;
    address creatorFeeRecipient;
    address originalDeployer;
    address feePolicy; // the meme hook
    PonsFeePolicySnapshot policy;
    address feeEscrow;
    address buybackVault;
    uint256 phantomQuote;
    uint256 curveFeeBps;
    uint256 creatorTaxBps;
    bool buybackEnabled;
    uint256 graduationThreshold;
    uint256 supply;
    bytes32 salt;
    string name;
    string symbol;
    string logo;
    string description;
    PonsSocials socials;
}

interface IPonsV2LaunchAndBuy {
    function launchAndBuy(
        PonsTokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        uint256 quoteIn,
        uint256 minTokensOut,
        address recipient,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve, uint256 tokensOut);

    function factory() external view returns (address);
}

interface IPonsV2LaunchFactory {
    enum GraduationPhase {
        NotGraduated,
        Swept,
        PoolCreated,
        Rescued
    }

    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        GraduationPhase phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    struct LaunchConfig {
        uint256 supply;
        uint256 curveFeeBps;
        uint256 phantomQuote;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        bool enabled;
    }

    error CreatorTaxTooHigh();
    error LaunchEconomicsMismatch(bytes32 expected, bytes32 actual);
    error WrongGraduationPhase();

    event TokenLaunched(
        address indexed token,
        address indexed curve,
        address indexed deployer,
        address pairToken,
        uint256 launchConfigId,
        uint256 graduationThreshold
    );
    event LaunchSwept(address indexed token, uint256 quoteOut, uint256 tokenOut);
    event PoolGraduated(address indexed token, uint256 positionId, uint256 tokenAmount, uint256 pairTokenAmount);

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory);
    function launchConfigCount() external view returns (uint256);
    function pairTokenEconomics(address pairToken)
        external
        view
        returns (uint256 phantomQuote, uint256 graduationThreshold, uint8 decimals);
    function approvedPairTokens(address pairToken) external view returns (bool);
    function launchFee() external view returns (uint256);
    function maxCreatorTaxBps() external view returns (uint256);
    function launchEnabled() external view returns (bool);
    function canLaunch(address launcher) external view returns (bool);
    function snipeTaxStartBps() external view returns (uint256);
    function snipeTaxSeconds() external view returns (uint256);
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
    /// @notice Pure fair launch (no opening buy): creates the token + curve, no dev bag. Native = msg.value == launchFee.
    function launchToken(PonsTokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);
    function createGraduatedPool(address token) external returns (uint256 positionId);
    function graduate(address token) external;
    function locker() external view returns (address);
    function memeHook() external view returns (address);
    function feeEscrow() external view returns (address);
    function buybackVault() external view returns (address);
    function launchDeployer() external view returns (address);
    function launchForwarder() external view returns (address);
    function owner() external view returns (address);
}

interface IPonsV2LaunchDeployer {
    function predictLaunchAddresses(PonsLaunchDeployment calldata params)
        external
        view
        returns (address token, address curve);
}

interface IPonsV2BondingCurve {
    error CurveGraduated();

    event CurveBuy(
        address indexed buyer,
        address indexed recipient,
        uint256 quoteIn,
        uint256 tokensOut,
        uint256 fee,
        uint256 tax
    );

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient)
        external
        payable
        returns (uint256 tokensOut);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 quoteOut);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);
    function realQuoteReserve() external view returns (uint256);
    function currentSnipeTaxBps(address recipient) external view returns (uint256);
    function readyToGraduate() external view returns (bool);
    function graduated() external view returns (bool);
    function sellableTokens() external view returns (uint256);
    function reservedTokens() external view returns (uint256);
    function phantomQuote() external view returns (uint256);
    function graduationThreshold() external view returns (uint256);
    function feeBps() external view returns (uint256);
    function creatorTaxBps() external view returns (uint256);
    function trackedQuote() external view returns (uint256);
    function trackedTokens() external view returns (uint256);
    function snipeTaxExempt(address account) external view returns (bool);
    function launchedAt() external view returns (uint256);
    function token() external view returns (address);
    function pairToken() external view returns (address);
}

interface IPonsV2MemeHook {
    error NotFeeSweepOperator();
    error InternalSwapRequiresOperator();

    event HookFeeCollected(bytes32 indexed poolId, address currency, uint256 feeAmount, uint256 taxAmount);
    event PoolFeesSwept(
        bytes32 indexed poolId,
        uint256 protocolAmount,
        uint256 buybackAmount,
        uint256 creatorAmount,
        uint256 tokensLocked
    );

    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
    function feeSweepOperator() external view returns (address);
    function protocolFeeRecipient() external view returns (address);
    function hookFeeBps() external view returns (uint256);
    function protocolFeeShareBps() external view returns (uint256);
    function maxInternalPriceImpactBps() external view returns (uint256);
    function currentFeePolicy() external view returns (PonsFeePolicySnapshot memory);
    function pendingFees(bytes32 poolId, address currency) external view returns (uint256);
    function pendingCreatorTax(bytes32 poolId, address currency) external view returns (uint256);
    function pendingBuyback(bytes32 poolId, address currency) external view returns (uint256);
    function launches(bytes32 poolId)
        external
        view
        returns (
            bool registered,
            bool memecoinIsCurrency0,
            address memecoin,
            address quoteToken,
            address creator,
            address buybackCreatorRecipient,
            address protocolFeeRecipient,
            uint16 creatorTaxBps,
            uint16 protocolFeeShareBps,
            uint16 buybackBurnBps,
            uint16 hookFeeBps,
            uint16 maxInternalPriceImpactBps,
            bool buybackEnabled
        );
}

interface IPonsV2FeeEscrow {
    event CreditedToken(address indexed recipient, address indexed token, address indexed depositor, uint256 amount);
    event ClaimedToken(address indexed recipient, address indexed token, uint256 amount);

    function balanceOfToken(address recipient, address token) external view returns (uint256);
    function claimToken(address token) external returns (uint256 amount);
    function claimToken(address token, uint256 amount) external returns (uint256);
}

interface IPonsV2LaunchLocker {
    function lockedPositions(address token) external view returns (uint256);
    function lockedTokenSupply(address token) external view returns (uint256);
    function isLocked(address token) external view returns (bool);
    function positionManager() external view returns (address);
}

interface IERC721Min {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @dev The GLD beacon (0xe10b6f6B275de231345c20D14Ab812db62151b00): an UpgradeableBeacon with
 *      AccessControl, Pausable and a per-account blocklist that every GLD transfer consults
 *      (`paused()`, `isBlocked(from)`, `isBlocked(to)`). Selectors recovered from the deployed
 *      bytecode; `blockAccounts` is gated by BLOCKER_ROLE = keccak256("BLOCKER_ROLE").
 */
interface IGldBeacon {
    function implementation() external view returns (address);
    function paused() external view returns (bool);
    function isBlocked(address account) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function blockAccounts(address[] calldata accounts) external;
    function unblockAccounts(address[] calldata accounts) external;
    function pause() external;
    function unpause() external;
}
