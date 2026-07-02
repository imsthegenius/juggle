# Publishing Juggle

Public source is generated from the private working repository with:

```bash
scripts/public-export.sh /tmp/juggle-public --init-git
```

The public repo intentionally contains only the app source, tests, packaging,
build/release scripts, README, license/notices, and the static download page.
Internal agent instructions, private planning notes, QA scratch files, and local
release artifacts are excluded from the first public history.

Public DMGs must be built with `scripts/release.sh` so they are Developer ID
signed, notarized, stapled, verified with `hdiutil verify`, and accompanied by a
SHA-256 checksum.
