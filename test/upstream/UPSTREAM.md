# Upstream pin

`IRelayEntrypoint.sol` in this directory is a byte-for-byte copy of

- repository: https://github.com/dromos-labs/metadex-public
- path: `V3/src/interfaces/relay/IRelayEntrypoint.sol`
- commit: `b032bb7f55eff31e081196754e0fdbc217f978d2`
- version: `1.0.0-provisional.3` (per upstream `VERSIONS`)
- license: MIT (SPDX header in the file)
- sha256: `d10e57499d9c91795eac315333e39998fcfb9e609b8f52831c49cdc25aeb841c`

It exists only so `test/Selectors.t.sol` can prove the interface re-declared in
`src/interfaces/IRelayEntrypoint.sol` matches upstream selector-for-selector. It is never imported by
`src/`.

To re-check the copy against upstream:

```sh
git -C <metadex-public> show b032bb7f55eff31e081196754e0fdbc217f978d2:V3/src/interfaces/relay/IRelayEntrypoint.sol | sha256sum
sha256sum test/upstream/IRelayEntrypoint.sol
```
