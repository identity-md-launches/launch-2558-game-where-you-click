# Vendored dependencies

These are ordinary source files, not submodules. Builds and tests do not fetch
packages. Only the required portions of production libraries are retained; their
file contents are unmodified. Forge standard library source is retained for test
and protected-harness compatibility. No upstream tests or deployment artifacts are
needed from the other packages.

| Directory | Origin and version | Purpose | License |
| --- | --- | --- | --- |
| `lib/v4-core` | [`@uniswap/v4-core` 1.0.2](https://registry.npmjs.org/@uniswap/v4-core/-/v4-core-1.0.2.tgz) | Interfaces and internal libraries; real PoolManager for local integration tests | MIT and BUSL-1.1 per file; texts in `licenses/` |
| `lib/openzeppelin-contracts` | [`@openzeppelin/contracts` 5.2.0](https://registry.npmjs.org/@openzeppelin/contracts/-/contracts-5.2.0.tgz) | Ownable2Step, ReentrancyGuard, IERC20, test ERC20 | MIT, `LICENSE` |
| `lib/forge-std` | [`foundry-rs/forge-std` v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | Test assertions, cheatcode interfaces and invariant targets | MIT / Apache-2.0, license files |
| `lib/solmate` | `lib/solmate` sources bundled in the exact v4-core 1.0.2 archive above | `Owned`, used only by the local PoolManager fixture | AGPL-3.0-only per the bundled `Owned.sol` SPDX identifier; bundled `LICENSE` retained |

Archive SHA-256 digests, before extracting source:

```text
@uniswap/v4-core 1.0.2
f3db3af55f3d0c52f16abe96e7db12443f243bca1f334962373f95c57611de49

@openzeppelin/contracts 5.2.0
7a7f3060fc71bf080f88cd2f574d9e4813a2409de4dff1badfadc7dec13e9441

forge-std v1.9.7 (GitHub codeload tag archive)
45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94
```

The application uses v4 interfaces and internal helper libraries and OpenZeppelin
source. Some transitive v4 source files, including `Position.sol` imported by
`StateLibrary`, carry BUSL-1.1 notices; all upstream file notices are preserved.
The v4 PoolManager implementation and its Solmate owner base are test-only imports;
this application does not deploy or copy a new PoolManager on launch.

The OpenZeppelin npm archive omits the license text. Its `LICENSE` is included
separately from the matching
[v5.2.0 tag](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.2.0/LICENSE).
