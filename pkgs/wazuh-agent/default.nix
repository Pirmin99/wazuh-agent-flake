# pkgs/wazuh-agent/default.nix
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchurl,
  cmake,
  gnumake,
  gcc,
  python3,
  perl,
  curl,
  gnutar,
  gzip,
  bzip2,
  xz,
  automake,
  autoconf,
  libtool,
  makeWrapper,
  openssl,
  zlib,
  pkg-config,
  expat,
  which,
  git,
  attr,
  clang,
  elfutils,
  patchelf,
}:

let
  # Version and dependency hashes live in deps.json; regenerate it with
  # scripts/update-deps.sh (or: nix run .#update) on a version bump.
  pins = lib.importJSON ./deps.json;
  inherit (pins) version depsVer;
  depsBase = "https://packages.wazuh.com/deps/${depsVer}/libraries/sources";

  dep =
    name: sha256:
    fetchurl {
      url = "${depsBase}/${name}.tar.gz";
      inherit sha256;
    };

  # These must match the GIT_TAGs that libbpf-bootstrap's CMakeLists asks for;
  # we pre-place the checkouts instead of letting it clone, so nothing in the
  # build would otherwise notice a mismatch. postUnpack asserts both tags are
  # still the ones below, so a deps release that moves them fails the build.
  bpftoolRev = "v7.7.0";
  libbpfRev = "v1.7.0";

  bpftoolSrc = fetchFromGitHub {
    owner = "libbpf";
    repo = "bpftool";
    rev = bpftoolRev;
    sha256 = "sha256-U49a1L0MGzP45ZGpsIBMavnn26FArp5hN+EpmnDJEiE=";
    fetchSubmodules = true;
  };

  libbpfSrc = fetchFromGitHub {
    owner = "libbpf";
    repo = "libbpf";
    rev = libbpfRev;
    sha256 = "sha256-F92msxkYp4yZA3qUoSwS5GKUhcEO6DrYNln7w6U+jt0=";
  };

  vmlinuxSrc = fetchFromGitHub {
    owner = "libbpf";
    repo = "vmlinux.h";
    rev = "5c36ac2080a8d3c1216470ce97e6502ed50272e5";
    sha256 = "sha256-EKLJh3sSH/BGMZHUfivQ8J1QbtnybekghZ+LNvdj858=";
  };

  externalDeps = lib.mapAttrs dep pins.deps;

  src = fetchFromGitHub {
    owner = "wazuh";
    repo = "wazuh";
    rev = "v${version}";
    sha256 = pins.srcHash;
    fetchSubmodules = true;
  };

in
stdenv.mkDerivation rec {
  pname = "wazuh-agent";
  inherit version src;

  # Newer GCC/glibc: strstr()/strchr() now preserve const, and the bundled
  # libbpf (bpftool bootstrap) is built with -Werror.
  env.NIX_CFLAGS_COMPILE = "-Wno-error=discarded-qualifiers";

  hardeningDisable = [ "zerocallusedregs" ];

  dontConfigure = true;

  nativeBuildInputs = [
    cmake
    gnumake
    gcc
    python3
    perl
    curl
    gnutar
    gzip
    bzip2
    xz
    automake
    autoconf
    libtool
    makeWrapper
    pkg-config
    expat
    which
    git
    clang
    clang.cc
    elfutils
    patchelf
  ];

  buildInputs = [
    openssl
    zlib
    attr
    stdenv.cc.cc.lib
    # Runtime dep of the libbpf.so we ship: it needs libelf.so.1 resolvable
    # from the installed rpath, not just at build time.
    elfutils
  ];

  postUnpack = ''
    mkdir -p source/src/external
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (dirName: drv: ''
        echo "Extracting ${dirName}..."
        mkdir -p source/src/external/${dirName}
        # Layouts vary between deps releases: most tarballs are name/...,
        # some ./name/... — strip the extra leading "." component when present.
        # (sed reads the whole listing; head would EPIPE tar under pipefail)
        firstEntry=$(tar -tf ${drv} | sed -n 1p)
        case $firstEntry in
          ./*) strip=2 ;;
          *)   strip=1 ;;
        esac
        tar -xf ${drv} -C source/src/external/${dirName} --strip-components=$strip
      '') externalDeps
    )}
    substituteInPlace source/src/external/openssl/config \
      --replace-fail 'exec "$THERE/Configure"' 'exec "$(cd "$THERE" && pwd)/Configure"'
    patchShebangs source/src/external/openssl/Configure
    # Copies from the read-only store land read-only, so the strip/elfedit steps
    # that follow need write permission. Anchor at end-of-line and carry the
    # optional ".tmp" suffix along: 4.14.10 changed the libstdc++ rule to
    # "cp $< $@.tmp ... mv $@.tmp $@", and an unanchored match rewrote it into
    # "cp $< $@ && chmod u+w $@.tmp" (copying to the wrong name, then chmod'ing
    # a file that does not exist).
    sed -i 's|cp $< $@\(\.tmp\)\?$|cp $< $@\1 \&\& chmod u+w $@\1|' source/src/Makefile
    grep -qF 'cp $< $@.tmp && chmod u+w $@.tmp' source/src/Makefile \
      || { echo "ERROR: chmod patch did not apply to the libstdc++ rule in src/Makefile"; exit 1; }
    sed -i 's|cd $(EXTERNAL_AUDIT) && ./autogen.sh && ./configure|cd $(EXTERNAL_AUDIT) \&\& chmod -R u+w . \&\& rm -f INSTALL \&\& ./autogen.sh \&\& ./configure|' source/src/Makefile
    sed -i 's|cp INSTALL.tmp INSTALL|chmod u+w INSTALL 2>/dev/null; cp INSTALL.tmp INSTALL|g' \
      source/src/external/audit-userspace/autogen.sh
    mkdir -p source/src/external/libdb/build_unix
    mkdir -p source/src/external/libbpf-bootstrap/src
    # libbpf-bootstrap's CMakeLists downloads modern.bpf.c from a hardcoded
    # WAZUH_BRANCH (v4.12.0 in deps 55) that nothing in the tree overrides, but
    # that copy is stale: the in-tree one grew euid/login_uid, which the
    # userspace mirror struct in src/syscheckd/src/ebpf/include/bpf_helpers.h
    # expects. Taking the branch's copy would compile fine and then hand
    # userspace a struct with every field past gid at the wrong offset.
    test -e source/src/syscheckd/src/ebpf/src/modern.bpf.c \
      || { echo "ERROR: in-tree modern.bpf.c not found under src/syscheckd/src/ebpf/src"; exit 1; }
    grep -q 'login_uid' source/src/syscheckd/src/ebpf/include/bpf_helpers.h \
      || echo "WARNING: bpf_helpers.h no longer mentions login_uid - recheck the file_event layout"
    cp source/src/syscheckd/src/ebpf/src/modern.bpf.c \
      source/src/external/libbpf-bootstrap/src/modern.bpf.c
    substituteInPlace source/src/external/libbpf-bootstrap/CMakeLists.txt \
      --replace-fail \
      'file(DOWNLOAD ''${FILE_URL} ''${DEST_PATH})' \
      '# download skipped - file pre-placed by Nix'
    # Pin check before the clone directives are stripped: once GIT_TAG is gone
    # there is nothing left to compare libbpfSrc/bpftoolSrc against.
    grep -qF 'GIT_TAG ${libbpfRev}' source/src/external/libbpf-bootstrap/CMakeLists.txt \
      || { echo "ERROR: libbpf-bootstrap no longer asks for libbpf ${libbpfRev}; update libbpfRev/libbpfSrc"; exit 1; }
    grep -qF 'GIT_TAG ${bpftoolRev}' source/src/external/libbpf-bootstrap/CMakeLists.txt \
      || { echo "ERROR: libbpf-bootstrap no longer asks for bpftool ${bpftoolRev}; update bpftoolRev/bpftoolSrc"; exit 1; }
    # Drop every clone directive (libbpf, bpftool, vmlinux.h): the sources are
    # pre-placed below and the sandbox has no network.
    sed -i '/^  GIT_REPOSITORY /d; /^  GIT_TAG /d' source/src/external/libbpf-bootstrap/CMakeLists.txt
    ! grep -q 'GIT_REPOSITORY\|GIT_TAG' source/src/external/libbpf-bootstrap/CMakeLists.txt \
      || { echo "ERROR: clone directives remain in libbpf-bootstrap/CMakeLists.txt"; exit 1; }
    sed -i 's/-fzero-call-used-regs=used-gpr//g' source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i '/^add_library(modern SHARED src\/modern.bpf.c)/d' \
      source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i '/^target_compile_options(modern PRIVATE/d' \
      source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i '/^target_link_libraries(modern modern_skel)/d' \
      source/src/external/libbpf-bootstrap/CMakeLists.txt
    # Deleting add_library(modern ...) leaves change_libbpf_include as the only
    # consumer of the modern.bpf.o custom command, so CMake emits that rule into
    # change_libbpf_include.dir — a target with no dependency on libbpf-build.
    # Under -j that races clang against libbpf's install_uapi_headers and fails
    # with "'bpf/bpf_helpers.h' file not found". Add the missing edge.
    grep -q '^add_custom_target(change_libbpf_include' \
      source/src/external/libbpf-bootstrap/CMakeLists.txt \
      || { echo "ERROR: change_libbpf_include target not found in libbpf-bootstrap/CMakeLists.txt"; exit 1; }
    echo 'add_dependencies(change_libbpf_include libbpf-build bpftool-build vmlinux.h)' \
      >> source/src/external/libbpf-bootstrap/CMakeLists.txt
    cp -rv ${libbpfSrc}/. source/src/external/libbpf-bootstrap/libbpf/
    cp -rv ${bpftoolSrc}/. source/src/external/libbpf-bootstrap/bpftool/
    chmod -R u+w source/src/external/libbpf-bootstrap/bpftool/
    cp -rv ${libbpfSrc}/. source/src/external/libbpf-bootstrap/bpftool/libbpf/
    cp -rv ${vmlinuxSrc}/. source/src/external/libbpf-bootstrap/vmlinux.h/
    sed -i 's|\''${BPFOBJECT_CLANG_EXE} -g -O2 -target bpf -D__TARGET_ARCH_\''${ARCH}|''${BPFOBJECT_CLANG_EXE} -g -O2 -target bpf -std=gnu11 -D__TARGET_ARCH_''${ARCH}|' \
      source/src/external/libbpf-bootstrap/tools/cmake/FindBpfObject.cmake
    sed -i 's|\''${CLANG_SYSTEM_INCLUDES} -I\''${GENERATED_VMLINUX_DIR}|-I''${GENERATED_VMLINUX_DIR}|' \
      source/src/external/libbpf-bootstrap/tools/cmake/FindBpfObject.cmake
    # Pin the BPF compile to unwrapped clang: FindBpfObject only calls
    # find_program when BPFOBJECT_CLANG_EXE is unset, and that picks the clang
    # wrapper off $PATH, which injects host target/sysroot/hardening flags into
    # a "-target bpf" compile. (The sed this replaces searched for a
    # -DBPFOBJECT_CLANG_EXE= that only its own replacement would have inserted,
    # so it never matched; VERBOSE=1 already reaches this sub-make through
    # MAKEFLAGS from the top-level make.)
    substituteInPlace source/src/Makefile \
      --replace-fail \
      'cd $(EXTERNAL_LIBBPF) && mkdir -p build && cd build && cmake .. && ''${MAKE}' \
      'cd $(EXTERNAL_LIBBPF) && mkdir -p build && cd build && cmake -DBPFOBJECT_CLANG_EXE=${clang.cc}/bin/clang .. && ''${MAKE}'
    find source/src/shared_modules source/src/data_provider -name "CMakeLists.txt" \
      -exec sed -i \
        -e 's|-std=c++14|-std=c++17|g' \
        -e '/^set(CMAKE_CXX_FLAGS "-Wall/d' \
      {} \;
    find source/src/shared_modules source/src/data_provider -name "CMakeLists.txt" \
      -exec sed -i \
        '1s|^|string(APPEND CMAKE_CXX_FLAGS " -std=c++17 -include cstdint -include filesystem")\n|' \
      {} \;
    sed -i 's|os_calloc(PATH_MAX, sizeof(char), buff);|os_calloc(PATH_MAX, sizeof(char), buff); { char * home_env = getenv("WAZUH_HOME"); if (home_env) { snprintf(buff, PATH_MAX, "%s", home_env); return buff; } }|' \
      source/src/shared/file_op.c
    # The whole runtime layout depends on this patch; fail loudly if a
    # version bump changes file_op.c and the sed above stops matching.
    grep -q 'getenv("WAZUH_HOME")' source/src/shared/file_op.c \
      || { echo "ERROR: WAZUH_HOME patch did not apply to src/shared/file_op.c"; exit 1; }
    chmod -R u+w source/src/external/
  '';

  buildPhase = ''
    runHook preBuild
    cd src

    # Pre-build bpftool so it exists when libbpf-bootstrap's CMake configures
    BPFTOOL_OUT="$(pwd)/external/libbpf-bootstrap/build/bpftool/bootstrap"
    mkdir -p "$BPFTOOL_OUT"
    cd external/libbpf-bootstrap/bpftool/src
    make -j$NIX_BUILD_CORES \
      OUTPUT="$BPFTOOL_OUT/" \
      bootstrap
    cp "$BPFTOOL_OUT/bootstrap/bpftool" "$BPFTOOL_OUT/bpftool"
    cd ../../../..

    # vmlinux.h comes from the pinned libbpf/vmlinux.h checkout copied in
    # postUnpack (CO-RE, kernel-independent) — no host BTF dump needed.
    test -e external/libbpf-bootstrap/vmlinux.h/include/x86/vmlinux.h \
      || { echo "ERROR: pinned vmlinux.h not found at include/x86/vmlinux.h"; exit 1; }

    # Pre-build libdb so db.h exists when data_provider CMake configures
    mkdir -p external/libdb/build_unix
    cd external/libdb/build_unix
    CPPFLAGS=-fPIC ../dist/configure \
      --with-cryptography=no \
      --disable-queue \
      --disable-heap \
      --disable-partition \
      --disable-mutexsupport \
      --disable-replication \
      --disable-verify \
      --disable-statistics \
      ac_cv_func_pthread_yield=no
    make libdb.a
    cd ../../..

    chmod -R u+w external/audit-userspace/
    make TARGET=agent -j$NIX_BUILD_CORES VERBOSE=1
    cd ..
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    INST=$out/opt/wazuh-agent

    mkdir -p \
      $INST/bin \
      $INST/lib \
      $INST/etc \
      $INST/etc/shared \
      $INST/ruleset/decoders \
      $INST/ruleset/rules \
      $INST/ruleset/sca \
      $INST/active-response/bin

    # These are essential; a missing one means the build silently produced a
    # broken agent, so install unconditionally and let a failure abort.
    for bin in \
        wazuh-agentd \
        wazuh-logcollector \
        wazuh-modulesd \
        wazuh-execd \
        agent-auth \
        manage_agents; do
      install -m 0750 src/$bin $INST/bin/$bin
    done

    install -m 0750 src/syscheckd/build/bin/wazuh-syscheckd $INST/bin/wazuh-syscheckd
    find src -maxdepth 2 -name "*.so*" -exec cp -P {} $INST/lib/ \; || true
    find src/shared_modules -name "*.so*" -exec cp -P {} $INST/lib/ \; || true
    find src/syscheckd -name "*.so*" -exec cp -P {} $INST/lib/ \; || true
    find src/wazuh_modules -name "*.so*" -exec cp -P {} $INST/lib/ \; || true
    find src/data_provider -name "*.so*" -exec cp -P {} $INST/lib/ \; || true

    # eBPF whodata needs two artifacts that upstream's installer places in lib/
    # (src/init/inst-functions.sh): modern.bpf.o, which wazuh-syscheckd opens by
    # path at runtime, and libbpf.so, which libfimebpf.so dlopens by soname.
    # Both are built but neither is picked up by the finds above, so install
    # them explicitly — and fail loudly rather than silently shipping an agent
    # whose whodata cannot start.
    test -e src/external/libbpf-bootstrap/build/modern.bpf.o \
      || { echo "ERROR: modern.bpf.o was not built; eBPF whodata would fail at runtime"; exit 1; }
    install -m 0750 src/external/libbpf-bootstrap/build/modern.bpf.o $INST/lib/modern.bpf.o
    # Our ExternalProject passes OBJDIR=build/libbpf/libbpf, so libbpf.so lands
    # one directory deeper than the build/libbpf/libbpf.so that upstream's
    # installer looks for. install(1) dereferences the .so -> .so.1 -> .so.M.m
    # symlink chain, matching what upstream ships: a single regular file.
    test -e src/external/libbpf-bootstrap/build/libbpf/libbpf/libbpf.so \
      || { echo "ERROR: libbpf.so not found under build/libbpf/libbpf - OBJDIR layout changed"; exit 1; }
    install -m 0750 src/external/libbpf-bootstrap/build/libbpf/libbpf/libbpf.so $INST/lib/libbpf.so

    # Replace the rpath wholesale: the build-tree entries it contains are
    # dangling (and rejected by the /build/ reference check), but keep the
    # buildInputs store paths resolvable alongside the bundled libs.
    RPATH="$INST/lib:${
      lib.makeLibraryPath [
        openssl
        zlib
        attr
        stdenv.cc.cc.lib
        elfutils
      ]
    }"
    for f in $INST/lib/*.so $INST/lib/*.so.*; do
      patchelf --set-rpath "$RPATH" $f 2>/dev/null || true
    done

    for f in $INST/bin/*; do
      patchelf --set-rpath "$RPATH" $f 2>/dev/null || true
    done

    install -m 0750 src/init/wazuh-client.sh $INST/bin/wazuh-control

    sed -i \
      -e 's|DIR=`dirname $PWD`;|DIR=''${WAZUH_HOME:-`dirname $PWD`}; cd $DIR;|' \
      -e '/^DIR=/a BINDIR=''${WAZUH_BINDIR:-$DIR/bin};' \
      -e '/^BINDIR=/a export WAZUH_HOME=''${WAZUH_HOME:-$DIR};' \
      -e 's|''${DIR}/bin/|''${BINDIR}/|g' \
      -e 's|\.\./|''${DIR}/|g' \
      $INST/bin/wazuh-control
    grep -q 'WAZUH_HOME' $INST/bin/wazuh-control \
      || { echo "ERROR: wazuh-control rewrite did not apply"; exit 1; }

    install -m 0640 etc/internal_options.conf $INST/etc/internal_options.conf

    cp -r active-response/bin/. $INST/active-response/bin/ || true
    cp -r ruleset/decoders/.    $INST/ruleset/decoders/
    cp -r ruleset/rules/.       $INST/ruleset/rules/
    cp -r ruleset/sca/.         $INST/ruleset/sca/ || true
    cp -r etc/shared/.          $INST/etc/shared/   || true

    install -m 0640 etc/ossec-agent.conf $INST/etc/ossec.conf.template 2>/dev/null \
      || install -m 0640 etc/ossec.conf $INST/etc/ossec.conf.template 2>/dev/null \
      || true

    chmod +x $INST/bin/* 2>/dev/null || true
    makeWrapper $INST/bin/wazuh-agentd $out/bin/wazuh-agentd \
      --set WAZUH_HOME /var/lib/wazuh-agent

    makeWrapper $INST/bin/wazuh-control $out/bin/wazuh-control \
      --set WAZUH_HOME /var/lib/wazuh-agent

    makeWrapper $INST/bin/agent-auth $out/bin/agent-auth \
      --set WAZUH_HOME /var/lib/wazuh-agent

    runHook postInstall
  '';

  meta = with lib; {
    description = "Wazuh open-source security agent (XDR/SIEM endpoint component)";
    homepage = "https://wazuh.com";
    license = licenses.gpl2Only;
    mainProgram = "wazuh-control";
    platforms = [ "x86_64-linux" ];
    maintainers = [ ];
  };
}
