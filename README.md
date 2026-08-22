# MetaShield

MetaShield is an aggressive macOS image metadata scrubber designed for NovelAI PNGs.
The visible operation is intentionally simple: select or drop an image, sanitize it,
verify the result, and only then replace the original PNG.

MetaShield performs all image decoding and encoding locally. The app has no analytics,
account system, advertising SDK, or updater. Its only network feature is an optional,
off-by-default GitHub release check; image data and metadata are never transmitted.

## How this was built

MetaShield was developed with AI coding assistance. The sanitizing core, the file
replacement path, and the update check were reviewed by a human against the threat
model in `AUDIT.md`, and every claim in the guarantee boundary below is backed by an
automated self test (`swift run -c release metashield-self-test`, 16/16). No
third-party code is vendored: the app links only Apple system frameworks and the
system zlib.

## Guarantee boundary

For a successfully processed PNG, MetaShield guarantees that the output:

- is a newly decoded and encoded, single-frame, 8-bit RGB PNG;
- has no alpha channel, so alpha-LSB, stealth pnginfo, signature, and FEC payloads
  cannot remain in the output alpha plane;
- is composited from straight (non-premultiplied) samples with a 16-level quantized
  alpha, so two inputs that differ only inside one alpha bucket produce byte-identical
  output. An alpha-LSB payload therefore leaves no residue in the output RGB either.
  Alpha differences large enough to cross a bucket boundary are visible transparency
  changes and fall under the visible-pixel boundary below;
- contains only `IHDR`, `IDAT`, and `IEND` chunks with valid CRCs;
- contains none of the source file's extended attributes;
- can be decoded again at the verified dimensions before replacement.

macOS may attach protected security attributes such as `com.apple.provenance` and
`com.apple.macl` to a newly created file. They are generated or managed by the OS
and are not copied image metadata. MetaShield does not try to defeat those macOS
security controls.

Arbitrary steganography embedded in visible RGB pixels is outside this guarantee.
Claiming to remove every possible hidden message while preserving an image would be
misleading. MetaShield does remove the known NovelAI container and alpha-channel paths.

## Update check

MetaShield never downloads or installs an update. The app is ad-hoc signed, so a
bundle fetched at runtime could not be tied to a developer identity, and replacing
the installed app from the network would be an unverifiable code path.

The optional check, off until the user enables it in the app window:

- runs only on an interactive launch, at most once every 24 hours;
- requests one compiled-in URL and reads exactly one field, `tag_name`, which is
  discarded unless it is a plain `major.minor.patch` number;
- rejects redirects and stops receiving the response as soon as it exceeds 512 KiB;
- never takes a URL from the response — the release page it opens is compiled in;
- shows a line of text and a button that downloads the new disk image.

The download is verified before the user ever sees the file. The app fetches a
manifest signed with an offline Ed25519 key, checks the signature *before* parsing
it, and only then downloads the disk image named by that manifest, rejecting it
unless its size and SHA-256 match. The manifest carries no URL: every address is
derived from compiled-in constants, so a compromised release host cannot redirect
the download. The verified file lands in the Downloads folder, marked as
downloaded so macOS still runs its first-launch check. MetaShield never installs
it, and never replaces itself.

When the check is enabled and macOS notification permission has already been granted,
a headless Finder, Services, or Photos run may also check once a day after it finishes
its work, and post a notification banner. That path never raises a permission prompt and
never delays process exit by more than eight seconds. With the check disabled, no path
touches the network. MetaShield installs no background agent.

## Input behavior

- Local PNG: canonicalized and atomically replaced after verification, without an
  extra confirmation dialog. Transparency is composited onto white; Finder tags,
  comments, quarantine/custom extended attributes, and source color profiles are
  not retained. File timestamps can change. Back up anything that must be reversible.
- Other still-image formats: automatically exported beside the source as a new
  canonical `.clean.png`; source retained and no folder chooser is shown.
- Photos, browsers, and other apps: file promises, file URLs, PNG, and TIFF pasteboard
  data are accepted when the source app provides them. Managed Photos originals are
  not overwritten; a clean PNG copy is saved instead.
- Photos share sheet: choose `Share > MetaShield`; processing starts automatically,
  the macOS share panel shows progress briefly and closes after completion, and
  cleaned PNGs are imported as new Photos library assets. The managed originals
  remain unchanged and temporary files are removed after PhotoKit completes the
  import. Photos `Edit With > MetaShield` is also accepted: its managed temporary
  input is sanitized and imported as a new Photos asset instead of being overwritten
  in its read-only folder. File-open hand-offs from Photos and Finder run headlessly:
  no MetaShield main window, Dock activation, focus change, completion sound, or
  confirmation dialog is shown, and the host process terminates after PhotoKit
  finishes. A first-run macOS Photos permission prompt can still be required and is
  brought to the foreground once; the MetaShield main window remains closed. An
  ad-hoc-signed update can make macOS request this permission again because it has
  no stable Developer ID signing identity.
- Read-only managed files received by the host app are automatically sanitized and
  imported into Photos. Pasteboard-only images are saved to Downloads automatically.
- Animated input: refused so frames are never silently discarded.
- Resource limits: the host limits one input to 256 MiB and 40 million decoded
  pixels and accepts at most 100 images per request. The Photos share extension,
  which runs under a smaller macOS memory budget, limits each provider file to
  128 MiB and 8 million decoded pixels and accepts at most 20 images. Provider loads
  and Photos authorization/import callbacks also time out after 60 seconds.
- A headless hand-off never opens the MetaShield main window, including on failure.
  Finder Quick Action failures are reported by a notification; Photos share failures
  stay visible in the macOS share panel. A headless Photos `Edit With` failure simply
  adds no new image, so Photos permission should be checked if no result appears.

## Build

```sh
./scripts/build-app.sh
```

The script stages a universal arm64/x86_64 app under `work/package.noindex` and puts
the ad-hoc-signed development ZIP under `outputs/developer`. Keeping a second indexed
`.app` out of `outputs` prevents duplicate MetaShield entries in macOS Open With
menus. Install the ZIP's app in `/Applications` and launch it once so macOS registers
its Services entry.

`outputs/developer/MetaShield-<version>-local.zip` is a development artifact. For free direct distribution,
build the user-facing DMG and its checksum with `./scripts/package-direct-dmg.sh`.

For command-line verification:

```sh
swift run metashield-self-test
swift run metashield-cli --verify image.png
```

## Finder and app context menus

After installing and launching MetaShield once, supported applications can show:

`Services > 메타데이터 완전 제거 및 덮어쓰기`

The host application decides whether it exposes a selected image to macOS Services.
Dragging to MetaShield is the reliable fallback for Photos, browsers, and other apps.
For Finder's dedicated Quick Actions submenu, install the bundled workflow from
`packaging/quick-action` into `~/Library/Services`. The in-app
`Finder 빠른 동작 설치/복구` button also enables the workflow in Finder's
`FinderActive` preference and restarts Finder, which macOS 26 may require even
after the workflow has been registered successfully. The Finder workflow runs the
bundled CLI directly, without launching the app or showing a confirmation dialog.
PNG inputs are verified and replaced in place; other still-image formats produce a
uniquely named `.clean.png` beside the source.

If automatic registration fails, the workflow itself remains installed. Enable it
manually in `System Settings > General > Login Items & Extensions`.

## Direct distribution

The default free distribution path is an ad-hoc-signed DMG. It does not require an
Apple Developer Program membership, but macOS will require the user to choose
`Open Anyway` in Privacy & Security on first launch:

```sh
./scripts/package-direct-dmg.sh
./scripts/verify-direct-dmg.sh outputs/MetaShield-<version>-direct.dmg
```

Distribute the resulting `.dmg` and matching `.sha256` over HTTPS. The DMG includes
a Korean first-launch guide. Do not ask users to remove quarantine attributes with
a Terminal command.

Developer ID signing and notarization remain an optional paid path if Gatekeeper
approval without the manual exception is wanted later:

```sh
METASHIELD_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
METASHIELD_NOTARY_PROFILE="metashield-notary" \
./scripts/sign-and-notarize.sh
```

Then verify the exact notarized artifact before upload:

```sh
./scripts/verify-release.sh outputs/MetaShield-<version>.dmg
```

See `DISTRIBUTION.md` for the complete clean-install, upgrade, rollback, and uninstall
checklist, `INSTALL.md` for user-facing installation instructions, `AUDIT.md` for
the release audit, and `PRIVACY.md` for the privacy disclosure.

## License and reporting

Apache License 2.0 — see [LICENSE](LICENSE). Copyright 2026 MetaShield.
The license grants no trademark rights, and redistributions of modified files must
say that they were changed.

Security issues: see [SECURITY.md](SECURITY.md). Please do not file vulnerabilities
as public issues.
