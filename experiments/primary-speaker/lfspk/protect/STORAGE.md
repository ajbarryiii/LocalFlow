# Storing the voiceprint on macOS (design; no LocalFlow code)

W4 deliverable 1. This covers condition (1), "adequately secured". Condition
(2), "not easily reversible", is covered by what the profile contains: see
`DESIGN.md` and `RESULTS.md`. Keys protect against everyone except an attacker
who also gets the key, so this document never counts a key toward (2).

LocalFlow as inspected (read-only), origin/main `a442d4a`: a non-sandboxed
Developer ID app with the hardened runtime. Its only entitlement is
`com.apple.security.device.audio-input` (`FreeFlow.entitlements`), and it ships
no provisioning profile. Settings go in `UserDefaults`; history (Core Data)
and audio go in `~/Library/Application Support/<LocalFlow|LocalFlow Dev>/`
(`AppName.supportDirectoryName`).

Every Apple claim below cites the page that supports it. **Unverified** marks
claims Apple does not document; each one comes with a test to run on a Mac
before relying on it. Documentation checked 2026-10-21.

## 0. Precondition: the audio history

LocalFlow keeps the latest 20 dictations as plain WAV files in
`Application Support/<app>/audio/` (`AppState.saveAudioFile`,
`maxPipelineHistoryCount = 20`). These files are not encrypted and not
excluded from backup. Anyone who can read the voiceprint from disk can read
those recordings too. That is minutes of the user's clean, close-microphone
voice: a better cloning source than any profile.

**Recommendation (a separate LocalFlow change; AJ decides): encrypt the
dictation history with the same key as the profile.** W4's measurements
(RESULTS.md) show that no utility-preserving transform makes the stored
template hard to invert. Storage encryption is therefore the main lever for
condition (1) (the owner's view, 2026-10-21), and it only works if it covers
every copy of the user's voice on disk.

- **Same scheme as the profile** (sections 1-3): AES-256-GCM via CryptoKit,
  a fresh 12-byte random nonce per file, the bundle identifier and key id as
  authenticated data. The key is a random 256-bit key in the keychain (2a
  now; ThisDeviceOnly data-protection keychain under 2b if LocalFlow adopts
  a provisioning profile), never synchronised. Each WAV is sealed at write
  time (`<uuid>.wav.lfa`) and opened in memory for replay and retry; no
  plaintext copy is written.
- **No backup:** set `isExcludedFromBackup` on the audio directory and on
  every file after each write, as for the profile.
- **Key handling:** read the key from the keychain once per app session and
  keep it in memory, so recording and replay add no keychain round trip. A
  missing or unreadable key means the old history is unreadable: delete it
  and start a new history with a new key (section 4). Never fall back to
  plaintext.
- **Cost** (sizes computed from the formats; encryption time not measured by
  W4, which has no Mac access):

  | item | plaintext size | AES-GCM overhead |
  |---|---|---|
  | voiceprint profile (W1 format, float32, one centroid: 20 + 2 + 4D bytes) | about 1 KB: 790 B at D = 192 (ReDimNet2-B2, ECAPA), 1,046 B at D = 256; about twice that with the v2 anchor | 28 B (12-byte nonce + 16-byte tag) |
  | one 30 s dictation WAV (16 kHz, 16-bit mono) | about 0.96 MB (32 kB/s) | 28 B |
  | full history (20 WAVs, up to 30 s each) | up to about 19 MB | 20 x 28 B |

  AES-GCM on Apple silicon uses the hardware AES instructions, so sealing
  about 1 MB per dictation should be far below the transcription time. That
  is an expectation, not a measurement; time one seal and open on the target
  Mac before shipping.
- Alternatives (also AJ's call): make the history opt-in, or shorten it. Any
  plaintext history left on disk makes the voiceprint's protection moot
  against a disk reader.

The profile's own protection still matters for leaks that carry the profile
without the audio: a backup or sync path, an export, an iOS App Group
container, or Linux, which saves no audio.

## 1. What is stored

One file, `Application Support/<app>/voiceprint.lfvp`, about 1 KB:

```
plaintext = "LFVP" | u8 format_version | embedder id + weights SHA-256 |
            protection id + parameter SHA-256 | per microphone route:
            (route tag, u32 dictation count, protected template bytes)
file      = AES.GCM.seal(plaintext, key, authenticating:
            "LFVP" | format_version | bundle identifier | key id).combined
```

- **AES-256-GCM via CryptoKit.** `SealedBox.combined` is nonce (12 bytes),
  then ciphertext, then tag (16 bytes). It is only available with the default
  12-byte nonce
  ([combined](https://developer.apple.com/documentation/cryptokit/aes/gcm/sealedbox/combined),
  [Nonce](https://developer.apple.com/documentation/cryptokit/aes/gcm/nonce),
  [tag](https://developer.apple.com/documentation/cryptokit/aes/gcm/sealedbox/tag)).
  Use a fresh random nonce on every save. The authenticated data binds the
  file to the app variant (Dev vs release) and the key generation, so a file
  copied between variants fails to open instead of being misread.
- **Template precision**: the running mean is stored as float32 (about 768 B
  for 192 dimensions, 1 KB for 256). W1's review found that float16 stops
  absorbing updates at high counts. W4's experiments use exactly this state.
- **Enrollment anchor** (W1 format v2, under review): a fixed early
  voiceprint kept for the anchored update rule. It is speaker-specific and at
  least as invertible as the running mean. It sits inside the same
  ciphertext, gets exactly the same protection transform as the mean, and is
  never stored in a weaker form. It is protected once at enrollment and
  rewritten byte-identically on every save, never re-noised: two
  independently noised copies could be averaged (DESIGN.md section 6.1).
- **Counters** (W1's format: dictations seen and accepted, uint32 each, plus a
  saturating uint16 count per centroid). Ruling: acceptable, inside the
  AES-GCM ciphertext only (never in a plaintext header, a log or a file name).
  They carry usage volume, not voice, but "accepted / seen" also hints at how
  often other voices reach the microphone, i.e. the user's surroundings.
  Store them coarsened: saturate both at 65,535 (uint16) — the update rule
  needs at most the centroid count, which already saturates — so the file
  never records lifetime totals.
- **Route tags** are coarse classes (`builtin`, `headset`, `other`), not
  device names: device names can identify a person or a product.
- **No timestamps and no per-dictation history** in the file. Only the count
  is needed for the running mean.
- **Writes are atomic** (`Data.write(options: .atomic)`: Apple documents it as
  writing "to an auxiliary file first and then replace the original file"
  ([atomic](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic))). Re-apply
  `isExcludedFromBackup` after every write (section 3).

## 2. The key

### 2a. What works today, without new entitlements (recommended now)

Store a random 256-bit key as a generic-password item in the **file-based
login keychain**. Use `SecItemAdd` without `kSecUseDataProtectionKeychain`,
with service `<bundle id>.voiceprint` and account `v1`.

- SecItem calls target the file-based keychain by default
  ([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)).
- Access is governed by the item's ACL. If the requesting app is not trusted,
  the system prompts the user ("Deny, Allow, Always Allow")
  ([Access control lists](https://developer.apple.com/documentation/security/access-control-lists)).
  **Unverified:** Apple's current pages do not say that the creating app is
  trusted by default. Test: create the item from a Developer ID build, read
  it back silently, then read it from `security find-generic-password -w` and
  expect a prompt.
- `kSecAttrAccessible…` values, including `WhenUnlockedThisDeviceOnly`, **do
  not apply here**. On macOS they apply only with
  `kSecUseDataProtectionKeychain` or `kSecAttrSynchronizable`
  ([kSecAttrAccessible](https://developer.apple.com/documentation/security/ksecattraccessible)).
  Do not set `kSecAttrSynchronizable`. Omitting it means the item is not
  synchronised
  ([kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable)).
- Caveats:
  - The login keychain lives in `~/Library/Keychains` and Time Machine backs
    it up ([Keychain Access help](https://support.apple.com/guide/keychain-access/kyca2423/mac)).
    That is acceptable because the voiceprint file itself is excluded from
    backup (section 3): a backup then holds a key with nothing to decrypt.
  - A change of signing identity (Team ID) changes the designated requirement
    and causes unexpected keychain alerts
    ([TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)).
    The missing-key path (section 4) handles this.

### 2b. Better, if LocalFlow adopts a Developer ID provisioning profile

Use the **data protection keychain**: `kSecUseDataProtectionKeychain = true`,
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and no synchronisation.

- ThisDeviceOnly items never migrate to another device or a restore from a
  different device
  ([WhenUnlockedThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly)).
- On macOS the data protection keychain needs keychain access-group
  entitlements, and these must be authorised by a provisioning profile
  ([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)).
  Without the profile, calls fail with `errSecMissingEntitlement` (-34018).
  Apple staff state this on the
  [developer forums](https://developer.apple.com/forums/thread/759481); the
  main documentation does not.
- On Apple silicon Macs the security boundary is login and logout, not screen
  lock as on iPhone (Apple Platform Security). On a Mac, "WhenUnlocked"
  therefore means roughly "while the user is logged in".
- Adding a provisioning profile and entitlements changes LocalFlow's signing.
  LocalFlow's AGENTS.md classes that as high risk: it needs AJ's approval and
  its own manual test.

### 2c. Optional Secure Enclave wrap

Create a `SecureEnclave.P256.KeyAgreement.PrivateKey` (CryptoKit). Derive the
file key by ECDH with a stored ephemeral public key plus HKDF. In the keychain
item store only the SE key's `dataRepresentation`, the encrypted blob that
"only the same Secure Enclave can later use to restore the key"
([Storing CryptoKit keys](https://developer.apple.com/documentation/cryptokit/storing-cryptokit-keys-in-the-keychain)).

- The private key never leaves the Enclave, and only P-256 is supported
  ([Protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave)).
  Available hardware: Apple silicon and T2 Macs; the Platform Security Guide
  also lists T1 Touch Bar models.
- Effect: a copy of the file plus the keychain taken off the Mac is useless.
  Decryption needs code running on that Mac. Against A3 this changes nothing:
  code running on the Mac can ask the Enclave to unwrap.
- **Unverified:** whether CryptoKit Secure Enclave keys need an entitlement or
  provisioning profile on macOS. Apple's docs do not say. An Apple engineer
  said Secure Enclave use needs a registered App ID with a profile, but that
  was about keychain-stored `SecKey` keys
  ([forum thread 728150](https://developer.apple.com/forums/thread/728150)).
  Test on a Developer ID build with the current entitlements: create a key,
  round-trip `dataRepresentation`, seal and open.
- If the Enclave is unavailable (Intel without T2, VMs) or the test fails,
  fall back to 2a. Never fall back to plaintext.

**Recommendation:** use 2a now. Add 2c if its test passes without a profile.
Adopt 2b only if LocalFlow takes on a provisioning profile for other reasons.

## 3. Backup, sync and disk encryption

- **Time Machine** backs up user files that are not part of macOS
  ([Mac help](https://support.apple.com/guide/mac-help/mh35860/mac)). Set
  `URLResourceValues.isExcludedFromBackup = true` on `voiceprint.lfvp` after
  every write; Apple warns that common file operations can reset it.
  - Apple documents this flag as excluding the file "from all backups of app
    data"
    ([isExcludedFromBackupKey](https://developer.apple.com/documentation/foundation/urlresourcekey/isexcludedfrombackupkey))
    but never names Time Machine. **Unverified for Time Machine;** check with
    `tmutil isexcluded <path>`.
  - LocalFlow already uses this flag for the Parakeet model directory.
  - Losing the profile on restore is fine: re-enrollment takes three
    dictations.
- **iCloud Drive** syncs Desktop and Documents when that option is on
  ([support 109344](https://support.apple.com/en-us/109344)), not
  `~/Library`. Apple says this by scope only, not explicitly. The profile
  never goes in Desktop or Documents.
- **iCloud Keychain**: not used (no synchronisable attribute; section 2a).
- **Disk:**
  - With FileVault, the whole volume is protected at rest.
  - Without FileVault, on Apple silicon or T2, the data volume is still
    encrypted, but its key is protected only by the hardware UID
    ([Platform Security](https://support.apple.com/guide/security/sec4c6dc1b6e/web)).
    Once the Mac boots, the files are readable to anyone with the hardware.
    The profile file is then still safe, because the login keychain holding
    the key is encrypted with the user's password. The WAV history is not
    (section 0).
- **Privacy consent does not cover `~/Library`**: macOS file-access prompts
  cover Desktop, Documents, Downloads, iCloud Drive and network volumes
  (Platform Security, "Controlling app access to files"). Any process running
  as the user can read Application Support, which is why the key goes in the
  keychain rather than next to the file.

## 4. Missing or unusable key: start over, never crash

Treat each of these as **no profile**:

- the item is not found, or the user denied the keychain prompt;
- `errSecMissingEntitlement`, or the Enclave key fails to restore (a new Mac,
  a reset, a restore from another device);
- AES-GCM authentication fails (tampering, corruption, wrong variant);
- the format version is unknown, or the embedder or protection hash differs
  from the running build (a model update).

In every case:

1. Dictation keeps working with the filter off. The filter never blocks or
   delays transcription.
2. Delete the unreadable file and the stale key. Create a new key on the next
   save.
3. Re-enrol silently from the next k dictations, as on first use.
4. Log one content-free event, such as `voiceprint reset: reason=auth`, with
   no bytes, scores, sizes or paths.

A model or protection change is a planned re-enrolment, not a migration. The
old template cannot be converted because the raw embedding is not stored.

## 5. Deletion and opt-out

- The feature is a setting ("Filter out other voices"). Turning it off
  deletes the file, the keychain item and the in-memory profile at once. A
  "Reset voice profile" action does the same and leaves the feature on. Both
  act immediately; nothing is queued.
- **Unverified (general macOS behaviour, not an Apple doc claim):**
  dragging the app to the Trash does not remove Application Support data or
  keychain items. Document the manual removal in the README: delete the file
  and the `<bundle id>.voiceprint` keychain item. Turning the feature off
  before uninstalling does both.

## 6. Exports, history and logs

- The profile, its templates, per-frame scores and per-dictation speaker
  decisions are never written to pipeline history (`PipelineHistoryStore`),
  `UserDefaults`, `os_log`/`print`, crash or diagnostic bundles, or any future
  export.
- LocalFlow on origin/main has no history export feature. Any future export
  must exclude the profile by construction, from an allow-list, not a
  deny-list.
- Logs may record events and counts only: "enrolled", "updated", "reset",
  "N words removed".
- Words removed as another speaker are transcript content, covered by the
  same retention policy as the transcript. Showing them in history is a
  product decision. If they are kept, they are as sensitive as the transcript
  itself.
- The decrypted profile lives only in LocalFlow's memory while the app runs.
  Keep its lifetime short and never copy it into long-lived caches.
  **Unverified (general Swift behaviour, no Apple guarantee found either way):**
  copy-on-write value types may leave copies that cannot be reliably zeroed,
  so do not rely on wiping memory.

## 7. iOS (later)

In LocalFlow iOS, the **containing app** captures audio and runs Parakeet
(`iOS/App/MicrophoneCapture.swift`; the keyboard drives it through the App
Group). The scorer therefore runs in the app, and **the keyboard extension
never needs the voiceprint**.

- Keep the profile in the app's own container, not the App Group: the keyboard
  never has a reason to read it, and every extra reader is an extra path out.
- File protection: `.completeUntilFirstUserAuthentication`. A dictation
  session can continue after the phone locks. With `.complete`, the file
  cannot be read while locked (Apple discards the class key about 10 s after
  lock) ([FileProtectionType](https://developer.apple.com/documentation/foundation/fileprotectiontype/complete)).
  The alternative is to load the profile into memory when the session starts
  and keep `.complete`; prefer this if sessions always start unlocked.
- Key: iOS always uses the data protection keychain. Use
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and no synchronisation.
  Such items "do not migrate to a new device", so a restore onto a
  **different** device leaves them absent
  ([AfterFirstUnlockThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)).
  A restore onto the **same** device may bring the key back; do not assume it
  forces re-enrolment. Set `isExcludedFromBackup` on the file as well, so a
  backup never carries both.
- If a later design does move scoring into the keyboard:
  - Current Apple docs give keyboards without Full Access **read-only**
    access to the containing app's shared containers
    ([Configuring open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)).
  - An older archived guide says keyboards have no shared container at all,
    so test on a device.
  - Keychain sharing with a keyboard extension through an access group is
    **not documented**; test it before relying on it.
- App Store privacy label: biometric data falls under "Sensitive Info". It
  only has to be declared if it leaves the device
  ([App privacy details](https://developer.apple.com/app-store/app-privacy-details/)).
  LocalFlow never transmits it.

## 8. What this does and does not protect (condition 1)

| attacker (DESIGN.md §2) | voiceprint with 2a (+2c) |
|---|---|
| A0 stolen powered-off Mac or Time Machine disk | Safe. The file is excluded from backup; on the Mac it needs the login keychain (user password) to decrypt; with 2c it also needs that Mac's Enclave. |
| A1 copies files out of `~/Library` | Safe. Ciphertext only; the key is in the keychain. |
| A2 code running as the user that can read the keychain item or LocalFlow's memory (as DESIGN.md §2 defines it) | **Not protected by storage.** By definition A2 gets the key or the decrypted profile; only the profile's content limits the damage (as for A3). |
| A3 full compromise | Not protected by storage. Only the profile's content limits the damage: W4's experiments. |

Barriers that raise the cost of becoming A2, without stopping A2:

- a different process reading the key from the file-based keychain gets a
  user prompt unless trusted (section 2a; the default trust of the creating
  app is unverified);
- the hardened runtime protects "against certain classes of exploits, like
  code injection, dynamically linked library (DLL) hijacking, and process
  memory space tampering"
  ([Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime));
  it does not stop code that can drive LocalFlow's own UI or run as root.

Apple's own Touch ID and Face ID templates are processed, encrypted and
stored by the Secure Enclave, and Touch ID data "never leaves the device"
([Face ID and Touch ID security](https://support.apple.com/guide/security/face-id-and-touch-id-security-sec067eb0c9e/web)).
**Unverified:** that apps can never obtain the template through
LocalAuthentication (the page implies a match/no-match answer but does not
state it). A voiceprint in LocalFlow gets none of that hardware protection. It is app
data protected as described here.

W4 measured whether condition (2) could instead come from what the template
contains. It cannot, inside the utility budget: every utility-preserving
transform still yields a recoverable, identifying profile (RESULTS.md). So
encryption at rest is the protection, and the honest statement is that the
profile is safe against disk thieves and backup leaks, not against code
running as the user.

## 9. Recommendation (final)

The owner's decision (2026-10-21) treats encryption at rest as the shipping
protection.

1. Store the profile encrypted with AES-256-GCM (sections 1-2a; optionally
   wrapped by the Secure Enclave, 2c):
   - the key is a random 256-bit key in the login keychain, never
     synchronised, read once per session and cached;
   - the file is excluded from backup (section 3).
2. Encrypt the dictation history with the same key, or make it opt-in
   (section 0). Without this, a disk reader clones from the WAVs instead.
3. Missing or unusable key: start over silently; never crash, never fall
   back to plaintext (section 4). Deletion and opt-out are immediate
   (section 5). Nothing enters logs, history or exports (section 6).
4. Optional keyed random rotation of the template is defence in depth only.
   It costs no utility and is exactly invertible with the key. Without the
   key, recovery collapses (measured: cosine about 0). It protects only
   against an attacker holding the file but not the key, a case encryption
   already covers.
5. Do not present any content transform (quantisation, noise, sign codes,
   stored classifiers) as making the voiceprint non-invertible. Inside the
   utility budget none does.
