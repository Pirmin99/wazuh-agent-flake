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
#   Type=oneshot + RemainAfterExit=yes — ExecStart launches all five daemons
#   directly (they self-daemonize), then exits 0.  systemd considers the
#   service active until ExecStop runs.  wazuh-control is intentionally
#   bypassed: its pstatus polling loop is unreliable when daemons are started
#   fresh (no pre-existing PID files) inside a systemd unit.
#
# Socket ownership:
#   wazuh-modulesd starts as root, creates control/upgrade/wmodules sockets,
#   then drops to the wazuh user internally.  After the privilege drop it
#   needs CAP_CHOWN to change socket ownership — without it, bind() fails
#   with EPERM.  CAP_CHOWN is therefore included in the capability sets.

{ config, lib, pkgs, ... }:

let
  cfg = config.services.wazuh-agent;
  pkg = cfg.package;

  ossecConf = pkgs.writeText "ossec.conf" ''
    <ossec_config>

      <!-- ── Manager connection ─────────────────────────────────────── -->
      <client>
        <server>
          <address>${cfg.managerAddress}</address>
          <port>${toString cfg.managerPort}</port>
          <protocol>${cfg.protocol}</protocol>
        </server>
        <notify_time>10</notify_time>
        <time-reconnect>60</time-reconnect>
        <auto_restart>yes</auto_restart>
        <crypto_method>aes</crypto_method>
        <enrollment>
          <enabled>${if cfg.autoEnroll then "yes" else "no"}</enabled>
        </enrollment>
      </client>

      <client_buffer>
        <disabled>no</disabled>
        <queue_size>5000</queue_size>
        <events_per_second>500</events_per_second>
      </client_buffer>

      <!-- ── Logging ────────────────────────────────────────────────── -->
      <logging>
        <log_format>plain</log_format>
      </logging>

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
        <ignore>/etc/adjtime</ignore>
        <ignore>/etc/random-seed</ignore>
      </syscheck>

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
      </wodle>

      <!-- ── Log collection ─────────────────────────────────────────── -->
      <!-- systemd journal — best source on NixOS -->
      <localfile>
        <log_format>journald</log_format>
        <location>journald</location>
      </localfile>

      <!-- ── Active response ────────────────────────────────────────── -->
      <active-response>
        <disabled>no</disabled>
      </active-response>

      <!-- ── Security Configuration Assessment ──────────────────────────── -->
      <sca>
        <enabled>${if cfg.enableSca then "yes" else "no"}</enabled>
        <scan_on_start>yes</scan_on_start>
        <interval>12h</interval>
        <skip_nfs>yes</skip_nfs>
        <policies>
          ${lib.concatMapStrings (p: "<policy>ruleset/sca/${p}</policy>\n    ") cfg.scaPolicies}
        </policies>
      </sca>

      ${cfg.extraConfig}

    </ossec_config>
  '';

in {

  options.services.wazuh-agent = {

    enable = lib.mkEnableOption "Wazuh security agent";

    package = lib.mkOption {
      type        = lib.types.package;
      description = "The wazuh-agent package to use.";
      default     = pkgs.callPackage ../pkgs/wazuh-agent {};
      defaultText = lib.literalExpression "pkgs.callPackage ../pkgs/wazuh-agent {}";
    };

    managerAddress = lib.mkOption {
      type        = lib.types.str;
      description = "IP address or hostname of the Wazuh manager.";
      example     = "192.168.1.100";
    };

    managerPort = lib.mkOption {
      type        = lib.types.port;
      default     = 1514;
      description = "Port the Wazuh manager listens on.";
    };

    protocol = lib.mkOption {
      type        = lib.types.enum [ "tcp" "udp" ];
      default     = "tcp";
      description = "Transport protocol to connect to the manager.";
    };

    enableSyscheck = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = "Enable file integrity monitoring.";
    };

    enableRootcheck = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = "Enable rootkit detection.";
    };

    autoEnroll = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = "Auto-enroll with the manager via the enrollment protocol on first start.";
    };


    enableSca = lib.mkOption {
      type        = lib.types.bool;
      default     = true;
      description = "Enable Security Configuration Assessment.";
    };

    scaPolicies = lib.mkOption {
      type        = lib.types.listOf lib.types.str;
      default     = [ "generic/sca_distro_independent_linux.yml" ];
      description = "List of SCA policy files to evaluate, relative to WAZUH_HOME/ruleset/sca/.";
    };

    extraConfig = lib.mkOption {
      type        = lib.types.lines;
      default     = "";
      description = "Raw XML appended inside <ossec_config> verbatim.";
      example     = ''
        <localfile>
          <log_format>syslog</log_format>
          <location>/var/log/nginx/access.log</location>
        </localfile>
      '';
    };

  };

  config = lib.mkIf cfg.enable {

    users.users.wazuh = {
      isSystemUser = true;
      group        = "wazuh";
      description  = "Wazuh agent daemon user";
      home         = "/var/lib/wazuh-agent";
    };
    users.groups.wazuh = {};

    # Created by systemd-tmpfiles on boot and on nixos-rebuild switch.
    # Layout derived from the reference wazuh/wazuh-agent:4.14.1 Docker image.
    # 0770 for directories daemons write into at runtime; 0750 for the rest.
    systemd.tmpfiles.rules = [
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

    systemd.services.wazuh-agent = {
      description = "Wazuh Security Agent";
      after       = [ "network-online.target" "systemd-journald.service" ];
      wants       = [ "network-online.target" ];
      wantedBy    = [ "multi-user.target" ];

      path = with pkgs; [ coreutils bash procps findutils ];

      serviceConfig = {

        # ── Pre-start: sync config and ensure a clean slate ──────────────
        # Runs as root (+) so it can chown/chmod files owned by wazuh.
        # Executed on every start, so nixos-rebuild switch changes take
        # effect immediately on service restart.
        ExecStartPre = [
          "+${pkgs.writeShellScript "wazuh-agent-setup" ''
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

            # Ruleset: copy once, never overwrite (contains runtime state).
            if [ ! -d /var/lib/wazuh-agent/ruleset ]; then
              cp -r ${pkg}/opt/wazuh-agent/ruleset /var/lib/wazuh-agent/ruleset
              chown -R wazuh:wazuh /var/lib/wazuh-agent/ruleset
            fi

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

            # ── Stop any surviving daemons from a previous cycle ──────────
            # Send SIGTERM and wait up to 10 s for all five to exit so the
            # new daemons can bind their sockets without racing.
            for daemon in wazuh-execd wazuh-agentd wazuh-syscheckd wazuh-logcollector wazuh-modulesd; do
              pkill -x "$daemon" 2>/dev/null || true
            done
            for i in $(seq 1 10); do
              any=0
              for daemon in wazuh-execd wazuh-agentd wazuh-syscheckd wazuh-logcollector wazuh-modulesd; do
                pgrep -x "$daemon" > /dev/null 2>&1 && any=1 && break
              done
              [ $any -eq 0 ] && break
              sleep 1
            done

            # ── Clean up stale runtime state ───────────────────────────────
            rm -f /var/lib/wazuh-agent/var/run/wazuh-*.pid
            # execq is a named pipe; wazuh-execd re-creates it on start.
            rm -f /var/lib/wazuh-agent/queue/alerts/execq
          ''}"
        ];

        # ── Start: launch all five daemons directly ───────────────────────
        # Each binary self-daemonizes (double-fork), so this script exits
        # almost immediately. systemd marks the service active (exited)
        # once the script returns 0, and keeps it active via RemainAfterExit.
        ExecStart = "${pkgs.writeShellScript "wazuh-start" ''
          ${pkg}/opt/wazuh-agent/bin/wazuh-execd
          ${pkg}/opt/wazuh-agent/bin/wazuh-agentd
          ${pkg}/opt/wazuh-agent/bin/wazuh-syscheckd
          ${pkg}/opt/wazuh-agent/bin/wazuh-logcollector
          ${pkg}/opt/wazuh-agent/bin/wazuh-modulesd
        ''}";

        # ── Stop: SIGTERM all daemons and wait for clean exit ─────────────
        ExecStop = "${pkgs.writeShellScript "wazuh-stop" ''
          for daemon in wazuh-modulesd wazuh-logcollector wazuh-syscheckd wazuh-agentd wazuh-execd; do
            pkill -x "$daemon" 2>/dev/null || true
          done
          for i in $(seq 1 10); do
            any=0
            for daemon in wazuh-execd wazuh-agentd wazuh-syscheckd wazuh-logcollector wazuh-modulesd; do
              pgrep -x "$daemon" > /dev/null 2>&1 && any=1 && break
            done
            [ $any -eq 0 ] && break
            sleep 1
          done
        ''}";

        Type             = "oneshot";
        RemainAfterExit  = "yes";
        WorkingDirectory = "/var/lib/wazuh-agent";
        User             = "root";

        # Restart on failure, but not on clean stop.
        Restart    = "on-failure";
        RestartSec = "10s";

        # Point all Wazuh binaries at /var/lib/wazuh-agent instead of the
        # compile-time /var/ossec default.
        Environment = [
          "WAZUH_HOME=/var/lib/wazuh-agent"
          "WAZUH_BINDIR=${pkg}/opt/wazuh-agent/bin"
          "LD_LIBRARY_PATH=${pkgs.systemd}/lib"
        ];

        # CAP_CHOWN is required: wazuh-modulesd creates sockets as root then
        # chowns them to wazuh before dropping privileges and calling bind().
        # Without CAP_CHOWN the chown fails, the socket stays root:root, and
        # bind() returns EPERM after the privilege drop.
        AmbientCapabilities = [
          "CAP_NET_RAW" "CAP_NET_ADMIN" "CAP_SYS_PTRACE"
          "CAP_DAC_READ_SEARCH" "CAP_DAC_OVERRIDE"
          "CAP_SETGID" "CAP_SETUID" "CAP_CHOWN"
        ];
        CapabilityBoundingSet = [
          "CAP_NET_RAW" "CAP_NET_ADMIN" "CAP_SYS_PTRACE"
          "CAP_DAC_READ_SEARCH" "CAP_DAC_OVERRIDE"
          "CAP_SETGID" "CAP_SETUID" "CAP_CHOWN"
        ];
      };
    };

    # Make wazuh-control and agent-auth available system-wide.
    environment.systemPackages = [ pkg ];

  };
}
