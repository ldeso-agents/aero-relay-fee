# aero-relay-fee

A single-purpose Relay entrypoint for [metadex](https://github.com/dromos-labs/metadex-public) Relays:
`RelayFeeSkim` takes a fixed basis-point cut of a Relay's idle token balance and forwards it to a
fixed sink. It is installed as the Relay's `converter`, holds no storage and no owner, and depends on
nothing at runtime.

MIT. Foundry. Zero runtime dependencies (`forge-std` is test-only).

## How it works

```
skim(relay, token)                              caller must hold KEEPER on the Relay
  idle = balanceOf(relay) - accountedBalance(token)
  fee  = idle * FEE_BPS / 10_000                  rounds down; reverts if zero
  relay.pull(token, fee)                          authorized by the CONVERTER role
  token.transfer(FEE_SINK, balanceOf(this))       tolerates no-return-data tokens
  emit Skimmed(relay, token, idle, fee, forwarded)
```

- **Fee base.** `balanceOf - accountedBalance` is exactly the bound the Relay enforces on `pull`
  (`RelayRewardsLib.pull`), so a skim can never move rewards already notified to holders. An
  accounted balance above the token balance counts as zero idle rather than panicking.
- **Keeper gate.** Same gate as every upstream entrypoint (`BaseEntrypoint._requireKeeper`): the
  keeper decides when the skim runs, so the intended sequence is skim first, then run the official
  Compounder on what is left. The contract is stateless, so a repeat call skims `FEE_BPS` of the
  remainder again; only the keeper can trigger that.
- **Immutables.** `FEE_BPS` (1 to `MAX_FEE_BPS` = 1000, i.e. 10%) and `FEE_SINK` are fixed at
  construction and cannot be changed.
- **Least privilege.** The contract is seated with CONVERTER, which authorizes `pull` and
  `notifyReward`. It never calls `notifyReward`.
- **Nothing stranded.** The whole token balance the contract holds is forwarded on each skim, so
  tokens sent here by mistake end up at the sink.

## Layout

```
src/RelayFeeSkim.sol                  the contract
src/interfaces/IRelayEntrypoint.sol   4 members re-declared from upstream (MIT)
src/interfaces/IERC20Minimal.sol      balanceOf + transfer
test/RelayFeeSkim.t.sol               unit + fuzz tests against a mock Relay
test/Selectors.t.sol                  pins the 4 upstream selectors
test/mocks/MockRelay.sol              mirrors RelayBase.pull semantics (role gate, idle bound)
test/upstream/IRelayEntrypoint.sol    byte-identical upstream copy, see test/upstream/UPSTREAM.md
script/Deploy.s.sol                   CREATE2 deploy with a fixed salt
```

### Upstream pin

The interface is re-declared from `V3/src/interfaces/relay/IRelayEntrypoint.sol` at
dromos-labs/metadex-public commit `b032bb7f55eff31e081196754e0fdbc217f978d2`
(`1.0.0-provisional.3`). `test/Selectors.t.sol` asserts the four selectors against both hardcoded
literals and the vendored upstream file, and CI checks the vendored file's sha256. The mock Relay
mirrors `RelayBase.pull` and `RelayRewardsLib.pull` from the same commit.

| member | selector |
| --- | --- |
| `pull(address,uint256)` | `0xf2d5d56b` |
| `accountedBalance(address)` | `0xa7838c8a` |
| `KEEPER()` | `0x862a179e` |
| `hasAnyRole(address,uint256)` | `0x514e62fc` |

Upstream is still provisional. Re-check the pin (and the `pull` semantics) against their final code
before deploying.

## Build and test

```sh
git submodule update --init   # or: forge install foundry-rs/forge-std@v1.16.2
forge build
forge test
FOUNDRY_PROFILE=ci forge test   # 5000 fuzz runs
forge fmt --check
```

## Deploy

The script deploys through the canonical CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`)
with the fixed salt `keccak256("aero-relay-fee/RelayFeeSkim/v1")`, asserts the deployed address
equals the predicted one, and is a no-op if that address already has code. The address depends on
the constructor arguments, so a different fee or sink lands on a different address.

```sh
cp .env.example .env            # fill FEE_BPS, FEE_SINK, BASE_RPC_URL, BASESCAN_API_KEY
set -a; . ./.env; set +a

# predict
forge script script/Deploy.s.sol --sig 'predict(uint256,address)' "$FEE_BPS" "$FEE_SINK"

# dry run
forge script script/Deploy.s.sol --rpc-url base

# deploy (pick your signer: --ledger, --account <name>, or --private-key)
forge script script/Deploy.s.sol --rpc-url base --broadcast --ledger
```

### Verify

Constructor args are ABI-encoded `(uint256 feeBps, address feeSink)`. The build sets
`bytecode_hash = "ipfs"` so both verifiers match the deployed metadata.

```sh
ARGS=$(cast abi-encode 'constructor(uint256,address)' "$FEE_BPS" "$FEE_SINK")

# Basescan (Etherscan v2 API)
forge verify-contract <ADDRESS> src/RelayFeeSkim.sol:RelayFeeSkim \
  --chain base --verifier etherscan --etherscan-api-key "$BASESCAN_API_KEY" \
  --constructor-args "$ARGS" --watch

# Sourcify
forge verify-contract <ADDRESS> src/RelayFeeSkim.sol:RelayFeeSkim \
  --chain base --verifier sourcify --constructor-args "$ARGS" --watch
```

## Hand-off to Aero

The Relay is created by Aero through `RelayFactory.createMaxiRelay(CreateParams)`
(`V3/src/relay/RelayFactory.sol`, gated on `RELAY_DEPLOYER_ROLE`). The relevant fields of
`IRelayFactory.CreateParams`:

| field | value |
| --- | --- |
| `admin` | your multisig (Relay owner: grants and revokes every role) |
| `keeper` | Aero's keeper (the only account that can call `skim`) |
| `compounder` | Aero's official Compounder, unchanged |
| `converter` | the `RelayFeeSkim` address from the deploy above |

The Relay grants `converter` the CONVERTER role at initialization (`RelayBase.initialize`), which is
what lets `RelayFeeSkim` call `pull`. Deploy and hand over the address only after Aero's final
code lands: the upstream repo is still provisional and the address is bound to this bytecode.

Keeper sequence per reward token: `RelayFeeSkim.skim(relay, token)`, then the Compounder's
`swapAndCompound` / `compoundIdleBalance` on the rest.
