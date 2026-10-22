# Dockerfile (Minimal)
# Stage 1: Build and customize the rootfs for development (Minimal - Fedora)
ARG TARGETPLATFORM
FROM fedora:latest AS customizer

# Update base system
RUN dnf -y update && dnf clean all

# Copy custom scripts first
# Copy our bashrc script to the rootfs
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh

# Make scripts executable
RUN chmod +x /etc/profile.d/ds-aliases.sh

# Install Minimal package set
RUN dnf -y update && \
    dnf -y install \
    # Core utilities
    bash \
    dialog \
    coreutils \
    file \
    findutils \
    grep \
    sed \
    gawk \
    curl \
    wget \
    ca-certificates \
    glibc-langpack-en \
    bash-completion \
    systemd-udev \
    dbus \
    systemd \
    systemd-resolved \
    systemd-networkd \
    which \
    tar \
    gzip \
    xz \
    # Basic tools
    git \
    nano \
    sudo \
    shadow-utils \
    util-linux \
    # Networking & SSH
    openssh-server \
    net-tools \
    iptables \
    iptables-legacy \
    iputils \
    iproute \
    bind-utils \
    # Logging & Rotation
    logrotate \
    # Procps for system monitoring
    procps-ng \
    # Essential kernel module support
    kmod \
    && dnf clean all

# Configure iptables-legacy (MANDATORY for Android compatibility)
RUN if command -v update-alternatives >/dev/null 2>&1 && [ -x /usr/sbin/iptables-legacy ]; then \
        update-alternatives --set iptables /usr/sbin/iptables-legacy || true; \
    fi && \
    if command -v update-alternatives >/dev/null 2>&1 && [ -x /usr/sbin/ip6tables-legacy ]; then \
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true; \
    fi

# Configure locales, environment, SSH, and user setup
RUN echo "LANG=en_US.UTF-8" > /etc/locale.conf && \
    # Configure SSH (Disable Root Login)
    mkdir -p /var/run/sshd && \
    ssh-keygen -A || true && \
    sed -i 's/^#*PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config || true && \
    sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true && \
    # Remove default user if it exists
    userdel -r fedora 2>/dev/null || true

# Fix DHCP in the container
RUN mkdir -p /etc/systemd/network && \
    cat <<'EOF' > /etc/systemd/network/10-eth-dhcp.network
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

# Apply Android compatibility fixes (Systemd and Udev)
RUN <<EOF_RUN

# --- 1. General Fixes ---
# Android network group setup (required for socket access on Android kernels)
grep -q '^aid_inet:' /etc/group    || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# Root permissions for Android hardware access
usermod -a -G aid_inet,aid_net_raw,input,video,tty root || true

# --- 2. Systemd-Specific Fixes ---
# Mask problematic services for Android kernels
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket

# Journald configuration (skip Audit, KMsg, etc)
cat >> /etc/systemd/journald.conf << 'EOT'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
EOT

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ds-logging.conf << 'EOT'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOT

# Enable essential services
mkdir -p /etc/systemd/system/multi-user.target.wants
if [ -d /usr/lib/systemd/system ]; then
    GUEST_SYSTEMD_PATH="/usr/lib/systemd/system"
else
    GUEST_SYSTEMD_PATH="/lib/systemd/system"
fi
for service in dbus.service dbus-broker.service systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
        ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
    fi
done

# Disable power button handling in systemd-logind
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOF

# Apply udev overrides
# 1. Trigger override (Prevents coldplugging Android hardware)
mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

# 2. Read-only path overrides to prevent failures
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

# Keep network services out of host and none modes; every mode with its own
# network needs a DHCP client, so list the modes to skip, not the ones to run in
# Prevents cellular network breakage when running in host network mode
for unit in NetworkManager.service dhcpcd.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -q '^net_mode=' /run/droidspaces/container.config && ! grep -qE '^net_mode=(host|none)$' /run/droidspaces/container.config"
EOF
    fi
done

# Configure logrotate for Android
if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

# Mark fixes as completed
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# Copy binfmt scripts
COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/
COPY scripts/binfmt/qemu-binfmt-register.service /etc/systemd/system/
RUN chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
    chmod 644 /etc/systemd/system/qemu-binfmt-register.service && \
    ln -sf /etc/systemd/system/qemu-binfmt-register.service /etc/systemd/system/multi-user.target.wants/qemu-binfmt-register.service

# Install qemu-user-static and final cleanup
RUN dnf -y install qemu-user-static && \
    dnf clean all && \
    rm -rf /var/cache/dnf /var/cache/dnf5 /tmp/* /var/tmp/*

# Stage 2: Export to scratch for extraction
FROM scratch AS export
LABEL droidspaces.name="Fedora Linux - Minimal" \
      droidspaces.distro="Fedora" \
      droidspaces.description="Minimal Fedora rootfs with basic packages." \
      droidspaces.author="Droidspaces developers"

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
