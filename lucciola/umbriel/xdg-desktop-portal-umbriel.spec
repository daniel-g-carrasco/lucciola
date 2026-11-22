# xdg-desktop-portal-umbriel, packaged by Lucciola from a pinned upstream
# commit: Umbriel's portal backend (ScreenCast, Screenshot, GlobalShortcuts,
# InputCapture) and its share picker. Built next to Umbriel in the
# Containerfile's umbriel-rpm stage; Lucciola's umbriel-portals.conf sends
# those interfaces to it, and the rest to the GNOME and GTK backends.

Name:           xdg-desktop-portal-umbriel
Version:        0.1.0
Release:        0.1.git%{portal_short}%{?dist}
Summary:        xdg-desktop-portal backend for the Umbriel compositor
License:        MIT
URL:            https://github.com/noctalia-dev/xdg-desktop-portal-umbriel
Source0:        %{url}/archive/%{portal_commit}.tar.gz

BuildRequires:  gcc-c++
BuildRequires:  meson
BuildRequires:  pkgconfig(sdbus-c++)
BuildRequires:  pkgconfig(libpipewire-0.3)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-server)
BuildRequires:  pkgconfig(wayland-protocols)
BuildRequires:  pkgconfig(wayland-egl)
BuildRequires:  pkgconfig(libdrm)
BuildRequires:  pkgconfig(gbm)
BuildRequires:  pkgconfig(cairo)
BuildRequires:  pkgconfig(cairo-ft)
BuildRequires:  pkgconfig(tomlplusplus)
BuildRequires:  pkgconfig(nlohmann_json)
BuildRequires:  pkgconfig(egl)
BuildRequires:  pkgconfig(glesv2)
BuildRequires:  pkgconfig(freetype2)
BuildRequires:  pkgconfig(fontconfig)
BuildRequires:  pkgconfig(pango)
BuildRequires:  pkgconfig(harfbuzz)
BuildRequires:  pkgconfig(xkbcommon)
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  stb_image_resize2-devel
BuildRequires:  systemd-rpm-macros
Requires:       xdg-desktop-portal
Requires:       umbriel

%description
The xdg-desktop-portal backend for Umbriel: screen sharing and screenshots
through PipeWire, global shortcuts and input capture, with a share picker.

%prep
%autosetup -n xdg-desktop-portal-umbriel-%{portal_commit} -p1

%build
%meson -Dtests=false
%meson_build

%install
%meson_install

%files
%license LICENSE
%{_libexecdir}/xdg-desktop-portal-umbriel
%{_libexecdir}/umbriel-share-picker
%{_datadir}/xdg-desktop-portal/portals/umbriel.portal
%{_datadir}/xdg-desktop-portal/umbriel-portals.conf
%{_datadir}/xdg-desktop-portal-umbriel/
%{_datadir}/dbus-1/services/org.freedesktop.impl.portal.desktop.umbriel.service
%{_userunitdir}/xdg-desktop-portal-umbriel.service

%changelog
* Sun Nov 22 2026 Daniel Grasso Carrasco <code@danielgrasso.com> - 0.1.0-0.1.git%{portal_short}
- Built from a pinned upstream commit for the Lucciola image.
