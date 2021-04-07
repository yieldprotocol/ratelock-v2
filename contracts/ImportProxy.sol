// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.10;

import "./interfaces/IFlashMinter.sol";
import "./helpers/DecimalMath.sol";
import "./helpers/SafeCast.sol";
import "./helpers/YieldAuth.sol";
import "./ImportProxyBase.sol";


interface IImportProxy {
    function importFromProxy(IPool, address, uint256, uint256, uint256) external;
    function hope(address) external;
    function nope(address) external;
}

contract ImportProxy is ImportProxyBase, DecimalMath, IFlashMinter {
    using SafeCast for uint256;
    using YieldAuth for IController;

    IImportProxy public immutable importProxy;

    constructor(IController controller_, IPool[] memory pools_, IProxyRegistry proxyRegistry_)
        public
        ImportProxyBase(controller_, pools_, proxyRegistry_)
    {
        importProxy = IImportProxy(address(this)); // This contract has two functions, as itself, and delegatecalled by a dsproxy.
    }

    /// --------------------------------------------------
    /// ImportProxy via dsproxy: Fork and Split
    /// --------------------------------------------------

    /// @dev Fork part of a user MakerDAO vault to ImportProxy, and call importProxy to transform it into a Yield vault
    /// This function can be called from a dsproxy that already has a `vat.hope` on the user's MakerDAO Vault
    /// @param pool fyDai Pool to use for migration, determining maturity of the Yield Vault
    /// @param user User vault to import
    /// @param wethAmount Weth collateral to import
    /// @param debtAmount Normalized debt to move ndai * rate = dai
    /// @param maxDaiPrice Maximum fyDai price to pay for Dai
    function importPosition(IPool pool, address user, uint256 wethAmount, uint256 debtAmount, uint256 maxDaiPrice) public {
        require(user == msg.sender || proxyRegistry.proxies(user) == msg.sender, "Restricted to user or its dsproxy"); // Redundant?
        importProxy.hope(msg.sender);                     // Allow the user or proxy to give importProxy the MakerDAO vault.
        vat.fork(                                      // Take the treasury vault
            WETH,
            user,
            address(importProxy),
            wethAmount.toInt256(),
            debtAmount.toInt256()
        );
        importProxy.nope(msg.sender);                     // Disallow the user or proxy to give importProxy the MakerDAO vault.
        importProxy.importFromProxy(pool, user, wethAmount, debtAmount, maxDaiPrice);
    }

    /// @dev Fork a user MakerDAO vault to ImportProxy, and call importProxy to transform it into a Yield vault
    /// This function can be called from a dsproxy that already has a `vat.hope` on the user's MakerDAO Vault
    /// @param pool fyDai Pool to use for migration, determining maturity of the Yield Vault
    /// @param user CDP Vault to import
    /// @param maxDaiPrice Maximum fyDai price to pay for Dai
    function importVault(IPool pool, address user, uint256 maxDaiPrice) public {
        (uint256 ink, uint256 art) = vat.urns(WETH, user);
        importPosition(pool, user, ink, art, maxDaiPrice);
    }

    /// --------------------------------------------------
    /// ImportProxy as itself: Maker to Yield proxy
    /// --------------------------------------------------

    // ImportProxy accepts to take the user vault. Callable only by the user or its dsproxy
    // Anyone can call this to donate a collateralized vault to ImportProxy.
    function hope(address user) public {
        require(user == msg.sender || proxyRegistry.proxies(user) == msg.sender, "Restricted to user or its dsproxy");
        vat.hope(msg.sender);
    }

    // ImportProxy doesn't accept to take the user vault. Callable only by the user or its dsproxy
    function nope(address user) public {
        require(user == msg.sender || proxyRegistry.proxies(user) == msg.sender, "Restricted to user or its dsproxy");
        vat.nope(msg.sender);
    }

    /// @dev Transfer debt and collateral from MakerDAO (this contract's CDP) to Yield (user's CDP)
    /// Needs controller.addDelegate(importProxy.address, { from: user });
    /// @param pool The pool to trade in (and therefore fyDai series to borrow)
    /// @param user The user to receive the debt and collateral in Yield
    /// @param wethAmount weth to move from MakerDAO to Yield. Needs to be high enough to collateralize the dai debt in Yield,
    /// and low enough to make sure that debt left in MakerDAO is also collateralized.
    /// @param debtAmount Normalized dai debt to move from MakerDAO to Yield. ndai * rate = dai
    /// @param maxDaiPrice Maximum fyDai price to pay for Dai
    function importFromProxy(IPool pool, address user, uint256 wethAmount, uint256 debtAmount, uint256 maxDaiPrice) public {
        require(knownPools[address(pool)], "ImportProxy: Only known pools");
        require(user == msg.sender || proxyRegistry.proxies(user) == msg.sender, "Restricted to user or its dsproxy");
        // The user specifies the fyDai he wants to mint to cover his maker debt, the weth to be passed on as collateral, and the dai debt to move
        (uint256 ink, uint256 art) = vat.urns(WETH, address(this));
        require(
            debtAmount <= art,
            "ImportProxy: Not enough debt in Maker"
        );
        require(
            wethAmount <= ink,
            "ImportProxy: Not enough collateral in Maker"
        );
        (, uint256 rate,,,) = vat.ilks(WETH);
        uint256 daiNeeded = muld(debtAmount, rate);
        uint256 fyDaiAmount = pool.buyDaiPreview(daiNeeded.toUint128());
        require(
            fyDaiAmount <= muld(daiNeeded, maxDaiPrice),
            "ImportProxy: Maximum Dai price exceeded"
        );

        // Flash mint the fyDai
        IFYDai fyDai = pool.fyDai();
        fyDai.flashMint(
            fyDaiAmount,
            abi.encode(pool, user, wethAmount, debtAmount)
        );

        emit ImportedFromMaker(pool.fyDai().maturity(), user, user, wethAmount, daiNeeded);
    }

    /// @dev Callback from `FYDai.flashMint()`
    function executeOnFlashMint(uint256, bytes calldata data) external override {
        (IPool pool, address user, uint256 wethAmount, uint256 debtAmount) = 
            abi.decode(data, (IPool, address, uint256, uint256));
        require(knownPools[address(pool)], "ImportProxy: Only known pools");
        require(msg.sender == address(IPool(pool).fyDai()), "ImportProxy: Callback restricted to the fyDai matching the pool");

        _importFromProxy(pool, user, wethAmount, debtAmount);
    }

    /// @dev Internal function to transfer debt and collateral from MakerDAO to Yield
    /// @param pool The pool to trade in (and therefore fyDai series to borrow)
    /// @param user Vault to import.
    /// @param wethAmount weth to move from MakerDAO to Yield. Needs to be high enough to collateralize the dai debt in Yield,
    /// and low enough to make sure that debt left in MakerDAO is also collateralized.
    /// @param debtAmount dai debt to move from MakerDAO to Yield. Denominated in Dai (= art * rate)
    /// Needs vat.hope(importProxy.address, { from: user });
    /// Needs controller.addDelegate(importProxy.address, { from: user });
    function _importFromProxy(IPool pool, address user, uint256 wethAmount, uint256 debtAmount) internal {
        IFYDai fyDai = IFYDai(pool.fyDai());

        // Pool should take exactly all fyDai flash minted. ImportProxy will hold the dai temporarily
        (, uint256 rate,,,) = vat.ilks(WETH);
        uint256 fyDaiSold = pool.buyDai(address(this), address(this), muldrup(debtAmount, rate).toUint128());

        daiJoin.join(address(this), dai.balanceOf(address(this)));      // Put the Dai in Maker
        vat.frob(                           // Pay the debt and unlock collateral in Maker
            WETH,
            address(this),
            address(this),
            address(this),
            -wethAmount.toInt256(),               // Removing Weth collateral
            -debtAmount.toInt256()  // Removing Dai debt
        );

        wethJoin.exit(address(this), wethAmount);                       // Hold the weth in ImportProxy
        controller.post(WETH, address(this), user, wethAmount);         // Add the collateral to Yield
        controller.borrow(WETH, fyDai.maturity(), user, address(this), fyDaiSold); // Borrow the fyDai
    }

    /// --------------------------------------------------
    /// Signature method wrappers
    /// --------------------------------------------------
    
    /// @dev Determine whether all approvals and signatures are in place for `importPosition`.
    /// If `return[0]` is `false`, calling `vat.hope(proxy.address)` will set the MakerDAO approval.
    /// If `return[1]` is `false`, `importFromProxyWithSignature` must be called with a controller signature.
    /// If `return` is `(true, true)`, `importFromProxy` won't fail because of missing approvals or signatures.
    function importPositionCheck() public view returns (bool, bool) {
        bool approvals = vat.can(msg.sender, address(this)) == 1;
        bool controllerSig = controller.delegated(msg.sender, address(importProxy));
        return (approvals, controllerSig);
    }

    /// @dev Transfer debt and collateral from MakerDAO to Yield
    /// Needs vat.hope(importProxy.address, { from: user });
    /// @param pool The pool to trade in (and therefore fyDai series to borrow)
    /// @param user The user migrating a vault
    /// @param wethAmount weth to move from MakerDAO to Yield. Needs to be high enough to collateralize the dai debt in Yield,
    /// and low enough to make sure that debt left in MakerDAO is also collateralized.
    /// @param debtAmount dai debt to move from MakerDAO to Yield. Denominated in Dai (= art * rate)
    /// @param maxDaiPrice Maximum fyDai price to pay for Dai
    /// @param controllerSig packed signature for delegation of ImportProxy (not dsproxy) in the controller. Ignored if '0x'.
    function importPositionWithSignature(IPool pool, address user, uint256 wethAmount, uint256 debtAmount, uint256 maxDaiPrice, bytes memory controllerSig) public {
        if (controllerSig.length > 0) controller.addDelegatePacked(user, address(importProxy), controllerSig);
        return importPosition(pool, user, wethAmount, debtAmount, maxDaiPrice);
    }

    /// @dev Transfer a whole Vault from MakerDAO to Yield
    /// Needs vat.hope(importProxy.address, { from: user });
    /// @param pool The pool to trade in (and therefore fyDai series to borrow)
    /// @param user The user migrating a vault
    /// @param maxDaiPrice Maximum fyDai price to pay for Dai
    /// @param controllerSig packed signature for delegation of ImportProxy (not dsproxy) in the controller. Ignored if '0x'.
    function importVaultWithSignature(IPool pool, address user, uint256 maxDaiPrice, bytes memory controllerSig) public {
        if (controllerSig.length > 0) controller.addDelegatePacked(user, address(importProxy), controllerSig);
        return importVault(pool, user, maxDaiPrice);
    }
}
