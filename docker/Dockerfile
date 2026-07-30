# syntax=docker/dockerfile:1

# ============================================================================
# Build args — control which optional components are included.
# Set to 0 to skip:  BUILD_ANGR=0 BUILD_FUZZING=0 BUILD_ANDROID=0
# ============================================================================
ARG BUILD_ANGR=1
ARG BUILD_FUZZING=0
ARG BUILD_ANDROID=0

# ============================================================================
# Stage 0: base — runtime OS packages only (no build toolchain)
# Used by the final stage. Keeps image lean — no gcc/cmake/maven bloat.
# ============================================================================
FROM ubuntu:24.04 AS base

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    HOME=/home/ctf

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        git curl wget ca-certificates gnupg sudo \
        python3 python3-pip python3-venv pipx \
        file binutils unzip xz-utils zlib1g-dev libssl-dev \
        openjdk-21-jdk-headless \
        gdb gdb-multiarch lldb \
        nasm patchelf elfutils \
        strace ltrace tmux vim less jq \
        libc6-dbg libcapstone-dev \
        zip p7zip-full \
        clang lld llvm \
        libglib2.0-dev libpixman-1-dev \
        libunwind-dev binutils-dev libblocksruntime-dev \
        libqt5widgets5 libc6-i386 \
        gcc g++ make \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /var/lib/apt/lists/partial

RUN useradd -m -s /bin/bash -G sudo ctf \
    && echo "ctf ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
    && mkdir -p /workspace /opt/tools \
    && chown -R ctf:ctf /workspace /opt/tools

# BinDiff — small .deb, rarely changes. Separate layer so apt packages above
# cache independently; bumping BINDIFF_DEB_URL doesn't re-fetch system deps.
ARG BINDIFF_DEB_URL=https://github.com/google/bindiff/releases/download/v8/bindiff_8_amd64.deb
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    wget -q -O /tmp/bindiff.deb "${BINDIFF_DEB_URL}" \
    && apt-get update && apt-get install -y --no-install-recommends /tmp/bindiff.deb \
    && rm -f /tmp/bindiff.deb \
    && rm -rf /var/lib/apt/lists/*


# ============================================================================
# Stage 1: base-build — extends base with build toolchain
# Used by all builder stages. Discarded after build — never ships.
# ============================================================================
FROM base AS base-build

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake meson ninja-build pkg-config \
        maven libtool-bin automake autoconf llvm-dev \
    && rm -rf /var/lib/apt/lists/*


# ============================================================================
# Stage 2: python — angr, pwntools, frida, MCP stack
# ============================================================================
FROM base-build AS python

ARG BUILD_ANGR

# Versions pinned for reproducible builds.
# Bump these ARGs to upgrade.
# NOTE: capstone, unicorn, claripy, pyelftools, z3-solver are left unpinned —
# angr pins exact versions of its own transitive deps. Let pip resolve them.
ARG ANGR_VERSION=9.3.1
ARG PWNTOOLS_VERSION=4.15.0
ARG FRIDA_VERSION=14.9.0
ARG LIEF_VERSION=0.17.6
ARG OBJECTION_VERSION=1.12.5
ARG KEYSTONE_VERSION=0.9.2
ARG R2PIPE_VERSION=1.9.0
ARG ROPPER_VERSION=1.13.10
ARG ROPGADGET_VERSION=7.6
ARG MCP_VERSION=1.13.0

# Layer 1: angr + transitive heavy deps (slow build, rarely bumped).
# These are pinned by angr itself — let pip resolve exact versions.
# BUILD_ANGR=0 skips this — saves ~800MB in final image.
RUN --mount=type=cache,target=/root/.cache/pip \
    if [ "${BUILD_ANGR}" != "0" ]; then \
        pip3 install --break-system-packages \
            angr==${ANGR_VERSION} \
            claripy \
            capstone \
            unicorn \
            pyelftools \
            z3-solver \
            fastmcp; \
    else \
        echo "=== angr: skipped (BUILD_ANGR=0) ==="; \
    fi

# Layer 2: standalone tools (lighter, bumped more often).
# Bumping PWNTOOLS_VERSION or FRIDA_VERSION only invalidates this layer.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip3 install --break-system-packages \
        pwntools==${PWNTOOLS_VERSION} \
        ropper==${ROPPER_VERSION} \
        ropgadget==${ROPGADGET_VERSION} \
        keystone-engine==${KEYSTONE_VERSION} \
        r2pipe==${R2PIPE_VERSION} \
        lief==${LIEF_VERSION} \
        frida-tools==${FRIDA_VERSION} \
        objection==${OBJECTION_VERSION} \
        mcp==${MCP_VERSION}


# ============================================================================
# Stage 3: r2-ghidra — radare2 + r2pm plugins, Ghidra headless, ghidra-mcp
# ============================================================================
FROM base-build AS r2-ghidra

# -- radare2 from source, installed to /opt/tools/radare2 -------------------
ARG R2_VERSION=6.0.8

RUN git clone --depth 1 --branch ${R2_VERSION} \
        https://github.com/radareorg/radare2 /opt/tools/radare2-src \
    && cd /opt/tools/radare2-src \
    && PREFIX=/opt/tools/radare2 sys/install.sh
# NOTE: keep radare2-src — sys/install.sh symlinks binaries/libs to it.
# Deleting it breaks radare2 + r2pm. Extra ~200MB acceptable.

# r2pm plugins (r2mcp, r2ghidra, r2ghidra-sleigh).
# Run as ctf so any plugin files written to ~/.local are captured.
ARG MCP_VERSION=1.13.0
ENV PATH="/opt/tools/radare2/bin:${PATH}" \
    PKG_CONFIG_PATH="/opt/tools/radare2/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
RUN pip3 install --break-system-packages mcp==${MCP_VERSION} \
    && chown -R ctf:ctf /opt/tools/radare2
USER ctf
# Layer 1: r2pm database update (network-bound, rarely invalidates).
RUN r2pm -U
# Layer 2: install plugins + patch r2mcp for radare2 >=6.0.
# r2pm's own make fails on the ld error; we ignore, patch, rebuild manually.
# Separate layer: if the r2mcp patch breaks on a new r2 version, only this
# RUN re-executes — r2pm -U stays cached.
RUN r2pm -ci r2mcp r2ghidra r2ghidra-sleigh || true \
    && cd /home/ctf/.local/share/radare2/r2pm/git/r2mcp/src \
    && sed -i 's/r_core_call_str_at/r_core_cmd_str_at/g' tools.c \
    && sed -i 's/r_table_new ("tools", NULL)/r_table_new ("tools")/' tools.c \
    && make clean && make && make user-install
USER root

# -- Ghidra headless --------------------------------------------------------
ARG GHIDRA_VERSION=12.1.2
ARG GHIDRA_DATE=20260605
ARG GHIDRA_URL=https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_DATE}.zip

RUN wget -q -O /tmp/ghidra.zip "${GHIDRA_URL}" \
    && unzip -q /tmp/ghidra.zip -d /opt/tools \
    && mv /opt/tools/ghidra_${GHIDRA_VERSION}_PUBLIC /opt/tools/ghidra \
    && rm /tmp/ghidra.zip \
    && chmod +x /opt/tools/ghidra/support/analyzeHeadless

# -- ghidra-mcp headless server ---------------------------------------------
ARG GHIDRA_MCP_VERSION=v5.13.1

RUN --mount=type=cache,target=/root/.m2/repository \
    git clone --depth 1 --branch ${GHIDRA_MCP_VERSION} \
        https://github.com/bethington/ghidra-mcp /opt/tools/ghidra-mcp \
    && cd /opt/tools/ghidra-mcp \
    && pip3 install --break-system-packages --no-cache-dir -r requirements.txt \
    && GHIDRA_ACTUAL_VERSION="$(grep '^application\.version=' \
         /opt/tools/ghidra/Ghidra/application.properties | cut -d= -f2)" \
    && echo "==> Patching pom.xml ghidra.version to ${GHIDRA_ACTUAL_VERSION}" \
    && sed -i "s|<ghidra.version>[^<]*</ghidra.version>|<ghidra.version>${GHIDRA_ACTUAL_VERSION}</ghidra.version>|" pom.xml \
    && PIP_BREAK_SYSTEM_PACKAGES=1 python3 -m tools.setup ensure-prereqs --ghidra-path /opt/tools/ghidra \
    && mvn -q -DskipTests -Pheadless clean package \
    && HEADLESS_JAR="$(find target/archive-tmp -maxdepth 1 -iname '*.jar' 2>/dev/null | head -n1)" \
    && if [ -z "${HEADLESS_JAR}" ]; then \
         HEADLESS_JAR="$(find target -maxdepth 1 -iname '*Headless*.jar' 2>/dev/null | head -n1)"; \
       fi \
    && if [ -z "${HEADLESS_JAR}" ]; then \
         echo "WARN: no jar in archive-tmp or target, falling back to largest jar" >&2 \
         && HEADLESS_JAR="$(find target -maxdepth 1 -iname '*.jar' -printf '%s %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)"; \
       fi \
    && mkdir -p docker \
    && echo "==> Deploying ${HEADLESS_JAR} -> docker/GhidraMCPHeadless.jar" \
    && cp "${HEADLESS_JAR}" docker/GhidraMCPHeadless.jar


# ============================================================================
# Stage 4: fuzzing — AFL++, honggfuzz
# BUILD_FUZZING=0 skips — saves ~200MB in final image.
# Uses GitHub tarballs (wget) instead of git clone for reliability — git
# protocol occasionally fails with exit 128 in BuildKit.
# ============================================================================
FROM base-build AS fuzzing

ARG BUILD_FUZZING

ARG AFLPLUSPLUS_VERSION=v5.00c
ARG HONGGFUZZ_VERSION=2.6

RUN if [ "${BUILD_FUZZING}" = "0" ]; then \
         echo "=== fuzzing: skipped (BUILD_FUZZING=0) ==="; \
         mkdir -p /opt/tools/fuzzing/bin; \
         exit 0; \
       fi

RUN echo "=== Building AFL++ ${AFLPLUSPLUS_VERSION} ===" \
    && mkdir -p /opt/tools/fuzzing/bin \
    && wget -q -O /tmp/afl.tar.gz \
        "https://github.com/AFLplusplus/AFLplusplus/archive/refs/tags/${AFLPLUSPLUS_VERSION}.tar.gz" \
    && tar -xzf /tmp/afl.tar.gz -C /opt/tools \
    && mv "/opt/tools/AFLplusplus-${AFLPLUSPLUS_VERSION#v}" /opt/tools/AFLplusplus-src \
    && rm /tmp/afl.tar.gz \
    && cd /opt/tools/AFLplusplus-src \
    && make distrib -j"$(nproc)" \
    && PREFIX=/opt/tools/fuzzing make install \
    && rm -rf /opt/tools/AFLplusplus-src

RUN echo "=== Building honggfuzz ${HONGGFUZZ_VERSION} ===" \
    && wget -q -O /tmp/honggfuzz.tar.gz \
        "https://github.com/google/honggfuzz/archive/refs/tags/${HONGGFUZZ_VERSION}.tar.gz" \
    && tar -xzf /tmp/honggfuzz.tar.gz -C /opt/tools \
    && mv "/opt/tools/honggfuzz-${HONGGFUZZ_VERSION}" /opt/tools/honggfuzz-src \
    && rm /tmp/honggfuzz.tar.gz \
    && cd /opt/tools/honggfuzz-src \
    && make -j"$(nproc)" \
    && PREFIX=/opt/tools/fuzzing make install \
    && rm -rf /opt/tools/honggfuzz-src


# ============================================================================
# Stage 5: android — platform-tools, apktool, jadx
# BUILD_ANDROID=0 skips — saves ~165MB in final image.
# ============================================================================
FROM base-build AS android

ARG BUILD_ANDROID

ARG PLATFORM_TOOLS_VERSION=37.0.0
ARG APKTOOL_VERSION=2.10.0
ARG JADX_VER=1.5.1

RUN mkdir -p /opt/tools/platform-tools /opt/tools/jadx/bin \
    && touch /opt/tools/apktool.jar \
    && if [ "${BUILD_ANDROID}" = "0" ]; then \
         echo "=== android: skipped (BUILD_ANDROID=0) ==="; \
         exit 0; \
       fi \
    && wget -q -O /tmp/platform-tools.zip \
        "https://dl.google.com/android/repository/platform-tools_r${PLATFORM_TOOLS_VERSION}-linux.zip" \
    && unzip -q /tmp/platform-tools.zip -d /opt/tools \
    && rm /tmp/platform-tools.zip \
    && wget -q -O /opt/tools/apktool.jar \
        "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar" \
    && wget -q -O /tmp/jadx.zip \
        "https://github.com/skylot/jadx/releases/download/v${JADX_VER}/jadx-${JADX_VER}.zip" \
    && unzip -q /tmp/jadx.zip -d /opt/tools/jadx \
    && chmod +x /opt/tools/jadx/bin/jadx /opt/tools/jadx/bin/jadx-gui 2>/dev/null || true \
    && rm /tmp/jadx.zip


# ============================================================================
# Stage 6: final — assemble all stages + scripts/configs
# FROM base (NOT base-build!) — ~400MB smaller without gcc/cmake/maven.
# ============================================================================
FROM base AS final

ARG BUILD_ANGR
ARG BUILD_FUZZING
ARG BUILD_ANDROID

# --- Python packages (pip-installed modules + entry-point scripts) ----------
COPY --from=python /usr/local/lib/ /usr/local/lib/
COPY --from=python /usr/local/bin/ /usr/local/bin/

# --- radare2 + plugins ------------------------------------------------------
COPY --from=r2-ghidra /opt/tools/radare2 /opt/tools/radare2
# Keep source tree — radare2 sys/install.sh symlinks binaries/libs to it
COPY --from=r2-ghidra /opt/tools/radare2-src /opt/tools/radare2-src
# Capture any r2pm plugin data written to ctf's home (e.g. r2pm db, plugin configs)
COPY --from=r2-ghidra /home/ctf /home/ctf

# --- Ghidra + ghidra-mcp ----------------------------------------------------
COPY --from=r2-ghidra /opt/tools/ghidra /opt/tools/ghidra
COPY --from=r2-ghidra /opt/tools/ghidra-mcp /opt/tools/ghidra-mcp
# Merge any extra pip deps installed by ghidra-mcp requirements.txt
COPY --from=r2-ghidra /usr/local/lib/ /usr/local/lib/
COPY --from=r2-ghidra /usr/local/bin/ /usr/local/bin/

# --- Fuzzing tools (optional: BUILD_FUZZING=0 skips) ------------------------
COPY --from=fuzzing /opt/tools/fuzzing /opt/tools/fuzzing

# --- Android tools (optional: BUILD_ANDROID=0 skips) ------------------------
COPY --from=android /opt/tools/platform-tools /opt/tools/platform-tools
COPY --from=android /opt/tools/apktool.jar /opt/tools/apktool.jar
COPY --from=android /opt/tools/jadx /opt/tools/jadx

# apktool wrapper + jadx symlinks (only if android was actually built)
RUN if [ -s /opt/tools/apktool.jar ]; then \
        printf '#!/bin/sh\nexec java -jar /opt/tools/apktool.jar "$@"\n' > /usr/local/bin/apktool \
        && chmod +x /usr/local/bin/apktool \
        && echo "apktool wrapper installed"; \
    else \
        echo "apktool: skipped (jar empty or missing)"; \
    fi

RUN if [ -x /opt/tools/jadx/bin/jadx ]; then \
        ln -sf /opt/tools/jadx/bin/jadx /usr/local/bin/jadx \
        && ln -sf /opt/tools/jadx/bin/jadx-gui /usr/local/bin/jadx-gui \
        && echo "jadx symlinks installed"; \
    else \
        echo "jadx: skipped (binary not found)"; \
    fi

# --- Environment ------------------------------------------------------------
ENV GHIDRA_INSTALL_DIR=/opt/tools/ghidra
ENV PATH="/opt/tools/radare2/bin:/home/ctf/.local/share/radare2/prefix/bin:${GHIDRA_INSTALL_DIR}:${GHIDRA_INSTALL_DIR}/support:/opt/tools/fuzzing/bin:/opt/tools/platform-tools:${PATH}"
ENV LD_LIBRARY_PATH="/opt/tools/radare2/lib:${LD_LIBRARY_PATH:-}"
ENV PKG_CONFIG_PATH="/opt/tools/radare2/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# --- Scripts (most-frequently-changed — keep LAST) --------------------------
COPY scripts/ /opt/tools/scripts/

RUN find /opt/tools/scripts -name '*.sh' -exec chmod +x {} + \
    && find /opt/tools/scripts -name '*.py' -exec chmod +x {} + \
    && mkdir -p /home/ctf/.config/ghidra \
    && chown -R ctf:ctf /opt/tools /home/ctf

USER ctf
WORKDIR /workspace

ENTRYPOINT ["/opt/tools/scripts/entrypoint.sh"]
CMD ["bash"]
