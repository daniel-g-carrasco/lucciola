# xdg-desktop-portal-luminous, packaged by Lucciola from a pinned upstream tag.
#
# The RemoteDesktop portal backend for niri: mouse and keyboard from the
# phone (KDE Connect's remote input goes through the RemoteDesktop portal
# and libei), and anything else that asks the portal to move the pointer or
# type. niri implements no org.gnome.Mutter.RemoteDesktop, so the GNOME
# backend answers with no device at all under niri; luminous (waycrate's
# backend for wlroots-style compositors, in Rust) serves it through the
# virtual pointer and keyboard protocols niri exposes. Not in Fedora. Built
# by lucciola/luminous/build-rpm.sh in the Containerfile's luminous-rpm
# stage, installed by lucciola/build.sh; its portals.conf line sends only
# RemoteDesktop to it (the GNOME backend keeps the rest).
#
# The version comes from the build (--define "luminous_version X.Y.Z"); the
# source tarball's sha256 is checked by build-rpm.sh before rpmbuild runs.
# The crates come from crates.io at the versions and checksums Cargo.lock
# pins (--locked); a changed crate stops the build.
# The binary is stripped by the build (RUSTFLAGS): no debuginfo subpackage,
# which rpmbuild would otherwise fail on as empty.
%global debug_package %{nil}

Name:           xdg-desktop-portal-luminous
Version:        %{luminous_version}
Release:        1%{?dist}
Summary:        xdg-desktop-portal backend for wlroots-style compositors (RemoteDesktop under niri)
License:        MIT
URL:            https://github.com/waycrate/xdg-desktop-portal-luminous
Source0:        %{url}/archive/refs/tags/v%{version}.tar.gz
# The pkg-config names the tag's -sys crates probe for (glib, gobject, gio,
# pango, pangocairo with cairo-gobject, pipewire and spa, wayland client,
# cursor, egl and server, drm, gbm), clang for the bindgen ones.
BuildRequires:  cargo
BuildRequires:  rust
BuildRequires:  gcc
BuildRequires:  clang
BuildRequires:  pkgconfig
BuildRequires:  pkgconfig(libpipewire-0.3)
BuildRequires:  pkgconfig(cairo)
BuildRequires:  pkgconfig(egl)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(xkbcommon)
BuildRequires:  pkgconfig(fontconfig)
BuildRequires:  pkgconfig(freetype2)
BuildRequires:  pkgconfig(pango)
BuildRequires:  pkgconfig(pangocairo)
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  pkgconfig(gio-2.0)
BuildRequires:  pkgconfig(libdrm)
BuildRequires:  pkgconfig(gbm)
BuildRequires:  pkgconfig(cairo-gobject)
BuildRequires:  pkgconfig(gobject-2.0)
BuildRequires:  pkgconfig(wayland-cursor)
BuildRequires:  pkgconfig(wayland-egl)
BuildRequires:  pkgconfig(wayland-server)
Requires:       xdg-desktop-portal
Requires:       pipewire-libs

%description
A backend for xdg-desktop-portal that serves Screenshot, ScreenCast,
RemoteDesktop, InputCapture, Settings, Access, Background and Clipboard on
wlroots-style Wayland compositors. Lucciola uses its RemoteDesktop for
niri, where the GNOME backend has nothing to offer.

%prep
%autosetup -n xdg-desktop-portal-luminous-%{version}

%build
export CARGO_HOME=%{_builddir}/cargo-home
export RUSTFLAGS="--remap-path-prefix=%{_builddir}=/builddir -Cstrip=symbols"
cargo build --release --locked

%install
install -D -m 0755 target/release/xdg-desktop-portal-luminous %{buildroot}%{_libexecdir}/xdg-desktop-portal-luminous
install -D -m 0644 misc/luminous.portal %{buildroot}%{_datadir}/xdg-desktop-portal/portals/luminous.portal
install -d %{buildroot}%{_datadir}/dbus-1/services %{buildroot}%{_userunitdir}
sed 's|@xdg_install_dir@|%{_libexecdir}|' misc/org.freedesktop.impl.portal.desktop.luminous.service.in \
  > %{buildroot}%{_datadir}/dbus-1/services/org.freedesktop.impl.portal.desktop.luminous.service
sed 's|@xdg_install_dir@|%{_libexecdir}|' misc/xdg-desktop-portal-luminous.service.in \
  > %{buildroot}%{_userunitdir}/xdg-desktop-portal-luminous.service

%files
%license LICENSE
%doc README.md
%{_libexecdir}/xdg-desktop-portal-luminous
%{_datadir}/xdg-desktop-portal/portals/luminous.portal
%{_datadir}/dbus-1/services/org.freedesktop.impl.portal.desktop.luminous.service
%{_userunitdir}/xdg-desktop-portal-luminous.service

%changelog
* Fri Oct 23 2026 Daniel Grasso Carrasco <code@danielgrasso.com> - %{luminous_version}-1
- Built from the upstream tag for the Lucciola image: RemoteDesktop under niri
