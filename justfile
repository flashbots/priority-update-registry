default: ci

fmt-check:
    forge fmt --check

fmt:
    forge fmt

build:
    forge build --sizes

test:
    forge test -vvv

slither-install:
    python3 -m venv .slither-venv
    .slither-venv/bin/pip install --quiet slither-analyzer

slither:
    .slither-venv/bin/slither . --filter-paths lib/

ci: fmt-check build test slither

initcode-hash AGE LEAD:
    #!/usr/bin/env bash
    set -euo pipefail
    forge build --quiet
    bytecode=$(jq -r '.bytecode.object' out/PrioUpdateRegistry.sol/PrioUpdateRegistry.json)
    ctor=$(cast abi-encode "constructor(uint256,uint256)" {{AGE}} {{LEAD}})
    hash=$(cast keccak "${bytecode}${ctor#0x}")
    echo "factory:       0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7"
    echo "initcode hash: $hash"

deploy SALT AGE LEAD *ARGS:
    forge script script/Deploy.s.sol \
      --sig "run(bytes32,uint256,uint256)" {{SALT}} {{AGE}} {{LEAD}} \
      --broadcast {{ARGS}}
