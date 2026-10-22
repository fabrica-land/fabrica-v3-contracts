# ENG-5167: nightly, not a stable release. No stable Foundry drops emSign ECC Root CA - G3 from its binaries
# (webpki-roots < 1.0.10) or its image CA store. Digest = linux/amd64 manifest of nightly-9089a6bf (2026-10-21).
# Keep in sync with `version:` in .github/workflows/test.yml.
ARG FOUNDRY_VERSION=nightly-9089a6bfdca158b2ef268b3d60923bf1e0879fed
FROM --platform=linux/amd64 ghcr.io/foundry-rs/foundry:${FOUNDRY_VERSION}@sha256:3e49d6742cf38501736cbee46f5549836396a5e73112b9f7638fbdf5d97c9f0d

# SHA-256: https://github.com/argotorg/solc-bin/blob/gh-pages/linux-amd64/list.json
ADD --chmod=0755 --checksum=sha256:fa8ac9a32d301ad023a36ee5a29f8e291fe3200c60244e43c142539e82a617f4 https://raw.githubusercontent.com/argotorg/solc-bin/gh-pages/linux-amd64/solc-linux-amd64-v0.8.35+commit.47b9dedd /usr/local/bin/solc
ENV FOUNDRY_OFFLINE=true

# Build and test a fresh checkout, including its Foundry dependencies.
RUN git clone --recurse-submodules https://github.com/fabrica-land/fabrica-v3-contracts.git /tmp/src
WORKDIR /tmp/src
RUN forge build --use /usr/local/bin/solc
RUN forge test --use /usr/local/bin/solc
