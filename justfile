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
