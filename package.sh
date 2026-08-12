#!/usr/bin/env bash
set -euo pipefail

UPSTREAM_REPO="fatedier/frp"
TAG="${1:?upstream tag is required}"
UPSTREAM_VERSION="${2:?upstream version is required}"
VERSION="${3:-${UPSTREAM_VERSION}}"
ARCH="${4:?Debian architecture is required}"
UPSTREAM_ARCH="${5:?upstream architecture is required}"
PACKAGE="$(awk '/^Package:/ { print $2; exit }' debian/control)"

write_control() {
  local arch="$1"
  local target="$2"
  awk -v version="${VERSION}" -v arch="${arch}" '
    /^Package:/ {
      print
      print "Version: " version
      print "Architecture: " arch
      next
    }
    { print }
  ' debian/control > "${target}"
}

rm -rf work dist
mkdir -p work dist

asset="frp_${UPSTREAM_VERSION}_linux_${UPSTREAM_ARCH}.tar.gz"
archive="work/${asset}"
extract_dir="work/extract-${ARCH}"
package_root="work/pkg-${ARCH}"

gh release download "${TAG}" --repo "${UPSTREAM_REPO}" --pattern "${asset}" --dir work --clobber
mkdir -p "${extract_dir}" "${package_root}/DEBIAN" "${package_root}/usr/bin"
tar -xzf "${archive}" -C "${extract_dir}"

frpc_bin="$(find "${extract_dir}" -type f -name frpc -print -quit)"
frps_bin="$(find "${extract_dir}" -type f -name frps -print -quit)"
frpc_config="$(find "${extract_dir}" -type f -name frpc.toml -print -quit)"
frps_config="$(find "${extract_dir}" -type f -name frps.toml -print -quit)"
test -n "${frpc_bin}"
test -n "${frps_bin}"
test -n "${frpc_config}"
test -n "${frps_config}"
install -m 0755 "${frpc_bin}" "${package_root}/usr/bin/frpc"
install -m 0755 "${frps_bin}" "${package_root}/usr/bin/frps"

# System-wide configuration belongs under /etc and must be preserved by
# dpkg across upgrades. Keep the upstream defaults as the initial conffiles.
install -d -m 0755 "${package_root}/etc/frp"
install -m 0644 "${frpc_config}" "${package_root}/etc/frp/frpc.toml"
install -m 0644 "${frps_config}" "${package_root}/etc/frp/frps.toml"
cat > "${package_root}/DEBIAN/conffiles" <<'EOF'
/etc/frp/frpc.toml
/etc/frp/frps.toml
EOF

# Vendor unit files belong under /usr/lib/systemd/system. Both units are
# intentionally shipped disabled: installing frp must not unexpectedly
# start a client or expose a server port before the administrator edits the
# corresponding configuration file.
install -d -m 0755 "${package_root}/usr/lib/systemd/system"
cat > "${package_root}/usr/lib/systemd/system/frpc.service" <<'EOF'
[Unit]
Description=frp client
Documentation=https://gofrp.org/
Wants=network-online.target
After=network-online.target
ConditionPathExists=/etc/frp/frpc.toml

[Service]
Type=simple
ExecStart=/usr/bin/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

cat > "${package_root}/usr/lib/systemd/system/frps.service" <<'EOF'
[Unit]
Description=frp server
Documentation=https://gofrp.org/
Wants=network-online.target
After=network-online.target
ConditionPathExists=/etc/frp/frps.toml

[Service]
Type=simple
ExecStart=/usr/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# Refresh systemd's unit cache on install/upgrade/removal when systemd is
# actually running, without making systemd a hard dependency of the package.
cat > "${package_root}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --system daemon-reload >/dev/null || true
    # Preserve the administrator's enablement choice. Only restart units that
    # were already running before an upgrade; never start either unit merely
    # because the package was installed.
    for unit in frpc.service frps.service; do
        if systemctl --system --quiet is-active "$unit"; then
            systemctl --system try-restart "$unit" >/dev/null || true
        fi
    done
fi
exit 0
EOF
chmod 0755 "${package_root}/DEBIAN/postinst"

cat > "${package_root}/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    # A manually enabled service must not survive package removal as a running
    # process or leave a dangling Wants= symlink behind.
    systemctl --system disable --now frpc.service frps.service >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "${package_root}/DEBIAN/prerm"

cat > "${package_root}/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --system daemon-reload >/dev/null || true
fi
exit 0
EOF
chmod 0755 "${package_root}/DEBIAN/postrm"

write_control "${ARCH}" "${package_root}/DEBIAN/control"

dpkg-deb --build --root-owner-group "${package_root}" "dist/${PACKAGE}_${VERSION}_${ARCH}.deb"

for deb in dist/*.deb; do
  dpkg-deb --info "${deb}" >/dev/null
  contents="$(dpkg-deb --contents "${deb}")"
  grep -q './etc/frp/frpc.toml' <<<"${contents}"
  grep -q './etc/frp/frps.toml' <<<"${contents}"
  grep -q './usr/lib/systemd/system/frpc.service' <<<"${contents}"
  grep -q './usr/lib/systemd/system/frps.service' <<<"${contents}"
done
