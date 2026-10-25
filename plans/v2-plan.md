# GrebFlow V2 plan

Status: optional follow-up work. Start only after the [V1 core plan](core-plan.md#validation-and-acceptance) acceptance checks pass and the app is demo-ready. These features are not required for the hackathon demo.

## Version 2 and later

1. Developer-friendly transcription and vocabulary. Prioritize recognizing terms such as json, TypeScript, npm, and project names without corrupting ordinary speech. Compare native vocabulary hints and local corrections as described below. This is important early V2 work, not a V1 requirement.
2. Shareable app build through GitHub Releases. Begin with an installable app archive or DMG, then signing and notarization for straightforward installation. Check Developer ID access, Gatekeeper behavior, stable app identity, and a clean Mac's permission onboarding. Do not promise that an unsigned download opens without extra steps.
3. Manual Swedish selection, after checking downloadable DictationTranscriber assets and latency/accuracy. Automatic English/Swedish detection and mixed-language speech need separate evaluation and may require another engine. Do not assume locale selection is automatic language detection. [Apple language support](https://developer.apple.com/documentation/speech/speechtranscriber)
4. Automatic weekly reports with a local notification or chosen delivery channel. Decide what happens when the app is closed, offline, or asleep before implementing scheduling.
5. Optional filler cleanup, report streaming, exclusion controls, and richer evidence navigation. Keep any cleanup outside the default low-latency dictation path until measured.
6. Optional "Mute other audio while recording" setting, off by default. Mute playback when right Option starts an authorized recording and restore it on release, without waiting for transcription or paste. Leave the microphone active. A basic device mute is small, but reliable restoration and output-device coverage need additional work, so this belongs in version 2.

## Developer-friendly transcription

First compare the V1 SpeechTranscriber with DictationTranscriber using developer phrases and ordinary speech. Measure recognition accuracy and release-to-paste latency before changing engines. Keep recognition local and preserve the V1 permission, session, and paste safeguards.

Apple documents vocabulary hints through AnalysisContext.contextualStrings for DictationTranscriber, not the planned SpeechTranscriber. Verify support against the installed SDK before implementation. Supply short developer terms and project names, with no more than 100 phrases as Apple recommends. Hints improve recognition likelihood but do not guarantee exact spelling or capitalization. Consider a custom language model with pronunciations only if the initial comparison shows a need. [Apple vocabulary guidance](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings)

Evaluate a small editable local dictionary for preferred spelling, capitalization, and explicit user-defined corrections before paste. Make corrections optional and match whole words or phrases rather than arbitrary substrings. Do not ship a blanket Jason-to-json replacement: "Ask Jason to review this" must remain valid ordinary speech. Preserve the original recognized text alongside corrected insertion text using the existing history fields.

Test phrases such as "parse the json response," "run npm install," and "Ask Jason to review the TypeScript changes." Include ambiguous names, punctuation, capitalization, and words that contain a dictionary term as a substring. Verify that corrections add no line breaks, submit events, or meaningful delay. Do not add an LLM rewrite to the default dictation path.

## Output muting requirements

For output muting, use Core Audio to query the active output device's kAudioDevicePropertyMute and check that it exists and is settable before changing it. Preserve the original state of each device GrebFlow changes; never unmute an already-muted device or change its volume. Restore on release, cancellation, capture failure, sleep, and normal quit. Handle output-device changes and respect user adjustments while recording. Define recovery for an interrupted session without promising restoration after a force quit or crash. If a device cannot be muted, indicate that limitation and let dictation continue.

Start with the default playback device and account for a separate system-alert output. Other apps can use different output routes, so label device coverage honestly rather than promising all sound on every configuration. Test speakers, headphones, Bluetooth route changes, and unsupported external outputs. Muting playback does not pause the music or video. Do not add system-audio capture, a virtual audio driver, or per-app playback automation just for this setting. [Core Audio mute property](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertymute), [checking whether a property is writable](https://developer.apple.com/documentation/coreaudio/audioobjectispropertysettable(_:_:_:))
