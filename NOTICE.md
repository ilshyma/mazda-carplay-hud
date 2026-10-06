# Third-party attributions

This project is licensed under the GNU Affero General Public License
v3.0 — see [LICENSE](LICENSE) — because parts of it are derived from
work that was already under AGPL-3.0:

## headunit — by Trevelopment / Bryan Adams et al.

* Upstream:  https://github.com/Trevelopment/headunit
* License:   GNU Affero General Public License v3.0 (same terms as
             this project's [LICENSE](LICENSE))

Portions of this project's code and the vendored CMU D-Bus proxies
were copied verbatim or adapted from that repository. Derived source
files carry an `SPDX-License-Identifier: AGPL-3.0-or-later` header
and a back-reference to the upstream.

## License compatibility note

AGPL-3.0 is copyleft: any derivative work must also be licensed
under AGPL-3.0 (or a later compatible version), and the corresponding
source must be made available to users who interact with the software
over a network. Keeping this repository public satisfies that.

## mazda-carplay-hud — by KID MIXER-MODER, EU fixes by ilshyma

* Upstream:  https://github.com/KidMixer/mazda-carplay-hud (v2.0.0),
             via https://github.com/ilshyma/mazda-carplay-hud (eu-fix)
* License:   GNU Affero General Public License v3.0

`mazda/patches/blmjcicarplay/` (the CarPlay iAP2 -> HUD shim) was
imported from that project and adapted to take its speed limit from
the svcjcinavi shim (`mazda/patches/common/hud_share.h`).
