// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;
import "@yield-protocol/vault-interfaces/IFYToken.sol";
import "@yield-protocol/vault-interfaces/IJoin.sol";
import "@yield-protocol/vault-interfaces/ICauldron.sol";
import "@yield-protocol/vault-interfaces/DataTypes.sol";
import "@yield-protocol/yieldspace-interfaces/IPool.sol";
import "dss-interfaces/src/dss/DaiJoinAbstract.sol";
import "dss-interfaces/src/dss/GemJoinAbstract.sol";
import "./helpers/AccessControl.sol";


library RMath { // Fixed point arithmetic in RAY (27) decimal units
    /// @dev Multiply an amount by a fixed point factor with 27 decimals, returning an amount
    function rmul(uint128 x, uint128 y) internal pure returns (uint128 z) {
        unchecked {
            uint256 _z = uint256(x) * uint256(y) / 1e27;
            require (_z <= type(uint128).max, "RMUL Overflow");
            z = uint128(_z);
        }
    }
}

library Safe128 {
    /// @dev Safely cast an uint128 to an int128
    function i128(uint128 x) internal pure returns (int128 y) {
        require (x <= uint128(type(int128).max), "Cast overflow");
        y = int128(x);
    }
}

contract ImportCdpProxy is AccessControl() {
    using RMath for uint128;
    using Safe128 for uint128;

    enum Operation {
        BUILD,               // 0
        GIVE,                // 1
        IMPORT               // 2
    }

    ICauldron public cauldron;
    CdpMgr cdpMgr = CdpMgr('0x123456789');
    IJoin yieldDaiJoin = IJoin('0x123456789');
    DaiJoinAbstract makerDaiJoin = DaiJoinAbstract('0x123456789');
    ProxyRegistry proxyRegistry = ProxyRegistry('0x123456789');

    mapping (bytes6 => IJoin)                   public joins;            // Join contracts available to manage assets. The same Join can serve multiple assets (ETH-A, ETH-B, etc...)
    mapping (bytes6 => IPool)                   public pools;            // Pool contracts available to manage series. 12 bytes still free.

    mapping (bytes6 => GemJoinAbstract)         public makerJoins;       // Maker Join contracts for each Yield ilk
    mapping (bytes6 => bytes32)                 public makerIlks;        // Maker ilk identifiers for each Yield ilk

    event JoinAdded(bytes6 indexed assetId, address indexed join);
    event PoolAdded(bytes6 indexed seriesId, address indexed pool);

    constructor (ICauldron cauldron_) {
        cauldron = cauldron_;
    }

    // ---- Data sourcing ----

    /// @dev Obtains a series by seriesId from the Cauldron, and verifies that it exists
    function getSeries(bytes6 seriesId)
        internal view returns(DataTypes.Series memory series)
    {
        series = cauldron.series(seriesId);
        require (series.fyToken != IFYToken(address(0)), "Series not found");
    }

    /// @dev Obtains a join by assetId, and verifies that it exists
    function getJoin(bytes6 assetId)
        internal view returns(IJoin join)
    {
        join = joins[assetId];
        require (join != IJoin(address(0)), "Join not found");
    }

    /// @dev Obtains a pool by seriesId, and verifies that it exists
    function getPool(bytes6 seriesId)
        internal view returns(IPool pool)
    {
        pool = pools[seriesId];
        require (pool != IPool(address(0)), "Pool not found");
    }

    // ---- Administration ----

    /// @dev Add a new Join for an Asset, or replace an existing one for a new one.
    /// There can be only one Join per Asset. Until a Join is added, no tokens of that Asset can be posted or withdrawn.
    function addJoin(bytes6 assetId, IJoin join)
        external
        auth
    {
        address asset = cauldron.assets(assetId);
        require (asset != address(0), "Asset not found");
        require (join.asset() == asset, "Mismatched asset and join");
        joins[assetId] = join;
        emit JoinAdded(assetId, address(join));
    }

    /// @dev Add a new Pool for a Series, or replace an existing one for a new one.
    /// There can be only one Pool per Series. Until a Pool is added, it is not possible to borrow Base.
    function addPool(bytes6 seriesId, IPool pool)
        external
        auth
    {
        IFYToken fyToken = getSeries(seriesId).fyToken;
        require (fyToken == pool.fyToken(), "Mismatched pool fyToken and series");
        require (fyToken.asset() == address(pool.baseToken()), "Mismatched pool base and series");
        pools[seriesId] = pool;
        emit PoolAdded(seriesId, address(pool));
    }

    /// @dev Add a new maker ilk, by providing an ilk id and a gem join, related to a yield ilk id
    function addMakerIlk(bytes6 yieldIlkId, bytes32 makerIlkId, GemJoinAbstract makerJoin)
        external
        auth
    {
        // TODO: Does anything need to match?
        makerIlks[yieldIlkId] = makerIlkId;
        makerJoins[yieldIlkId] = makerJoin;
    }

    // ---- Vault management ----

    /// @dev Create a new vault, linked to a series (and therefore underlying) and a collateral
    function _build(bytes12 vaultId, bytes6 seriesId, bytes6 ilkId)
        private
        returns(DataTypes.Vault memory vault)
    {
        return cauldron.build(msg.sender, vaultId, seriesId, ilkId);
    }

    /// @dev Give a vault to another user.
    function _give(bytes12 vaultId, address receiver)
        private
        returns(DataTypes.Vault memory vault)
    {
        return cauldron.give(vaultId, receiver);
    }

    // ---- Batching ----

    /// @dev Submit a series of calls for execution.
    /// When a cdp is owned by a dsproxy, we might want to do a batch where a new vault is built,
    /// the cdp migrated, and the vault given to the dsproxy owner.
    function batch(
        bytes12 vaultId,
        Operation[] calldata operations,
        bytes[] calldata data
    ) external {
        require(operations.length == data.length, "Unmatched operation data");
        DataTypes.Vault memory vault;
        IFYToken fyToken;
        IPool pool;

        // Unless we are building the vault, we cache it
        if (operations[0] != Operation.BUILD) vault = getOwnedVault(vaultId);

        // Execute all operations in the batch. Conditionals ordered by expected frequency.
        for (uint256 i = 0; i < operations.length; i += 1) {
            Operation operation = operations[i];

            if (operation == Operation.BUILD) {
                (bytes6 seriesId, bytes6 ilkId) = abi.decode(data[i], (bytes6, bytes6));
                vault = _build(vaultId, seriesId, ilkId);   // Cache the vault that was just built
            
            } else if (operation == Operation.GIVE) {
                (address to) = abi.decode(data[i], (address));
                _give(vaultId, to);
                break;                                      // After giving the vault to someone we finish the batch, since the cahce is not valid anymore.
            
            } else if (operation == Operation.IMPORT) {
                (address to, int128 ink, int128 art) = abi.decode(data[i], (address, int128, int128));
                _importFromCdp(vaultId, vault, to, ink, art);
            }
        }
    }

    // ---- RateLock ----

    /// @dev Move `ink` collateral and `art` debt from Maker's `cdp` to Yield's `vaultId`.
    /// The resulting Yield debt will be no more than `max` in Dai terms.
    function importFromCdp(bytes12 vaultId, uint256 cdp, uint128 ink, uint128 art, uint128 max)
        external
        returns (DataTypes.Balances memory balances, uint128 yieldDebt)
    {
        DataTypes.Vault memory vault = cauldron.vaults(vaultId);

        require(
            vault.owner == msg.sender ||
            proxyRegistry.proxies(vault.owner) == msg.sender,
            "Only vault owner or its dsproxy"
        );
        
        return _importFromCdp(vaultId, vault, cdp, ink, art, max);
    }

    /// @dev Move `ink` collateral and `art` debt from Maker's `cdp` to Yield's `vault`.
    /// The resulting Yield debt will be no more than `max` in Dai terms.
    function _importFromCdp(bytes12 vaultId, DataTypes.Vault memory vault, uint256 cdp, uint128 ink, uint128 art, uint128 max)
        private
        returns (DataTypes.Balances memory balances, uint128 yieldDebt)
    {
        DataTypes.Series memory series = getSeries(vault.seriesId);
        IPool pool = getPool(vault.seriesId);
        IJoin yieldIlkJoin = getJoin(vault.ilkId);
        GemJoinAbstract makerIlkJoin = getMakerJoin(vault.ilkId);   // We register the maker join addresses for each on of our ilks
        
        // TODO: Check base is Dai
        // TODO: Check vault ilk and cdp ilk match

        // Find out how much will the yield debt be
        (, uint256 rate,,,) = vat.ilks(getMakerIlk(vault.ilkId));   // We register a table of yield to maker ilks
        uint128 daiAmount = art.rmul(rate);
        yieldDebt = pool.buyBaseTokenPreview(daiAmount);

        // Set the collateral and debt levels
        balances = cauldron.pour(vaultId, ink.i128(), yieldDebt.i128());

        // Get the dai from the Yield DaiJoin
        yieldDaiJoin.exit(address(this), daiAmount);

        // Pay user debt in MakerDAO
        dai.approve(address(makerDaiJoin), daiAmount);
        makerDaiJoin.join(cdpMgr.urns(cdp), daiAmount); // Put the Dai in Maker
        cdpMgr.frob(                                    // Pay the debt and unlock collateral in Maker
            cdp,
            -ink.toInt256(),                            // Removing collateral
            -art.toInt256()                             // Removing Dai debt
        );
        // Retrieve user collateral from MakerDAO
        cdpMgr.flux(cdp, address(this), ink);
        makerIlkJoin.exit(address(yieldIlkJoin), ink);

        // Add collateral to vault and mint fyTokens
        ilkJoin.join(address(yieldIlkJoin), ink);
        series.fyToken.mint(address(pool), yieldDebt);

        // Buy back the Dai and resolve the flash loan
        pool.buyBaseToken(address(yieldDaiJoin), daiAmount, max);
        yieldDaiJoin.join(address(yieldDaiJoin), art);
    }
}