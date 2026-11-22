# Umbriel, packaged by Lucciola from a pinned upstream commit.
#
# Lucciola's compositor: the Lucciola session runs Umbriel with the Noctalia
# shell on top (lucciola/build.sh, step 2). Umbriel has no releases yet
# (0.1.0, 2026-11), so the commit is pinned and its archive checked against
# a sha256 by build-rpm.sh. Built in the Containerfile's umbriel-rpm stage on
# the image's own base, so it links against the wlroots 0.20 the image ships
# (Umbriel needs >= 0.20.1 and < 0.21). Not in Fedora; Terra has nightly
# builds only, which a pin cannot hold.
#
# Lucciola's patches (each says why):
#   0001  untagged SDR decodes with sdr_transfer (gamma 2.2) while an SDR
#         gamut mapping is staged, as on HDR outputs: the panel's ICC
#         profile no longer lifts the shadows
#   0002  sRGB-tagged SDR (Chromium, Electron) decodes like untagged SDR
#         under that mapping, so one colour is shown as one value
# Proposed upstream: noctalia-dev/umbriel#885.

Name:           umbriel
Version:        0.1.0
Release:        0.1.git%{umbriel_short}%{?dist}
Summary:        Wayland compositor with scrolling, dwindle and master layouts
License:        MIT
URL:            https://github.com/noctalia-dev/umbriel
Source0:        %{url}/archive/%{umbriel_commit}.tar.gz
Patch0:         0001-sdr-transfer-for-staged-sdr-mapping.patch
Patch1:         0002-srgb-tagged-like-untagged-under-sdr-mapping.patch

# The pkg-config names come from meson.build of the commit.
BuildRequires:  gcc-c++
BuildRequires:  meson
BuildRequires:  pkgconfig(wayland-server)
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-protocols)
BuildRequires:  pkgconfig(wlroots-0.20)
BuildRequires:  pkgconfig(xkbcommon)
BuildRequires:  pkgconfig(libinput)
BuildRequires:  pkgconfig(libeis-1.0)
BuildRequires:  pkgconfig(pixman-1)
BuildRequires:  pkgconfig(tomlplusplus)
BuildRequires:  pkgconfig(nlohmann_json)
BuildRequires:  pkgconfig(cairo)
BuildRequires:  pkgconfig(pangocairo)
BuildRequires:  pkgconfig(libdrm)
BuildRequires:  pkgconfig(libdisplay-info)
BuildRequires:  pkgconfig(libudev)
BuildRequires:  pkgconfig(lcms2)
BuildRequires:  pkgconfig(libsystemd)
BuildRequires:  pkgconfig(xcb)
BuildRequires:  pkgconfig(xcb-icccm)
BuildRequires:  pkgconfig(xcb-ewmh)
BuildRequires:  pkgconfig(xcb-shape)
BuildRequires:  pkgconfig(xcb-randr)
BuildRequires:  pkgconfig(egl)
BuildRequires:  pkgconfig(glesv2)
BuildRequires:  pkgconfig(gbm)
BuildRequires:  pkgconfig(jemalloc)
BuildRequires:  systemd-rpm-macros
# Xwayland starts on demand for X11 applications.
Requires:       xorg-x11-server-Xwayland

%description
Umbriel is a Wayland compositor built on wlroots: scrolling, dwindle, master
and stacking layouts, per-output workspaces, window rules, colour management
with ICC profiles, and fluid animations. It pairs with the Noctalia shell.

%prep
%autosetup -n umbriel-%{umbriel_commit} -p1

%build
# lcms2 on: ICC characterization of the panel (color_profile); tests off: the
# harness needs a GPU and a session.
%meson -Dtests=disabled -Dlcms2=enabled -Djemalloc=enabled -Dlocaled=enabled
%meson_build

%install
%meson_install

%files
%license LICENSE
%doc README.md
%{_bindir}/umbriel
%{_bindir}/start-umbriel
%{_datadir}/umbriel/
%{_datadir}/wayland-sessions/umbriel.desktop
%{_userunitdir}/umbriel.service
%{_userunitdir}/umbriel-session.target
%{_userunitdir}/umbriel-shutdown.target

%changelog
* Sun Nov 22 2026 Daniel Grasso Carrasco <code@danielgrasso.com> - 0.1.0-0.1.git%{umbriel_short}
- Built from a pinned upstream commit for the Lucciola image, with two
  colour patches (0001, 0002).
