# Noctalia Greeter, packaged by Lucciola from a pinned upstream tag.
#
# Built by lucciola/greeter/build-rpm.sh in the Containerfile's greeter-rpm
# stage (on the same base image as Lucciola), installed by lucciola/build.sh
# with dnf, so its runtime libraries come from Fedora and the files are owned
# by an RPM like everything else in the image. Why not Terra's package: see
# the Containerfile, at the greeter-rpm stage.
#
# The version comes from the build (--define "greeter_version X.Y.Z"); the
# source tarball's sha256 is checked by build-rpm.sh before rpmbuild runs.

Name:           noctalia-greeter
Version:        %{greeter_version}
Release:        4%{?dist}
Summary:        Login greeter for greetd with the look of Noctalia Shell
License:        MIT AND (Apache-2.0 OR MIT)
URL:            https://github.com/noctalia-dev/noctalia-greeter
Source0:        %{url}/archive/refs/tags/v%{version}.tar.gz
# Lucciola's mark (lucciola/assets/lucciola-mark.svg): the greeter has no
# setting for its logo, only hide_logo, and draws assets/noctalia.svg at the
# bottom of the screen, tinted with the palette's on_surface. %%install puts
# the firefly in its place, so greeter.toml can show the logo again.
Source1:        lucciola-mark.svg
# A wrong password read "pam_authenticate: AUTH_ERR"; the patch says it in
# words (the patch file says which results and why).
Patch0:         0001-say-pam-results-in-words.patch
# The fingerprint reader listens as soon as the login screen is up, without
# an Enter first: [auth].start_on_select, turned on by Lucciola's
# greeter.toml (the patch file says how it behaves).
Patch1:         0002-start-auth-on-select.patch
# The text field's caret (in the palette's text colour) and reveal icon follow
# the palette, instead of keeping Noctalia's built-in colours from start-up.
Patch2:         0003-caret-in-palette-colour.patch

# The pkg-config names come from meson.build of the tag.
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  meson
BuildRequires:  wayland-devel
BuildRequires:  pkgconfig(wayland-client)
BuildRequires:  pkgconfig(wayland-server)
BuildRequires:  pkgconfig(wayland-egl)
BuildRequires:  pkgconfig(wayland-protocols)
BuildRequires:  pkgconfig(xkbcommon)
BuildRequires:  pkgconfig(freetype2)
BuildRequires:  pkgconfig(fontconfig)
BuildRequires:  pkgconfig(cairo)
BuildRequires:  pkgconfig(cairo-ft)
BuildRequires:  pkgconfig(pango)
BuildRequires:  pkgconfig(pangocairo)
BuildRequires:  pkgconfig(pangoft2)
BuildRequires:  pkgconfig(librsvg-2.0)
BuildRequires:  pkgconfig(libxml-2.0)
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  pkgconfig(gio-2.0)
BuildRequires:  pkgconfig(tomlplusplus)
BuildRequires:  pkgconfig(nlohmann_json)
BuildRequires:  pkgconfig(wlroots-0.20)
BuildRequires:  pkgconfig(libinput)
BuildRequires:  pkgconfig(libwebp)
BuildRequires:  pkgconfig(egl)
BuildRequires:  pkgconfig(glesv2)
BuildRequires:  stb_image_resize2-devel

# greetd runs it; noctalia-greeter-session starts the compositor under
# dbus-run-session (dbus-daemon), and without it the greeter has no session
# bus. polkit's pkexec runs the appearance helper for "Sync with Noctalia".
Requires:       greetd
Requires:       dbus-daemon
Requires:       polkit

%description
Noctalia Greeter is a login screen for greetd: pick a user, enter the
password, choose a Wayland session. It runs in its own small wlroots
compositor and shares the visual language of Noctalia Shell, which can copy
its colours, font and wallpaper to it ("Sync with Noctalia").

%prep
%autosetup -n noctalia-greeter-%{version} -p1

%build
# Fedora's %%meson uses buildtype=plain with the distribution's flags; the
# project's "release" buildtype would add -march=native.
%meson -Db_pie=true
%meson_build

%install
%meson_install
# Upstream's tmpfiles entry hardcodes a "greeter" account; Fedora's greetd
# runs greeters as "greetd", and Lucciola ships its own entry
# (lucciola-greeter.conf) with that account and the seeded settings.
rm -f %{buildroot}%{_prefix}/lib/tmpfiles.d/noctalia-greeter.conf
# The login screen's logo: Lucciola's firefly instead of Noctalia's (Source1).
test -f %{buildroot}%{_datadir}/noctalia-greeter/assets/noctalia.svg
install -m 0644 %{SOURCE1} %{buildroot}%{_datadir}/noctalia-greeter/assets/noctalia.svg

%files
%license LICENSE
%doc README.md
%{_bindir}/noctalia-greeter
%{_bindir}/noctalia-greeter-apply-appearance
%{_bindir}/noctalia-greeter-compositor
%{_bindir}/noctalia-greeter-print-greetd-config
%{_bindir}/noctalia-greeter-session
%{_bindir}/noctalia-greeter-xsession
%{_datadir}/noctalia-greeter/
%{_datadir}/polkit-1/actions/org.noctalia.greeter.apply-appearance.policy

%changelog
* Mon Oct 19 2026 Daniel Grasso Carrasco <code@danielgrasso.com> - %{greeter_version}-4
- The text field's caret in the palette's text colour and its reveal icon
  in the palette's, re-applied with the palette, instead of the colours of
  Noctalia's built-in palette from start-up

* Mon Oct 19 2026 Daniel Grasso Carrasco <code@danielgrasso.com> - %{greeter_version}-3
- [auth].start_on_select: the login conversation starts when a user is
  selected, so the fingerprint reader listens without an Enter first

* Sun Oct 18 2026 Daniel Grasso Carrasco <code@danielgrasso.com> - %{greeter_version}-2
- Lucciola's firefly as the logo; PAM results in words on a failed login

* Sat Oct 17 2026 Daniel Grasso Carrasco <code@danielgrasso.com> - %{greeter_version}-1
- Built from the upstream tag for the Lucciola image
