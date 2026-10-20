ARG FOUNDRY_VERSION=1.5.1
FROM --platform=linux/amd64 ghcr.io/foundry-rs/foundry:v${FOUNDRY_VERSION}

# SHA-256: https://github.com/argotorg/solc-bin/blob/gh-pages/linux-amd64/list.json
ADD --chmod=0755 --checksum=sha256:fa8ac9a32d301ad023a36ee5a29f8e291fe3200c60244e43c142539e82a617f4 https://raw.githubusercontent.com/argotorg/solc-bin/gh-pages/linux-amd64/solc-linux-amd64-v0.8.35+commit.47b9dedd /usr/local/bin/solc
ENV FOUNDRY_OFFLINE=true

# Build and test a fresh checkout, including its Foundry dependencies.
RUN git clone --recurse-submodules https://github.com/fabrica-land/fabrica-v3-contracts.git /tmp/src
WORKDIR /tmp/src
RUN forge build --use /usr/local/bin/solc
RUN forge test --use /usr/local/bin/solc
