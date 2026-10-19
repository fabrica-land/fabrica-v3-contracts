ARG FOUNDRY_VERSION=1.7.1
FROM ghcr.io/foundry-rs/foundry:v${FOUNDRY_VERSION}

# Build and test a fresh checkout, including its Foundry dependencies.
RUN git clone --recurse-submodules https://github.com/fabrica-land/fabrica-v3-contracts.git /tmp/src
WORKDIR /tmp/src
RUN forge build
RUN forge test
