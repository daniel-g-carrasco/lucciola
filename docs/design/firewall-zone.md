# A stricter default firewall zone

Proposal for decision D2 and item E8 of [`SECURITY-CLAIMS.md`](../SECURITY-CLAIMS.md).
Written 2026-11-11. **Nothing here is implemented**: this is the reasoning
to agree on before any zone is written.

## What happens today

Lucciola uses Fedora's default, the `FedoraWorkstation` zone, on every
network the machine joins:

- every TCP and UDP port from 1025 to 65535 accepts connections;
- below 1025, only what is named: DHCPv6, the Samba client, and SSH (which
  Remote Login takes away and gives back only to its own tunnels and devices).

A fresh install listens on very little: mDNS (5353) and LLMNR (5355), the
two lines of `.github/smoke/listeners-allow.txt`. So the open range does not
expose what the image runs. It exposes **what the owner runs later**, on
whatever network they are on that day.

Three features already ask for their own ports: Phone (the `kdeconnect`
service), Sunshine (nine ports) and Remote Login (its own zone). Today the
first two are redundant, their ports are inside the open range anyway.

## What the open range is for

Fedora opens it so that a desktop works without firewall questions. On
Lucciola these are the things that need to be reached from the network:

| What | Why it needs an open port |
|---|---|
| Lanterna, screen mirroring to the TV | the TV connects back to an HTTP server on the laptop |
| Phone (KDE Connect) | the phone opens the connection |
| Sunshine | the client opens the connection |
| Steam: Remote Play, game transfer between PCs, LAN games | incoming by design |
| LocalSend, Syncthing, a file sent with `nc` | incoming by design |
| A site under development opened from the phone | incoming by design |
| Finding devices: printers, TVs, network shares | the answer to a multicast question arrives from another address, so the firewall does not see it as a reply |

Nothing in this list makes sense on a network the owner does not control.

## What it costs

On a café, hotel, train or conference network, every program that listens
is reachable by everyone else on that network: a development server, a
container published with `-p`, a database, a notebook, a debug port, a
model server set to listen everywhere. None of these was meant to be
public, and nothing tells the owner that it is.

That is the whole risk. It is a laptop's risk: a desktop that never leaves
home is behind its router either way.

## Options

| | What it is | Safe on a public network | What breaks |
|---|---|---|---|
| **A** | Keep `FedoraWorkstation` | no | nothing |
| **B** | A strict zone everywhere | yes | everything in the table above, at home too, until each thing is opened by hand |
| **C** | Trust per network: strict unless the owner says "I trust this network" | yes | the table above on a network not yet marked as trusted; nothing at home once it is |
| **D** | Close TCP, keep UDP open | mostly | Lanterna, Steam, LocalSend, a site opened from the phone, at home too |

B is the safest and the one people turn off: the first evening the TV does
not show up, the firewall goes. D looks like a compromise and breaks the
same things at home that B does, because what people use is TCP.

## Recommendation: C

It is what Windows and macOS do, for the same reason: the question is not
"which ports" but "which network".

**Two zones.**

- `lucciola-public`, the default. Accepts DHCPv6 and nothing else. The
  machine does not answer mDNS or LLMNR here: on a public network its name
  is nobody's business. Outgoing connections and their replies work as
  always: browsing, mail, VPN, video calls, updates.
- `lucciola-trusted`. What `FedoraWorkstation` is today, without SSH. Not
  narrower: narrowing it is a second decision, to take with data, and
  nothing in this proposal depends on it.

**One rule.** A network is public until the owner says otherwise. The
choice is stored where NetworkManager already keeps it, in the network's
own profile (`connection.zone`), so it follows the network, not the day.
Wi-Fi and cable alike.

**Where the owner says it.**

1. The first time a network is joined, a notification: *"Casetta is treated
   as a public network: this PC cannot be reached from it."* with one
   action, *"I trust this network"*.
2. Lucciola System, a row for the network in use: *"I trust this network
   (home, office)"*, a switch. The same page answers the question a silent
   firewall never answers, **why does it not work**: it lists what is
   listening and says that on this network nobody can reach it.
3. `ujust lucciola-network trust|public|status`, the same helper.

**What the features do.** Phone and Sunshine open their ports in the
trusted zone only; their pages say that they work on trusted networks.
Remote Login does not change: its tunnels keep their own zone, its chosen
devices are allowed in both.

**VPNs.** A tunnel of one's own stays in `lucciola-tunnel` as today. A
commercial VPN is public, which is the default.

**Machines already installed.** The default zone arrives through
`/etc/firewalld/firewalld.conf`. An owner who changed that file keeps
their choice; nobody else has to do anything to get the new default. Every
saved network starts as public, and the first login after the update asks
about the one in use. I would not mark saved networks as trusted on the
owner's behalf: the list holds hotels as well as homes.

## What this does not protect from

- A network that pretends to be the trusted one (same name, same
  password). The same is true of every per-network firewall.
- Anything outgoing. This is about being reached, not about reaching.
- Programs on the same machine.

## Side effects worth knowing

- **D3 (LLMNR) mostly answers itself**: on a public network port 5355 is
  closed. Whether to keep LLMNR on trusted networks is all that is left.
- **Claim C9** ("the firewall blocks unsolicited inbound traffic") goes
  from *limitation* to *verified*, with a check in the smoke boot.
- A Flatpak app cannot know why nothing reaches it. Lanterna on a public
  network will look for the TV and find nothing. The notification and the
  page in Lucciola System are the only places that explain it, so their
  words matter more than the zone files.

## The work, in three pull requests

1. The two zones, the default, the helper (`lucciola-network`), Phone,
   Sunshine and Remote Login adapted, tests on fakes, the smoke check.
   No window yet: the helper and `ujust` are enough to try it for a week.
2. The notification and the row in Lucciola System.
3. The guide.

## To decide

1. **C**, or another option.
2. **The words**: "trusted" and "public", or "home" and "public". I lean to
   "trusted": an office is not a home.
3. **mDNS on public networks**: closed (my advice: the machine neither
   announces itself nor finds printers there) or open (printers found
   everywhere, the name visible to everyone).
4. **Machines already installed**: ask for each network (my advice), or
   trust the network in use at the moment of the update without asking.
