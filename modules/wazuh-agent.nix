# modules/wazuh-agent.nix
#
# NixOS module for the Wazuh agent.
#
# Runtime state layout (nothing outside this path):
#   /var/lib/wazuh-agent/   — persistent state: logs, queue, client.keys,
#                              ossec.conf, databases, PID files, sockets
#
# The Nix store holds binaries, rulesets, and default templates (read-only).
#
# Service design:
#   wazuh-agent.target groups one unit per daemon.  Each daemon runs in the
#   foreground (-f) as a Type=simple service, so systemd supervises it
#   directly: crashes are noticed and restarted, stop kills the cgroup, and
#   no pkill/pgrep machinery is needed.  wazuh-agent-setup.service prepares
#   /var/lib/wazuh-agent (config, rulesets, symlinks) before any daemon
#   starts and re-runs on nixos-rebuild switch.
#
# Socket ownership:
#   wazuh-modulesd starts as root, creates control/upgrade/wmodules sockets,
#   then drops to the wazuh user internally.  After the privilege drop it
#   needs CAP_CHOWN to change socket ownership — without it, bind() fails
#   with EPERM.  CAP_CHOWN is therefore included in the capability sets.

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.wazuh-agent;
  pkg = cfg.package;

  managerServers =
    if cfg.managerAddresses != [ ] then
      cfg.managerAddresses
    else
      lib.optional (cfg.managerAddress != null) cfg.managerAddress;

  enrollmentEnabled = cfg.autoEnroll || cfg.enrollmentPasswordFile != null;

  ossecConf = pkgs.writeText "ossec.conf" ''
    <ossec_config>

      <!-- ── Manager connection ─────────────────────────────────────── -->
      <client>
        ${lib.concatMapStrings (addr: ''
          <server>
            <address>${addr}</address>
            <port>${toString cfg.managerPort}</port>
            <protocol>${cfg.protocol}</protocol>
          </server>
        '') managerServers}
        <notify_time>10</notify_time>
        <time-reconnect>60</time-reconnect>
        <auto_restart>yes</auto_restart>
        <crypto_method>aes</crypto_method>
        <enrollment>
          <enabled>${if enrollmentEnabled then "yes" else "no"}</enabled>
          ${lib.optionalString (
            cfg.enrollmentPasswordFile != null
          ) "<authorization_pass_path>etc/authd.pass</authorization_pass_path>"}
        </enrollment>
      </client>

      <client_buffer>
        <disabled>no</disabled>
        <queue_size>5000</queue_size>
        <events_per_second>500</events_per_second>
      </client_buffer>

      <!-- ── Rootkit detection ───────────────────────────────────────── -->
      <rootcheck>
        <disabled>${if cfg.enableRootcheck then "no" else "yes"}</disabled>
        <frequency>43200</frequency>
        <skip_nfs>yes</skip_nfs>
      </rootcheck>

      <!-- ── System inventory ───────────────────────────────────────── -->
      <wodle name="syscollector">
        <disabled>no</disabled>
        <interval>1h</interval>
        <scan_on_start>yes</scan_on_start>
        <hardware>yes</hardware>
        <os>yes</os>
        <network>yes</network>
        <packages>yes</packages>
        <ports all="no">yes</ports>
        <processes>yes</processes>
        <synchronization>
          <enabled>yes</enabled>
          <interval>5m</interval>
          <max_eps>50</max_eps>
          <integrity_interval>24h</integrity_interval>
        </synchronization>
      </wodle>

      <!-- ── File integrity monitoring ──────────────────────────────── -->
      <syscheck>
        <disabled>${if cfg.enableSyscheck then "no" else "yes"}</disabled>
        <frequency>43200</frequency>
        <scan_on_start>yes</scan_on_start>
        <directories>/etc,/usr/bin,/usr/sbin</directories>
        <directories>/bin,/sbin,/boot</directories>
        <!-- NixOS-specific: watch the live system profile -->
        <directories>/run/current-system</directories>
        <ignore>/etc/mtab</ignore>
        <ignore>/etc/hosts.deny</ignore>
        <ignore>/etc/mail/statistics</ignore>
        <ignore>/etc/random-seed</ignore>
        <ignore>/etc/random.seed</ignore>
        <ignore>/etc/adjtime</ignore>
        <ignore>/etc/httpd/logs</ignore>
        <ignore>/etc/utmpx</ignore>
        <ignore>/etc/wtmpx</ignore>
        <ignore>/etc/cups/certs</ignore>
        <ignore>/etc/dumpdates</ignore>
        <ignore>/etc/svc/volatile</ignore>
        <ignore>/sys/kernel/security</ignore>
        <ignore>/sys/kernel/debug</ignore>
        <ignore type="sregex">.log$|.swp$</ignore>
        <nodiff>/etc/ssl/private.key</nodiff>
        <skip_nfs>yes</skip_nfs>
        <skip_dev>yes</skip_dev>
        <skip_proc>yes</skip_proc>
        <skip_sys>yes</skip_sys>
        <process_priority>10</process_priority>
        <max_eps>50</max_eps>
        <synchronization>
          <enabled>yes</enabled>
          <interval>5m</interval>
          <max_eps>50</max_eps>
          <integrity_interval>24h</integrity_interval>
        </synchronization>
      </syscheck>

      <!-- ── Log collection ─────────────────────────────────────────── -->
      <localfile>
        <log_format>syslog</log_format>
        <location>logs/active-responses.log</location>
      </localfile>
      <!-- systemd journal — best source on NixOS -->
      <localfile>
        <log_format>journald</log_format>
        <location>journald</location>
      </localfile>
      <localfile>
        <log_format>command</log_format>
        <command>df -P</command>
        <frequency>360</frequency>
      </localfile>
      <localfile>
        <log_format>full_command</log_format>
        <command>netstat -tan |grep LISTEN |grep -v 127.0.0.1 | sort</command>
        <frequency>360</frequency>
      </localfile>
      <localfile>
        <log_format>full_command</log_format>
        <command>last -n 5</command>
        <frequency>360</frequency>
      </localfile>

      <!-- ── Active response ────────────────────────────────────────── -->
      <active-response>
        <disabled>no</disabled>
      </active-response>

      <!-- ── Security Configuration Assessment ─────────────────────── -->
      <sca>
        <enabled>${if cfg.enableSca then "yes" else "no"}</enabled>
        <scan_on_start>yes</scan_on_start>
        <interval>12h</interval>
        <skip_nfs>yes</skip_nfs>
        <policies>
          ${lib.concatMapStrings (p: "<policy>ruleset/sca/${p}</policy>\n          ") cfg.scaPolicies}
        </policies>
      </sca>

      ${cfg.extraConfig}

    </ossec_config>
  '';

  # The daemons drop privileges themselves; the sets below are what they need
  # after the drop.  Kept identical across daemons for simplicity.
  capabilities = [
    "CAP_NET_RAW"
    "CAP_NET_ADMIN"
    "CAP_SYS_PTRACE"
    "CAP_DAC_READ_SEARCH"
    "CAP_DAC_OVERRIDE"
    "CAP_SETGID"
    "CAP_SETUID"
    "CAP_CHOWN"
  ];

  environment = [
    # Point all Wazuh binaries at /var/lib/wazuh-agent instead of the
    # compile-time /var/ossec default.
    "WAZUH_HOME=/var/lib/wazuh-agent"
    "WAZUH_BINDIR=${pkg}/opt/wazuh-agent/bin"
    # logcollector dlopens libsystemd for the journald log format.
    "LD_LIBRARY_PATH=${pkgs.systemd}/lib"
  ];

  # PATH for the daemons: active-response scripts (execd) and the command/
  # full_command localfiles above (df, netstat, last) run external tools.
  daemonPath = with pkgs; [
    coreutils
    bash
    procps
    findutils
    nettools
    util-linux
  ];

  # Start order mirrors wazuh-control: execd, agentd, syscheckd,
  # logcollector, modulesd.  Ordering only (After=), no Requires= between
  # daemons, so one crashing never takes the others down.
  daemons = {
    wazuh-execd = {
      description = "Wazuh Agent Active Response Daemon";
      after = [ ];
    };
    wazuh-agentd = {
      description = "Wazuh Agent Manager Connection Daemon";
      after = [
        "wazuh-execd.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
    };
    wazuh-syscheckd = {
      description = "Wazuh Agent File Integrity Monitoring Daemon";
      after = [ "wazuh-agentd.service" ];
    };
    wazuh-logcollector = {
      description = "Wazuh Agent Log Collection Daemon";
      after = [
        "wazuh-agentd.service"
        "systemd-journald.service"
      ];
    };
    wazuh-modulesd = {
      description = "Wazuh Agent Modules Daemon";
      after = [ "wazuh-agentd.service" ];
    };
  };

  mkDaemonService = name: daemon: {
    inherit (daemon) description;
    after = [ "wazuh-agent-setup.service" ] ++ daemon.after;
    requires = [ "wazuh-agent-setup.service" ];
    wants = daemon.wants or [ ];
    partOf = [ "wazuh-agent.target" ];
    wantedBy = [ "wazuh-agent.target" ];
    path = daemonPath;

    # Restart on nixos-rebuild switch when the generated config changes,
    # not only when the unit file itself does.
    restartTriggers = [ ossecConf ];

    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkg}/opt/wazuh-agent/bin/${name} -f";
      WorkingDirectory = "/var/lib/wazuh-agent";
      User = "root";
      Restart = "on-failure";
      RestartSec = "10s";
      Environment = environment;
      AmbientCapabilities = capabilities;
      CapabilityBoundingSet = capabilities;
    };
  };

in
{

  options.services.wazuh-agent = {

    enable = lib.mkEnableOption "Wazuh security agent";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The wazuh-agent package to use.";
      default = pkgs.callPackage ../pkgs/wazuh-agent { };
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/wazuh-agent {}";
    };

    managerAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "IP address or hostname of the Wazuh manager. Shorthand for a single-element managerAddresses.";
      example = "192.168.1.100";
    };

    managerAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "IP addresses or hostnames of Wazuh managers, tried in order (failover). Takes precedence over managerAddress.";
      example = [
        "wazuh1.example.org"
        "wazuh2.example.org"
      ];
    };

    managerPort = lib.mkOption {
      type = lib.types.port;
      default = 1514;
      description = "Port the Wazuh manager listens on.";
    };

    protocol = lib.mkOption {
      type = lib.types.enum [
        "tcp"
        "udp"
      ];
      default = "tcp";
      description = "Transport protocol to connect to the manager.";
    };

    enableSyscheck = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable file integrity monitoring.";
    };

    enableRootcheck = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable rootkit detection.";
    };

    autoEnroll = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Auto-enroll with the manager via the enrollment protocol on first start. Implied by enrollmentPasswordFile.";
    };

    enrollmentPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File containing the enrollment (authd) password. Copied to
        WAZUH_HOME/etc/authd.pass on service start and used by wazuh-agentd
        to enroll itself when no client.keys exists yet. Setting this enables
        enrollment. Use a runtime path (e.g. from agenix/sops-nix), not a
        path literal — literals are copied into the world-readable Nix store.
      '';
      example = "/run/secrets/wazuh-enrollment-password";
    };

    enableSca = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Security Configuration Assessment.";
    };

    scaPolicies = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "generic/sca_distro_independent_linux.yml" ];
      description = "List of SCA policy files to evaluate, relative to WAZUH_HOME/ruleset/sca/.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Raw XML appended inside <ossec_config> verbatim.";
      example = ''
        <localfile>
          <log_format>syslog</log_format>
          <location>/var/log/nginx/access.log</location>
        </localfile>
      '';
    };

  };

  config = lib.mkIf cfg.enable {

    assertions = [
      {
        assertion = managerServers != [ ];
        message = "services.wazuh-agent: set managerAddress or managerAddresses.";
      }
    ];

    users.users.wazuh = {
      isSystemUser = true;
      group = "wazuh";
      description = "Wazuh agent daemon user";
      home = "/var/lib/wazuh-agent";
    };
    users.groups.wazuh = { };

    systemd = {

      # Created by systemd-tmpfiles on boot and on nixos-rebuild switch.
      # Layout derived from the reference wazuh/wazuh-agent:4.14.1 Docker image.
      # 0770 for directories daemons write into at runtime; 0750 for the rest.
      tmpfiles.rules = [
        "d /var/lib/wazuh-agent                         0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/etc                     0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/logs                    0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/logs/wazuh              0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/tmp                     0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/backup                  0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/agentless               0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/active-response         0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/active-response/bin     0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/queue                   0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/queue/alerts            0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/queue/diff              0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/queue/fim               0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/queue/fim/db            0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/queue/logcollector      0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/queue/rids              0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/queue/sockets           0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/queue/syscollector      0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/queue/syscollector/db   0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/queue/db                0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/var                     0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/var/run                 0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/var/incoming            0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/var/upgrade             0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/var/wodles              0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/var/selinux             0770 wazuh wazuh -"
        "d /var/lib/wazuh-agent/wodles                  0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/ruleset                 0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/ruleset/decoders        0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/ruleset/rules           0750 wazuh wazuh -"
        "d /var/lib/wazuh-agent/ruleset/sca             0750 wazuh wazuh -"
      ];

      targets.wazuh-agent = {
        description = "Wazuh Security Agent";
        wantedBy = [ "multi-user.target" ];
      };

      services = {

        # ── Setup: sync config into /var/lib/wazuh-agent ───────────────────
        # Runs as root before any daemon; re-runs on every start and on
        # nixos-rebuild switch, so config changes take effect immediately.
        wazuh-agent-setup = {
          description = "Wazuh Security Agent setup";
          partOf = [ "wazuh-agent.target" ];
          wantedBy = [ "wazuh-agent.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "wazuh-agent-setup" ''
              # ── Config files ───────────────────────────────────────────────
              install -m 0640 -o wazuh -g wazuh \
                ${ossecConf} /var/lib/wazuh-agent/etc/ossec.conf
              install -m 0640 -o wazuh -g wazuh \
                ${pkg}/opt/wazuh-agent/etc/internal_options.conf \
                /var/lib/wazuh-agent/etc/internal_options.conf

              # Create empty client.keys on first run; preserved on restarts
              # so enrollment survives a service restart.
              if [ ! -f /var/lib/wazuh-agent/etc/client.keys ]; then
                install -m 0640 -o wazuh -g wazuh /dev/null \
                  /var/lib/wazuh-agent/etc/client.keys
              fi

              ${
                if cfg.enrollmentPasswordFile != null then
                  ''
                    install -m 0640 -o wazuh -g wazuh \
                      ${cfg.enrollmentPasswordFile} /var/lib/wazuh-agent/etc/authd.pass
                  ''
                else
                  ''
                    rm -f /var/lib/wazuh-agent/etc/authd.pass
                  ''
              }

              # Ruleset: copy each subdirectory individually so new ones are added on upgrade.
              for subdir in decoders rules sca; do
                if [ ! -d /var/lib/wazuh-agent/ruleset/$subdir ]; then
                  cp -r ${pkg}/opt/wazuh-agent/ruleset/$subdir /var/lib/wazuh-agent/ruleset/$subdir
                  chown -R wazuh:wazuh /var/lib/wazuh-agent/ruleset/$subdir
                fi
              done

              # etc/shared: copy once, then ensure it stays writable.
              # wazuh-agentd writes merged.mg here (pushed by the manager).
              if [ ! -d /var/lib/wazuh-agent/etc/shared ]; then
                cp -r ${pkg}/opt/wazuh-agent/etc/shared /var/lib/wazuh-agent/etc/shared
              fi
              chown -R wazuh:wazuh /var/lib/wazuh-agent/etc/shared
              chmod -R u+w         /var/lib/wazuh-agent/etc/shared

              # ── bin/ symlinks ──────────────────────────────────────────────
              # wazuh-execd resolves $WAZUH_HOME/bin/wazuh-control via execve()
              # rather than $WAZUH_BINDIR. Symlink every store binary into the
              # writable bin/ so that lookup always succeeds.
              mkdir -p /var/lib/wazuh-agent/bin
              for bin in ${pkg}/opt/wazuh-agent/bin/*; do
                ln -sf "$bin" /var/lib/wazuh-agent/bin/$(basename "$bin")
              done

              # ── Clean up stale runtime state ───────────────────────────────
              rm -f /var/lib/wazuh-agent/var/run/wazuh-*.pid
              # execq is a named pipe; wazuh-execd re-creates it on start.
              rm -f /var/lib/wazuh-agent/queue/alerts/execq
            '';
          };
        };

      }
      // lib.mapAttrs mkDaemonService daemons;

    };

    # Make wazuh-control and agent-auth available system-wide.
    environment.systemPackages = [ pkg ];

  };
}
