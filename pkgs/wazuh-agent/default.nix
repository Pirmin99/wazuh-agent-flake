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
  version = "4.14.5";
  depsVer = "99-29585";
  depsBase = "https://packages.wazuh.com/deps/${depsVer}/libraries/sources";

  dep =
    name: sha256:
    fetchurl {
      url = "${depsBase}/${name}.tar.gz";
      inherit sha256;
    };

  depNlohmann =
    sha256:
    fetchurl {
      url = "https://packages.wazuh.com/deps/21/libraries/sources/nlohmann.tar.gz";
      inherit sha256;
    };

  modernBpfC = fetchurl {
    url = "https://raw.githubusercontent.com/wazuh/wazuh/v4.12.0/src/syscheckd/src/ebpf/src/modern.bpf.c";
    sha256 = "sha256-mnPGgEoBZgXT6KxNCHEYt8eZHqrWIJjajxwiifpff+A=";
  };

  bpftoolSrc = fetchFromGitHub {
    owner = "libbpf";
    repo = "bpftool";
    rev = "v7.5.0";
    sha256 = "sha256-XUh53pZ4NS56aMZMxYFVxrS+yScH0M7NiRGwjw8P3NE=";
    fetchSubmodules = true;
  };

  libbpfSrc = fetchFromGitHub {
    owner = "libbpf";
    repo = "libbpf";
    rev = "v1.5.0";
    sha256 = "sha256-+L/rbp0a3p4PHq1yTJmuMcNj0gT5sqAPeaNRo3Sh6U8=";
  };

  # Pinned commit of main; provides the CO-RE vmlinux.h used for the eBPF
  # build (include/x86/vmlinux.h), so no BTF dump from the host kernel and
  # therefore no sandbox escape is needed.
  vmlinuxSrc = fetchFromGitHub {
    owner = "libbpf";
    repo = "vmlinux.h";
    rev = "5c36ac2080a8d3c1216470ce97e6502ed50272e5";
    sha256 = "sha256-EKLJh3sSH/BGMZHUfivQ8J1QbtnybekghZ+LNvdj858=";
  };

  externalDeps = {
    "audit-userspace" = dep "audit-userspace" "sha256-6Coy5e35OwVRYOFLyX9B3q05KHklhR3ICnY44tTTBDQ=";
    benchmark = dep "benchmark" "sha256-lMV6oMsr142+nnfTMsvGRNrw/s3JoJYyBIvm4J+c7Ws=";
    bzip2 = dep "bzip2" "sha256-J2iO4DFqZLOeURssIkBwytl8OUpfcR+dBV/BgJ2JW80=";
    cJSON = dep "cJSON" "sha256-2oCfcLfQOsUprmIj1DkL+ibNKfjDLI6LO2Me+hZniS0=";
    "cpp-httplib" = dep "cpp-httplib" "sha256-GLroWhWQcef5tpB5lrV2fBJW6me4ip74bbdzgF0eRrU=";
    curl = dep "curl" "sha256-qTtbg5JV2SSHo/mtffraHcc6sBaALH9mncCaiRxlRvo=";
    dbus = dep "dbus" "sha256-fGVKyaT2i1DzLWdJIsGP/nQdMoqX15RFdhj8OgekjTo=";
    googletest = dep "googletest" "sha256-jB6KCn8iHCEl6Z5qy3CdorpHJHa00FfFjeUEvr841Bc=";
    libarchive = dep "libarchive" "sha256-VA/0pV3vp1d4osQFZ6gwZIzlNnuK6hIzZodNlrc074A=";
    "libbpf-bootstrap" = dep "libbpf-bootstrap" "sha256-hh74B1ePDobIfuXC2YdHaFPmQGm/xLsTon4jPtNXSDI=";
    libdb = dep "libdb" "sha256-fpxE6Mf9sYb/UhqNCFsb+mNNNC3Md37Oofv5qYq13F4=";
    libffi = dep "libffi" "sha256-DpcfZLrMIglOifA0u6B1tA7MLCwpAO7NeuhYFf1sn2k=";
    libpcre2 = dep "libpcre2" "sha256-WoDWVNfRSz25+jpJ179EpJhoO0Z4SojOxRSosZR2e5I=";
    libplist = dep "libplist" "sha256-iCeNS9/BvWo6GlWk89kzaD0nMroJz3p0n+jsjuxAbjw=";
    libyaml = dep "libyaml" "sha256-NdqtYIs3LVzgmfc4wPIb/MA9aSDZL0SDhsWE5mTxN2o=";
    lua = dep "lua" "sha256-Iz6H6HEJC9MMS2kqxzvXFDYcFQURSOTu7IKKHfhDbso=";
    lzma = dep "lzma" "sha256-TODBktQQcrVnmvibtTHvtoXIJnpLfiAFmZFJrBcCgTQ=";
    msgpack = dep "msgpack" "sha256-BtY7zzKJbNCvVIDEARNLGtHBZv2E6+W0hueSEB7oVOI=";
    nlohmann = depNlohmann "sha256-tcOpnp61Mx2VjivdOmKDxLnqetZ03UZp7ibVxe74Rf4=";
    openssl = dep "openssl" "sha256-A4b+Ogv0i64spNF0KlPfmo/LG3NYO6Iuj4p936E3XNk=";
    pacman = dep "pacman" "sha256-Yxq+Bl7JgttWv+wFzzfDOo9on9f0Fkw5J3KEvXoNDjE=";
    popt = dep "popt" "sha256-1ogKBmIsoy3EqjmtXc977y+qgb2TGvvmS6Q0rY/uHao=";
    procps = dep "procps" "sha256-Ih85XinRvb5LrMnbOWAu7guuaFqTVDe+DX/rQuMZLQc=";
    rocksdb = dep "rocksdb" "sha256-7u1go9Tin3MF55+fXOvUJhF0JhIn8bWn0F2lVWVnVDY=";
    rpm = dep "rpm" "sha256-kNhy9U6rzzdzbZCsF6jTEwEtqE5oWxn9Lav0oBKVcpA=";
    sqlite = dep "sqlite" "sha256-qBv/MLtK/9GwakmD/4jvgntKuuoxkbOa/37bKNHd0AM=";
    zlib = dep "zlib" "sha256-tZ04FJ8MKexU0nZmEevFpRoDK/lxfjmprwD7bLhTK4s=";
  };

  src = fetchFromGitHub {
    owner = "wazuh";
    repo = "wazuh";
    rev = "v${version}";
    sha256 = "sha256-YflBYPNfLRVUIVZH9BRgDLKiMFqQh3hB8Yk0DS6dlaU=";
    fetchSubmodules = true;
  };

in
stdenv.mkDerivation rec {
  pname = "wazuh-agent";
  inherit version src;

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
  ];

  postUnpack = ''
    mkdir -p source/src/external
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (dirName: drv: ''
        echo "Extracting ${dirName}..."
        mkdir -p source/src/external/${dirName}
        tar -xf ${drv} -C source/src/external/${dirName} --strip-components=${
          if dirName == "sqlite" then "2" else "1"
        }
      '') externalDeps
    )}
    substituteInPlace source/src/external/openssl/config \
      --replace-fail 'exec "$THERE/Configure"' 'exec "$(cd "$THERE" && pwd)/Configure"'
    patchShebangs source/src/external/openssl/Configure
    sed -i 's|cp $< $@|cp $< $@ \&\& chmod u+w $@|g' source/src/Makefile
    sed -i 's|cd $(EXTERNAL_AUDIT) && ./autogen.sh && ./configure|cd $(EXTERNAL_AUDIT) \&\& chmod -R u+w . \&\& rm -f INSTALL \&\& ./autogen.sh \&\& ./configure|' source/src/Makefile
    sed -i 's|cp INSTALL.tmp INSTALL|chmod u+w INSTALL 2>/dev/null; cp INSTALL.tmp INSTALL|g' \
      source/src/external/audit-userspace/autogen.sh
    mkdir -p source/src/external/libdb/build_unix
    mkdir -p source/src/external/libbpf-bootstrap/src
    cp ${modernBpfC} source/src/external/libbpf-bootstrap/src/modern.bpf.c
    substituteInPlace source/src/external/libbpf-bootstrap/CMakeLists.txt \
      --replace-fail \
      'file(DOWNLOAD ''${FILE_URL} ''${DEST_PATH})' \
      '# download skipped - file pre-placed by Nix'
    sed -i '/GIT_REPOSITORY https:\/\/github.com\/libbpf\/libbpf.git/d' source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i '/GIT_TAG v1.5.0/d' source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i '/GIT_REPOSITORY https:\/\/github.com\/libbpf\/bpftool.git/d' source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i '/GIT_TAG v7.5.0/d' source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i '/GIT_REPOSITORY https:\/\/github.com\/libbpf\/vmlinux.h.git/d' source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i '/GIT_TAG main/d' source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i 's/-fzero-call-used-regs=used-gpr//g' source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i '/^add_library(modern SHARED src\/modern.bpf.c)/d' \
      source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i '/^target_compile_options(modern PRIVATE/d' \
      source/src/external/libbpf-bootstrap/CMakeLists.txt
    sed -i '/^target_link_libraries(modern modern_skel)/d' \
      source/src/external/libbpf-bootstrap/CMakeLists.txt
    cp -rv ${libbpfSrc}/. source/src/external/libbpf-bootstrap/libbpf/
    cp -rv ${bpftoolSrc}/. source/src/external/libbpf-bootstrap/bpftool/
    chmod -R u+w source/src/external/libbpf-bootstrap/bpftool/
    cp -rv ${libbpfSrc}/. source/src/external/libbpf-bootstrap/bpftool/libbpf/
    cp -rv ${vmlinuxSrc}/. source/src/external/libbpf-bootstrap/vmlinux.h/
    sed -i 's|\''${BPFOBJECT_CLANG_EXE} -g -O2 -target bpf -D__TARGET_ARCH_\''${ARCH}|''${BPFOBJECT_CLANG_EXE} -g -O2 -target bpf -std=gnu11 -D__TARGET_ARCH_''${ARCH}|' \
      source/src/external/libbpf-bootstrap/tools/cmake/FindBpfObject.cmake
    sed -i 's|\''${CLANG_SYSTEM_INCLUDES} -I\''${GENERATED_VMLINUX_DIR}|-I''${GENERATED_VMLINUX_DIR}|' \
      source/src/external/libbpf-bootstrap/tools/cmake/FindBpfObject.cmake
    sed -i 's|cd $(EXTERNAL_LIBBPF) && mkdir -p build && cd build && cmake -DBPFOBJECT_CLANG_EXE=${clang.cc}/bin/clang .. && ''${MAKE}|cd $(EXTERNAL_LIBBPF) \&\& mkdir -p build \&\& cd build \&\& cmake -DBPFOBJECT_CLANG_EXE=${clang.cc}/bin/clang .. \&\& ''${MAKE} VERBOSE=1|' source/src/Makefile
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

    # Replace the rpath wholesale: the build-tree entries it contains are
    # dangling (and rejected by the /build/ reference check), but keep the
    # buildInputs store paths resolvable alongside the bundled libs.
    RPATH="$INST/lib:${
      lib.makeLibraryPath [
        openssl
        zlib
        attr
        stdenv.cc.cc.lib
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
