# Jot OpenAI (macOS)

**Hold fn. Speak. Release. Text appears at your cursor.**

Personal OpenAI-powered fork of [Jot by Ammaar Reshi](https://github.com/google-gemini/jot-gemini-transcribe-macOS). Original copyright Google LLC, Apache 2.0; modifications by Slava Staroverov. Independent project, not endorsed by OpenAI or Google.

## Changes from upstream

- Default speech-to-text: OpenAI **gpt-transcribe** (the earlier gpt-4o-transcribe is deprecated).
- Optional smart cleanup and per-app tone: OpenAI Responses API, model **gpt-6-luna**, with Jot's existing validation gate and raw transcript fallback.
- The original on-disk crash-safe recording, history and retry, customizable hotkey, vocabulary and guarded text insertion remain.
- Audio is sent to api.openai.com/v1/audio/transcriptions as multipart FLAC. Dictionary keywords are passed as recognition hints.
- Separate application ID (com.staroverov.jot-openai), storage folder, Keychain service, and jot-openai URL scheme. The original Jot installation is not overwritten or migrated.
- The experimental Gemini Live path is disabled. Live transcription using OpenAI is a future extension, not part of this build.
- An independent Developer ID is needed for public notarized downloads. This repository builds locally with an ad-hoc development signature.

## Build

Requires macOS 14+, Xcode 16+, Homebrew and xcodegen.

    brew install xcodegen
    git clone https://github.com/StaroverovVV/jot-openai.git
    cd jot-openai
    ./scripts/test.sh
    ./scripts/build.sh

The compiled Jot OpenAI.app is in Xcode DerivedData (Debug products). Copy it into Applications, launch it, grant Microphone and Accessibility in macOS settings, then open Settings → Advanced to add an OpenAI API key from https://platform.openai.com/api-keys.

**ChatGPT subscriptions and OpenAI API billing are separate.** You must supply an API key. It is kept in the macOS Keychain, never in the repository.

## Usage

Hold fn and release to transcribe. fn plus Space locks hands-free recording. Escape cancels. Other keys can be configured in Settings. Links for programmatic use: jot-openai://settings/advanced, jot-openai://history, jot-openai://dictionary.

Smart transcription on (default): one OpenAI audio transcription request, then a second cleanup call for removing filler and resolving self-corrections. A validation gate rejects unfaithful rewriting, falling back to the raw transcript. Smart transcription off: verbal transcription only (dictionary replacements still apply). Tone matching can request cleanup even when Smart is off.

## Privacy and limits

- The audio and optional vocabulary hints go directly to OpenAI. When Smart or Tone is enabled, transcript text goes to OpenAI a second time with Responses store=false.
- The OpenAI model sees the transcript, not app screen content or keystrokes. Local history stays on Mac until deleted.
- No paid API or audio end-to-end verification was possible without an API key; automated transport tests run offline using a mocked URLProtocol.
- Public distribution has not been signed or notarized by a new developer; local development builds are for the owner's Mac.
- The upstream Gemini implementation remains in the source tree for compatibility with original tests, but the fork runtime uses OpenAI only.

Full information: [Privacy](docs/PRIVACY.md).

## License and attribution

Apache License 2.0. Original Jot copyright and attribution preserved, including [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Original project: https://github.com/google-gemini/jot-gemini-transcribe-macOS.
