# Privacy — Jot OpenAI fork

This independent fork uses OpenAI, not Gemini, as its runtime speech service.

## Data sent to OpenAI

1. The FLAC recording of each dictation is uploaded directly over HTTPS to api.openai.com/v1/audio/transcriptions, authenticated with your personal API key.
2. Selected dictionary terms are sent as keywords to improve correct spelling.
3. When Smart transcription or tone matching is enabled, the recognized text plus cleanup instructions are sent to the OpenAI Responses API at api.openai.com/v1/responses. The request specifies store=false. Tone matching also includes a coarse category such as professional email or chat, not the contents of the app window.
4. The API key is transmitted as an Authorization HTTP header, not as a URL parameter. It lives in the macOS Keychain under a new service identity for this fork.

## Data stored on the Mac

Recording history, CAF master audio, transcriptions and metadata stay inside the Jot OpenAI application support folder. Individual recording audio may be deleted after the configured retention period; transcript history persists until deletion in Settings. The vocabulary database is local, except for the terms sent as hints. Files have no extra encryption beyond macOS/FileVault. Screenshots, full screen content, unrelated typed text and general keystrokes are not sent to OpenAI by this app.

Jot OpenAI has separate application preferences, Keychain service and files from the upstream original Jot. It does not migrate or delete existing original Jot data.

## Data policies and consent

Use of OpenAI API is governed by [OpenAI API data policies](https://openai.com/policies/api-data-usage-policies/). A ChatGPT subscription does not include unlimited API transcription. Avoid recording confidential coaching conversations or other protected personal data unless you have suitable consent and data handling arrangements.

OpenAI Live streaming transcription is not implemented in this fork. Files are uploaded when the dictation ends. The project is not endorsed by OpenAI or Google.

This project retains Jot's Apache 2.0 license and original attribution.
