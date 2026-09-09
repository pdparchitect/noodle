# Voice messages

On macOS 26, click the microphone beside Send. Noodle checks Apple's on-device
SpeechTranscriber support for the current system language and installs the
system-managed speech model if needed. Microphone permission is requested only
after an explicit recording action. No cloud transcription fallback is used.

Choose the recording microphone in Settings → General. System Default follows the
Mac's current input; choosing a named microphone affects Noodle only and takes
effect on the next recording. Device choices survive relaunch. An unavailable
selection requires choosing another device, rather than silently recording from
a different microphone. A flat input for three seconds shows a no-sound warning;
check the hardware mute switch or select another microphone. Recording uses the
same 36-point height and glass surface as the empty text composer.

The composer displays a waveform and elapsed time while recording. Return stops,
finalizes transcription, and sends a voice message. Stop ends recording without
sending; Return then sends the ready recording. Escape or × discards it. Recording
stops after ten minutes without automatically sending. Unsupported devices or
languages and denied permission show an actionable error, leaving text chat usable.

Switching conversations stops recording and retains the unsent audio/transcript
with that conversation. Existing text and file drafts are untouched. Audio and a
small draft manifest live under that conversation's `Attachments/VoiceDraft`.
Completed and interrupted recordings can be reopened after relaunch; an incomplete
transcript is never treated as final. A transcription failure keeps the recording
and offers Retry Transcription or explicit Send Audio Only. A failed send keeps the
draft. These files are removed only when discarded or successfully sent.

The saved message has one audio attachment. Its optional `voice` metadata stores
the transcript, locale, duration and waveform. Every harness receives that metadata
through Messenger; the visible chat shows a compact player, not a transcript text
bubble. Right-click and choose Show Transcript to read/copy the words. Playback is
paused when the player leaves view, and starting another player pauses the first.
The attachment's audio file remains available for Quick Look and Show in Finder.

## Permissions and tests

The only added entitlement is `com.apple.security.device.audio-input` on the main
app, with `NSMicrophoneUsageDescription`. No agent helper receives microphone
access, no sandbox boundary is relaxed, and no recording starts at launch.
Apple model installation uses the already-enabled outbound network access.

- `swift test --disable-sandbox`: metadata validation, legacy decoding, persistence,
  agent delivery and documentation encoding coverage, plus existing regressions.
- `zsh Tests/voice-recording.sh`: synthetic audio conversion, waveform, restored
  draft states and narrowly scoped discard; no microphone access.
- `zsh Tests/voice-recording.sh --transcribe <synthetic-spoken-audio>`: actual
  on-device file and live-buffer transcription; may install Apple's speech assets.
- `zsh Tests/voice-composer.sh`: isolated Return/Escape UI fixture without a store
  or real conversation. It briefly opens a test window.
- `zsh Tests/voice-sandbox.sh`: signed, hardened sandboxed synthetic speech test;
  the fixture has no microphone entitlement and cannot capture ambient audio.

Manually verify microphone permission allow/deny, a real recording, switching
chats while speaking, audio playback, and a send to a real bot in the signed app.
