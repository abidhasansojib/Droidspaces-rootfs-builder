# Fedora-Minimal.Dockerfile
# Stage 1: Build and customize Fedora rootfs for Droidspaces (Minimal)

ARG TARGETPLATFORM
FROM --platform=$TARGETPLATFORM fedora:latest AS customizer

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Copy custom profile script
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh
RUN chmod +x /etc/profile.d/ds-aliases.sh

# Update system and install minimal packages
RUN dnf -y update && \
    dnf -y install \
      systemd \
      systemd-udev \
      systemd-resolved \
      systemd-networkd \
      shadow-utils \
      util-linux \
      coreutils \
      findutils \
      grep \
      sed \
      gawk \
      file \
      which \
      tar \
      gzip \
      xz \
      bash \
      bash-completion \
      nano \
      sudo \
      iproute \
      iputils \
      net-tools \
      bind-utils \
      curl \
      wget \
      ca-certificates \
      openssh-server \
      iptables-legacy \
      glibc-langpack-en \
      procps-ng \
      kmod \
      dbus \
      dialog && \
    dnf clean all

# Configure iptables-legacy (mandatory for Android kernel compatibility)
RUN if command -v update-alternatives >/dev/null 2>&1 && [ -x /usr/sbin/iptables-legacy ]; then \
        update-alternatives --set iptables /usr/sbin/iptables-legacy || true; \
    fi && \
    if command -v update-alternatives >/dev/null 2>&1 && [ -x /usr/sbin/ip6tables-legacy ]; then \
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true; \
    fi

# Configure locale and SSH
RUN echo "LANG=en_US.UTF-8" > /etc/locale.conf && \
    mkdir -p /var/run/sshd && \
    ssh-keygen -A || true && \
    sed -i 's/^#*PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config || true && \
    sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true

# Droidspaces NAT DHCP profile
RUN mkdir -p /etc/systemd/network && \
    cat > /etc/systemd/network/20-eth0.network <<'EOF'
[Match]
Name=eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseDomains=yes
RouteMetric=100
EOF

# Droidspaces / Android compatibility fixes
RUN <<'EOF_RUN'
set -e

# Android network groups (required for socket access on Android kernels)
grep -q '^aid_inet:' /etc/group || echo 'aid_inet:x:3003:' >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# Root permissions for Android hardware/network access
usermod -a -G aid_inet,aid_net_raw,input,video,tty root || true

# Mask problematic services for Android kernels
mkdir -p /etc/systemd/system
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket

# Journald configuration (skip Audit, KMsg, volatile storage)
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ds-logging.conf <<'EOF'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOF

# Find systemd unit directory
if [ -d /usr/lib/systemd/system ]; then
    GUEST_SYSTEMD_PATH=/usr/lib/systemd/system
else
    GUEST_SYSTEMD_PATH=/lib/systemd/system
fi

# Enable essential services only if present
mkdir -p /etc/systemd/system/multi-user.target.wants
for service in dbus.service dbus-broker.service systemd-udevd.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
        ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
    fi
done

# Disable power-button handling in logind
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf <<'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOF

# Restrict udev trigger to safe subsystems (prevents coldplugging Android hardware)
mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

# Remove read-write path conditions that fail in container environments
for unit in \
    systemd-udevd.service \
    systemd-udev-trigger.service \
    systemd-udev-settle.service \
    systemd-udevd-kernel.socket \
    systemd-udevd-control.socket
do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

# Keep network daemons out of host and none modes
for unit in NetworkManager.service dhcpcd.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -e "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf" <<'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -q '^net_mode=' /run/droidspaces/container.config && ! grep -qE '^net_mode=(host|none)$' /run/droidspaces/container.config"
EOF
    fi
done

# Mark fixes as completed
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# Cleanup cache and temporary files
RUN dnf clean all && \
    rm -rf /var/cache/dnf /var/cache/dnf5 /tmp/* /var/tmp/* || true

# Stage 2: Export to scratch for extraction
FROM scratch AS export
LABEL droidspaces.name="Fedora - Minimal" \
      droidspaces.distro="Fedora" \
      droidspaces.description="Minimal Fedora rootfs with basic packages." \
      droidspaces.author="Droidspaces developers"

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
