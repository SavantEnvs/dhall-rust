# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for dhall-rust (Rust / cargo-fuzz). Builds ON TOP of the
# org C/C++ base (ghcr.io/savantenvs/base), adding a pinned Rust NIGHTLY (required
# for -Zsanitizer=address, the OSS-Fuzz Rust ASan path) under /opt/toolchains/rust,
# plus a pinned STABLE toolchain for the oracle build (upstream's own root
# `rust-toolchain` file pins "stable" — matching it makes mayhem/test.sh an honest
# rebuild of what upstream's CI actually runs, and avoids the "pinned nightly
# builds the fuzz targets fine but breaks dev-dependency compilation" trap).
#
# WHY a Rust-specific template (SPEC §6.2 items 8/9, §6.5):
#   The toolchains and cargo registry are NOT in the base. We install them at a
#   FIXED, $HOME-independent prefix (/opt/toolchains/rust) and pin CARGO_HOME /
#   RUSTUP_HOME there as ENV, so the cargo registry this FIRST (online) build
#   populates is found again by the PATCH tier's OFFLINE re-run (different $HOME).
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t dhall-rust-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (never an ENV — an empty ENV breaks clang). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH
# Undefaulted (no '=') so the base ENV default flows through unless --build-arg overrides it.
ARG SANITIZER_FLAGS

# ── Rust toolchains @ a FIXED, lockable, $HOME-independent prefix ──────────────
# nightly-2025-06-01 is fleet-proven good (nightly-2025-01-15 ICEs compiling `log`
# under -Zsanitizer=address — see docs/netnew-worker-prompt.md §6). It becomes the
# rustup DEFAULT so bare `cargo fuzz build`/`cargo build` in mayhem/build.sh use it
# without a `+toolchain` override.
ARG RUST_NIGHTLY=nightly-2025-06-01
ARG RUST_STABLE=stable
ARG CARGO_FUZZ_VERSION=0.12.0

ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:${PATH}

USER root
RUN install -d /opt/toolchains/rust \
 && curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh \
 && sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "${RUST_NIGHTLY}" \
 && rustup toolchain install "${RUST_STABLE}" --profile minimal \
 && cargo install cargo-fuzz --version "${CARGO_FUZZ_VERSION}" --locked \
 && rm -f /tmp/rustup-init.sh \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must
 # read the toolchains and read/refresh the cargo registry cache, so hand the whole
 # prefix to 2000.
 && chown -R 2000:2000 /opt/toolchains/rust

# Source enters from the build CONTEXT (CI checkout): the FULL repo, incl. .git,
# → /mayhem. The dhall-lang git submodule is deliberately NOT fetched (not needed
# to build: dhall/build.rs generates the parser grammar from an in-repo
# dhall.abnf; mayhem/test.sh avoids the submodule-dependent spec.rs suite).
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Populates $CARGO_HOME (online, this first build) and builds the sanitized fuzz
# target(s) + the KAT probe.
RUN bash mayhem/build.sh

# Run the project's functional suite at build time IF present (a failing suite fails the build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
