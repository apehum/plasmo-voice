# macOS microphone tests

Checks, on a GitHub macOS runner, which input device Plasmo Voice opens under launchers with different
microphone setups, whether it starts the microphone helper, and whether voice actually reaches the server.

Each case is one job: it starts an offline Fabric server with PV, launches the game through a stand-in
launcher app, answers the microphone prompts, and fails when PV did something other than what the case
expects. The workflow is [`macos-mic.yml`](../../workflows/macos-mic.yml).

## Running it

The cases run on every pull request after the PR snapshot build, using that build's 26.3 Fabric jar.

macOS jobs are free on public repositories, but only five run at a time, so the full set takes two waves.

## Launchers

Real launchers can't run here (no Minecraft account, their own dialogs), so `prepare.sh` builds a stub
app that starts the game through [portablemc](https://github.com/mindstorm38/portablemc). TCC judges a
microphone request by the responsible app, so the stub's bundle id, `Info.plist` and signature are what
each variant changes:

| Launcher | Stands in for |
|---|---|
| `usage` | Prism: declares `NSMicrophoneUsageDescription`, so TCC prompts for it |
| `no-usage` | Launchers without the usage description: TCC refuses them without a prompt |
| `hardened` | The official Minecraft Launcher: hardened runtime, no usage description, no `com.apple.security.device.audio-input` entitlement |

## Cases

They are the matrix in [`macos-mic.yml`](../../workflows/macos-mic.yml); to add one, add a line.

| Case | Launcher permission | Helper permission | Prompt answer | Expected device | Helper |
|---|---|---|---|---|---|
| `usage-fresh-allow` | not asked yet | not asked yet | allow | javax | no |
| `usage-fresh-deny` | not asked yet | not asked yet | deny | none, denied | no |
| `usage-allowed` | allowed | not asked yet | – | javax | no |
| `usage-denied` | denied | not asked yet | – | none, denied | no |
| `no-usage-fresh-allow` | not asked yet | not asked yet | allow | CoreAudio | yes |
| `no-usage-fresh-deny` | not asked yet | not asked yet | deny | none, denied | yes |
| `no-usage-helper-allowed` | not asked yet | allowed | – | CoreAudio | yes |
| `hardened-fresh-allow` | not asked yet | not asked yet | allow | CoreAudio | yes |

How `run-case.sh` tells what happened:

- **Device:** the `JavaxInputDevice` or `CoreAudioInputDevice` "Device … initialized" line in the client log.
- **Helper:** a `PVMicHelper` process, or "macOS microphone helper started" in the client log.
- **Voice:** BlackHole is the default input with a 440 Hz tone playing into it, and PV uses voice
  activation at -60 dB. A 10 s window with 100+ client-to-server UDP packets means voice got through
  (voice is ~500, keepalives ~10).
- **Denied:** "Microphone access is DENIED" in the client log.

## Things to know

- Permissions are preset by writing rows straight into the user's `TCC.db`, which runner images allow.
- The game starts through `open`, so launchd makes the stand-in its responsible process, as with a real
  launcher. Started from the job's shell, the runner's agent would be responsible instead.
- The prompt has no accessibility elements, so `answer-prompts.sh` clicks its buttons by position with a
  real mouse event (`click.c`).
- The game runs on Temurin from setup-java, not on the Java runtime the official launcher ships.
- The `macos-mic-<case>` artifact has the client and server logs, the TCC log stream, screenshots,
  client thread dumps and any crash reports. The job summary has the checks and the PV device log.
