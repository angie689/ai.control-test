# AI Control test

A native **iPhone text-based AI app** that uses a remote small language model (SLM) for generating replies, while keeping its **agents, virtual applications, tools and sandbox on the iPhone**.

No computer or local model installation is needed on the iPhone. GitHub Actions builds an unsigned IPA inside a ZIP for SideStore.

## What the iPhone IPA can do

- Chat with a hosted SLM (a separate inference gateway is required).
- Clone and switch between up to 8 agents with independent conversations.
- Run calculator, notes, tasks, virtual text workspace, and allowlisted HTTPS reader **inside the IPA**.
- Import **.aicapp** / JSON app packages directly from iPhone Files using **Apps → Import app from Files**.
- Review each imported app's requested virtual operations before installing.
- Disable, re-enable or swipe to delete imported apps.
- Use imported app actions through the AI's **app_action** tool, subject to local policy.
- Keep local sandbox state in the app's protected Documents storage. The SLM only receives relevant message/tool text; it cannot run iPhone tools itself.

**Important:** These are declarative *virtual sandbox apps*, not executable iOS .ipa packages. iOS does not permit loading another independently built IPA inside this app. Imports never run arbitrary code, install system apps, access other iPhone apps, or change the AI sandbox's permissions.

## Import a sample app from iPhone

A ready-to-import example lives at [examples/Flashcards.aicapp](examples/Flashcards.aicapp).

1. Save **Flashcards.aicapp** to iPhone Files (GitHub's raw file/download option).
2. In AI Controller, tap **Apps**.
3. Tap **Import app from Files**, then choose the file.
4. Review its allowed virtual operations and tap **Install**.
5. Tell the AI: "Use Flashcards to save a card named gravity with an explanation."

Imported apps support ONLY a predefined set of operations: list, read, write, append, delete. Records are separate for each agent and app. A user must explicitly import an app; it cannot install itself.

### .aicapp JSON format

~~~json
{
  "format": 1,
  "id": "my_notes",
  "name": "My Notes App",
  "description": "A notebook with isolated virtual records.",
  "actions": [
    {
      "id": "save",
      "title": "Save Note",
      "description": "Save text under a key.",
      "operation": "write"
    },
    {
      "id": "list",
      "title": "List Notes",
      "description": "List all saved keys.",
      "operation": "list"
    }
  ]
}
~~~

Packages must be 32 KB or smaller, with 1-12 actions and no executable instructions. Imports are strictly validated; only 12 imported apps can be installed. Virtual records are limited to 30 per agent/app and 4000 characters per record. Apps may be disabled or deleted.

## Build the iPhone app

1. Open [Build iPhone IPA ZIP — GitHub Actions](https://github.com/6tpndfmcck-crypto/ai-controller-thing/actions/workflows/ios-ipa.yml) in iPhone Safari.
2. Choose the latest successful run.
3. Download its **AIController-IPA-ZIP** artifact.
4. Unzip the GitHub artifact, and use the included **AIController-IPA.zip** with SideStore. That inner ZIP contains AIController.ipa.
5. Install with SideStore. An Apple distribution signing certificate is not included.

You can use the app's local Apps and agent-management screens even before connecting a model. AI chats and model-selected tool actions require configuring an SLM gateway.

## Server-hosted SLM (inference only)

The remote service only returns an assistant message or tool-call suggestions. **It never executes tool calls and has no sandbox app data.** The IPA executes each permitted tool itself and sends text results back to the SLM.

The included Python gateway is **server.py**. It requires Python 3.11+, a secret AI_CONTROLLER_TOKEN, and one of:

- Hosted: set OPENROUTER_API_KEY and OPENROUTER_MODEL to a model available to that account that supports tool calling.
- Self-hosted: an Ollama model available at 127.0.0.1:11434. This requires a separate machine, not the phone.

The gateway must be served through HTTPS for iOS. A cloud host such as Render may be used for the small inference gateway; it does not host the sandbox or run Ollama. Hosting or API model usage may have fees or rate limits.

On a managed cloud service, start the gateway with:

~~~sh
python3 server.py
~~~

Provide AI_CONTROLLER_TOKEN (random 24-256 characters) and OPENROUTER_API_KEY as private environment variables, NOT in the repository. For Render, the gateway listens on its PORT with HTTPS provided by Render's ingress. Do not expose raw Ollama ports.

After deployment, enter the gateway HTTPS origin and AI_CONTROLLER_TOKEN into **AI Controller → Settings**. The token is kept in iOS Keychain. This repository does **not** automatically deploy a hosted model or supply API credentials.

The gateway supports only these endpoints:
- GET /health (unrestricted status check)
- GET /api/state (authenticated model/tools metadata)
- POST /api/complete (authenticated stateless inference)

There are no remote endpoints for cloning agents, storing notes, installing apps, or running tools.

## Sandboxing and limits

The tools are *capability-limited*, not a virtual machine. The IPA cannot execute arbitrary programs. The imported apps can only access their own virtual records. The built-in web reader uses allowlisted hostnames (docs.python.org and en.wikipedia.org), TLS, GET requests, and redirect refusal. Do not treat the web-reader as an OS-level network sandbox; imported packages cannot access the network directly.

The on-device records and chat logs are stored in the app's protected Documents directory. They survive app relaunches but not removal of the app and its data. Remote inference sends user messages and relevant context to the chosen model provider.

The sandbox and the remote inference gateway do not create autonomous background agents; each agent works when you select it and send a message.

## Tests

~~~sh
python3 -m unittest discover -v
~~~

The tests mock the SLM and validate the gateway; GitHub Actions compiles the native iOS app and packages its IPA. A successful build does not establish that every imported app or model combination works on a physical iPhone.

Codex's original Python CLI prototype is kept in app.py, but the IPA has its own locally enforced sandbox.
