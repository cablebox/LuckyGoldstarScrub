# LuckyGoldstarScrub

Performance and privacy audit of the LG OLED55CXPUA (CX, 2020) firmware 04.64.00 (webOS 5.6.2).

Start with **[REPORT.md](REPORT.md)**. It covers the changes to make (menu-only and rooted), what makes the TV slow,
and how it phones home. The supporting evidence is in `findings/`, the DNS blocklist is in `blocklist.txt`, and the
rooted-TV boot script is `scripts/50scrub`. `scripts/extract.sh` reproduces the firmware extraction.
