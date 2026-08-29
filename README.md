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
automated self test (`swift run -c release metashield-self-test`, 35/35). No
third-party code is vendored: the app links only Apple system frameworks and the
system zlib.

## Isolated decoding

Opening images from untrusted sources is what MetaShield is for, and it is also
the largest thing that can go wrong: the decoders live in Apple's ImageIO, and a
memory-safety bug there would otherwise run with the user's full privileges.

Every byte an attacker controls is therefore decoded in a separate XPC service
that is sandboxed with **only** `com.apple.security.app-sandbox` — no file,
network, or device access of any kind. The app hands it a read-only descriptor
and gets back encoded bytes; it keeps the file handling, verification, and
replacement for itself, because those need privileges the decoder must not have.

Validation that invokes native decoders happens on the same side of the boundary.
The service checks its own output before returning it, and the app then does only
non-decoding checks: the pure-Swift `PNGInspector` structural parse, byte counts,
and a bounded byte-for-byte comparison of what reached the disk. For PNG, the
service independently checks the exact zlib end, decompressed scanline length,
and every row's filter byte; a redundant ImageIO decode is unnecessary. The app
does not open untrusted or service-returned bytes with ImageIO at all — doing so
would give a compromised decoder the same bug to exploit a second time, outside
the sandbox.

There is no silent fallback. If the service cannot be reached the request fails
rather than quietly decoding in the app, since dropping the isolation exactly
when something is already wrong is the worst possible moment for it.

The service does not trust its caller either. It enforces its own absolute
ceilings (40 MP, 256 MiB input and output), measures the descriptor with `fstat` before reading
it, requires a regular file, reads in bounded chunks, and returns an error for a
malformed request rather than trapping.

What this does **not** claim: a compromised decoder can still return bytes the
app will write to disk. The app never decodes them, so the sandbox is not
re-entered, but the resulting file is only as trustworthy as the service that
produced it. `AUDIT.md` states the boundary precisely.

This is why the app itself is not sandboxed: doing that was measured (see
`AUDIT.md`) and it breaks in-place replacement and copies beside the original,
while adding a quarantine attribute to every result. Isolating the decoder keeps
all of that behaviour and puts the sandbox where the danger actually is.

The command-line tool uses the same service when it runs from inside the app
bundle. Built standalone it decodes in process, which is a development path.
The Photos share extension is itself sandboxed, so its decoding is already
contained.

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
- contains only `IHDR`, `IDAT`, and `IEND` chunks with valid CRCs, and an `IDAT`
  whose zlib stream decodes to exactly one scanline per row with no trailing or
  concatenated data. **In the shipped app that pixel-stream check runs in the
  isolated decoder, not in the app.** The app repeats only the container checks,
  because inflating attacker-influenced bytes in the unsandboxed process is the
  thing the isolation exists to avoid. A compromised decoder could therefore
  return a container the app accepts and writes; it cannot re-enter the app, but
  this specific guarantee is enforced on the sandboxed side. The command-line
  tool built standalone performs the full check in process;
- contains none of the source file's extended attributes;
- contains one complete zlib stream with exactly the expected number of RGB
  scanline bytes and a valid PNG filter byte on every row.

macOS may attach protected security attributes such as `com.apple.provenance` and
`com.apple.macl` to a newly created file. They are generated or managed by the OS
and are not copied image metadata. MetaShield does not try to defeat those macOS
security controls.

## AVIF conversion (separate, weaker guarantee)

MetaShield can also write an AVIF copy, for cases where file size matters more
than a byte-level structural guarantee. This is a *different* promise and is
stated separately on purpose:

- AVIF conversion never overwrites a source file; it always writes a new file
  beside the original. Two additional menu items also move the source to the
  Trash afterwards, and they say so in their names. Retiring the source is not a
  setting the plain conversion commands can silently acquire, because AVIF is
  lossy and not readable everywhere: the choice belongs in the command the user
  picks, and both variants are off until the user enables them.
- AVIF is always lossy. Apple's encoder has no lossless mode, and a requested
  quality of 1.0 makes it fail outright, so the usable range stops below that.
  Pixels are re-encoded and will not match the source exactly.
- The image handed to the encoder is produced by the same pipeline as the PNG
  path: a freshly decoded, single-frame, fully opaque 8-bit sRGB image built from
  raw samples, carrying none of the source's metadata, alpha, or extended
  attributes. Alpha-LSB payloads are destroyed before encoding, exactly as for PNG.
- The written file is re-read and rejected unless it decodes to one opaque image
  at the expected dimensions and carries no EXIF, GPS, IPTC, maker-note, or other
  descriptive metadata container. Apple's encoder writes only structural entries
  (orientation, tile geometry), which are the only `{TIFF}` keys accepted.
- What AVIF does *not* get is the PNG path's chunk-level canonicalization: there
  is no equivalent of "only IHDR, IDAT and IEND, with a validated zlib stream".
  The AVIF guarantee is about what the file decodes to and what metadata it
  reports, not about every byte of its container.

**AVIF conversion requires macOS 26 or later.** Apple's ImageIO gained an AVIF
*encoder* only in macOS 26; releases 13 through 15 can decode AVIF but not write
it. This was measured on GitHub's macOS 14, 15 and 26 runners, not inferred from
version numbers. Because the app supports macOS 13 and up, availability is checked
at runtime: on an older system the two AVIF menu items fail immediately with a
message saying so, no partial file is written, and the source is untouched. The
metadata-scrubbing commands are unaffected and work on every supported release.

Supporting AVIF (or WebP) on older macOS would require vendoring an encoder, which
is why it is not done: no third-party code is involved here, and AVIF encoding is
provided by Apple's ImageIO where the OS offers it.

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
- Other still-image formats: exported beside the source as a new canonical
  `.clean.png`, after which the source is moved to the Trash. Leaving it would
  defeat the point: the original still carries the metadata that was just
  removed, sitting next to a file the user believes is clean. The move is only
  made after the copy has been written and verified, only when the copy landed
  in the same folder, and never for a Photos-managed original. It goes to the
  Trash rather than being deleted, so it is recoverable.
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
  and Photos authorization/import callbacks also time out after 60 seconds. Photos
  file promises are received serially, monitored while they are being written,
  and limited to 256 MiB each and 4 GiB for the batch. AppKit exposes no size
  preflight for raw pasteboard image data, so that one path can be materialized by
  macOS before MetaShield applies its 256 MiB rejection limit.
- A headless hand-off never opens the MetaShield main window, including on failure.
  Headless results are silent by default; when the user enables the main window's
  `백그라운드 처리 완료 알림` option and macOS notification permission is granted, a
  finished headless run posts one summary notification (success count, or the first
  failure). Photos share failures stay visible in the macOS share panel. A headless
  Photos `Edit With` failure simply adds no new image, so Photos permission should be
  checked if no result appears.

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

```
Services > 메타데이터 완전 제거 및 덮어쓰기          (in place, irreversible)
Services > AVIF로 변환 (메타데이터 제거)              (new file, original kept)
Services > AVIF로 변환 및 압축 (메타데이터 제거)      (new file, original kept)
```

Each menu item names exactly what it does. The compression level used by the
third item is a slider in the main window; it changes how small the new file is
and never changes whether a file is replaced.

**A fresh install shows only the first item.** The two AVIF commands start hidden
and are opt-in, because they do a different job from what most people install
MetaShield for, and because writing AVIF needs macOS 26 anyway. The main window's
`Finder 메뉴 설정 열기…` button opens the Services list in System Settings, where
each command is shown or hidden with Apple's own checkboxes.

macOS enables every service an app declares and `Info.plist` cannot mark one as
off by default, so that initial state is seeded once — at first launch only — by
writing the same `pbs` preference System Settings itself uses. It never runs
again, so a command the user later enables is never turned back off, and an
existing entry is never overwritten. If that undocumented format ever changes the
write simply does nothing: all three items stay visible, exactly as in earlier
releases, and remain removable from System Settings. The app keeps no checkbox of
its own for this, so there is no stored state that can disagree with reality.

The host application decides whether it exposes a selected image to macOS Services.
Dragging to MetaShield is the reliable fallback for Photos, browsers, and other apps.
The Finder command is a bundle-contained AppKit Service. MetaShield does not copy a
workflow, helper, or background agent outside the app bundle. PNG inputs are verified
and replaced in place; other still-image formats produce a uniquely named `.clean.png`
beside the source. Releases from 0.3.8 onward remove the legacy 0.3.7-and-earlier
workflow the first time they launch. The app also declares itself an alternate image
handler (`Editor` role, because it modifies files in place, with `Alternate` rank), so
dragging files onto the MetaShield Dock icon or choosing Finder's
`Open With > MetaShield` runs the same headless sanitization as the Service; MetaShield
never becomes the default handler for any image type. Finder-side processing needs no
TCC permission at all. The main window's `사진 권한 미리 연결… (선택)` button opens
Apple's share picker with a metadata-free setup image. Selecting MetaShield there
grants the share extension's add-only Photos permission ahead of time; the step is
optional — skipping it simply means the same one-time prompt appears on the first real
`Share > MetaShield` use. The setup image is never imported. macOS may still show its
fixed Copy/Edit Extensions rows in that picker.
Notification permission remains optional and is requested only when the user enables
GitHub update checks. Other Photos hand-off paths run under the host app and may receive
their own one-time permission prompt when first used.

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
