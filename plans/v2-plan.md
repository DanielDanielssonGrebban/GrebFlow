# GrebFlow V2 plan

Status: optional follow-up work. Start only after the [V1 core plan](core-plan.md#validation-and-acceptance) acceptance checks pass and the app is demo-ready. These features are not required for the hackathon demo.

## Version 2 and later

1. Shareable app build through GitHub Releases. Begin with an installable app archive or DMG, then signing and notarization for straightforward installation. Check Developer ID access, Gatekeeper behavior, stable app identity, and a clean Mac's permission onboarding. Do not promise that an unsigned download opens without extra steps.
2. Manual Swedish selection, after checking downloadable DictationTranscriber assets and latency/accuracy. Automatic English/Swedish detection and mixed-language speech need separate evaluation and may require another engine. Do not assume locale selection is automatic language detection. [Apple language support](https://developer.apple.com/documentation/speech/speechtranscriber)
3. Automatic weekly reports with a local notification or chosen delivery channel. Decide what happens when the app is closed, offline, or asleep before implementing scheduling.
4. Optional filler cleanup, custom developer vocabulary, report streaming, exclusion controls, and richer evidence navigation. Keep any cleanup outside the default low-latency dictation path until measured.
5. Optional "Mute other audio while recording" setting, off by default. Mute playback when right Option starts an authorized recording and restore it on release, without waiting for transcription or paste. Leave the microphone active. A basic device mute is small, but reliable restoration and output-device coverage need additional work, so this belongs in version 2.

## Output muting requirements

For output muting, use Core Audio to query the active output device's kAudioDevicePropertyMute and check that it exists and is settable before changing it. Preserve the original state of each device GrebFlow changes; never unmute an already-muted device or change its volume. Restore on release, cancellation, capture failure, sleep, and normal quit. Handle output-device changes and respect user adjustments while recording. Define recovery for an interrupted session without promising restoration after a force quit or crash. If a device cannot be muted, indicate that limitation and let dictation continue.

Start with the default playback device and account for a separate system-alert output. Other apps can use different output routes, so label device coverage honestly rather than promising all sound on every configuration. Test speakers, headphones, Bluetooth route changes, and unsupported external outputs. Muting playback does not pause the music or video. Do not add system-audio capture, a virtual audio driver, or per-app playback automation just for this setting. [Core Audio mute property](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertymute), [checking whether a property is writable](https://developer.apple.com/documentation/coreaudio/audioobjectispropertysettable(_:_:_:))
