INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
NO LICENCE IS GRANTED. See LICENCE.txt.

# Ingenium on a Fire tablet, an Android device, an iPhone or an iPad

This repository builds two installable apps in the cloud. Each one is a
standalone app: the engine that runs the models is inside it, two models are
built into it (from version 3.0), and it works with no connection at all.

| App file | For | Built-in models |
| --- | --- | --- |
| `Ingenium-Android-Fire.apk` | Fire tablets, Android tablets and phones | LFM2.5 1.2B Instruct (731 MB) and LFM2.5 1.2B Thinking (731 MB) |
| `Ingenium-iPhone-iPad-unsigned.ipa` | iPhone and iPad | LFM2.5 1.2B Instruct (731 MB) and Qwen3.5 2B (1.28 GB) |

The first model of each pair answers quickly (the house Velox); the second
thinks before it answers (the house Scriba), and the chat shows its thinking.
Two more houses, Magister (the strongest the device holds) and Faber (the
coding model), install from the Models page with one tap. A model in another
form (safetensors, PyTorch, MLX) can be converted to GGUF on the device, under
Convert a model on the same page.

Each also comes in a copy without the built-in models
(`Ingenium-Android-Fire-no-model.apk`, about 25 MB, and
`Ingenium-iPhone-iPad-no-model-unsigned.ipa`, about 5 MB). See **Removing a model** below
for when that copy is useful.

Each device gets the models that suit it. Fire tablets usually have 2 to 4 GB
of memory and run models on the processor alone, so they get two compact
models. iPhones and iPads have more memory and a graphics chip the engine
uses, so their thinking model is the larger Qwen3.5 2B.

## Where the files are

Open this repository on GitHub and choose **Releases** (on the right of the
main page, or add `/releases` to the address). The release named
**Ingenium (latest build)** holds all four files. Each new build replaces them.

This repository is private, so GitHub only gives the files to someone who is
signed in. On the tablet, sign in to GitHub in the browser first.

**Which build you have.** In the app, tap **About** at the top right (the
round key with an "i" on a phone). It shows the version and the build number,
for example "Version 2.1 · build 20261002.7". The release's description lists
the same number for each app, so you can see that the newest build is the one
installed.

## Fire tablet or Android device

1. On the tablet, open Silk (or another browser) and sign in to GitHub.
2. Open this repository's Releases page and tap **Ingenium-Android-Fire.apk**.
   It is a large download (about 720 MB), so use Wi-Fi.
3. Allow installing apps from this source when asked. On a Fire tablet this
   is Settings, then Security and Privacy, then **Apps from Unknown Sources**,
   for Silk or for the Docs app. You may turn it off again afterwards.
4. Open the downloaded file and tap **Install**, then **Open**.

A newer build installs over an older one and keeps your models and your work,
because every build is signed with the same key (see `signing/SIGNING.txt`).

## iPhone and iPad

Apple does not allow any app onto an iPhone or iPad unless it is signed with
an Apple ID. This is a rule of Apple's, and no build can avoid it. The file
on the Releases page is therefore unsigned, and you sign it once on a
computer with your own Apple ID. Two free tools do this:

* **Sideloadly** (Windows or Mac): https://sideloadly.io
* **AltStore** (Windows or Mac): https://altstore.io

The steps with Sideloadly, in outline. Please follow the tool's own guide
too, because its screens change between versions.

1. On the computer, download **Ingenium-iPhone-iPad-unsigned.ipa** from the
   Releases page.
2. Connect the iPhone or iPad with a cable and unlock it.
3. Open Sideloadly, drop the file onto it, enter your Apple ID, and start.
4. On the device, open Settings, then General, then **VPN and Device
   Management**, and trust your Apple ID.
5. On iOS 16 and later, also turn on **Developer Mode** (Settings, then
   Privacy and Security) when the device asks for it, and restart.

What to know about signing with a free Apple ID:

* The signature lasts **7 days**. After that the app will not open until you
  sign it again (Sideloadly or AltStore can do this; AltStore can refresh by
  itself when the computer is on the same Wi-Fi). Installing again over the
  old copy keeps your models and your work.
* A free Apple ID can have 3 such apps on a device at once.
* A paid Apple Developer membership (99 US dollars a year) makes the
  signature last a year.

These limits are Apple's and may have changed since this was written; the
Sideloadly and AltStore sites describe the current ones.

## Using your own models

Ingenium runs models in the **GGUF** format. Most models on Hugging Face are
offered as GGUF; choose a file whose name contains `Q4_K_M` for a good balance
of size and quality.

**Adding a model.** Open the Models page and tap **Tap here to add a model
file (.gguf)**. Choose the file (for example from Downloads). Ingenium copies
it into its own library, so it stays ready even if the original is moved or
deleted. You may add several at once. Files that are not GGUF models are
refused with the reason.

On iPhone and iPad there is a second way: the Files app shows **On My iPhone
(or iPad), Ingenium, Models**. A `.gguf` file placed there appears in
Ingenium the next time the Models page is opened.

**Choosing a model.** Tap **Set active** on its card. The chat loads it the
first time you send a message.

**Removing a model.** Tap **Remove** on its card and confirm. Its copy is
deleted and the space comes back. The built-in model can be **hidden** the
same way; it stays inside the app, because an installed app cannot shrink,
and a **Bring it back** button returns it whenever you like.

To remove the built-in model completely and get its space back, install the
copy without the built-in model (the `no-model` file, from the same build or
a newer one) over the full app. It is the same app with the same signature,
so it installs as an update and the models you added stay. Installing the
full app again later brings the built-in model back. On iPhone and iPad, sign
the `no-model` file with the same tool and the same Apple ID as before, so
that it replaces the app as an update. That step on iPhone and iPad has not
been tried on a real device.

**Which sizes fit.** As a rough guide for GGUF files at Q4:

| Device memory | Comfortable model size |
| --- | --- |
| 2 GB | up to about 1B parameters (under 0.8 GB) |
| 3 to 4 GB | up to about 1.5B parameters (about 1 GB) |
| 6 GB and more | up to about 4B parameters (about 2.5 GB) |

These are approximate. The app's Models page shows how much memory your
device reports and marks each model as fitting or too heavy.

A model that is too large for the device's memory will fail to load or will
be very slow. The Models page warns you before that happens.

## What runs where

* The interface is the same Ingenium page as on the computer.
* The engine is llama.cpp, compiled for each device. It uses up to four
  processor cores, and on iPhone and iPad it also uses the graphics chip. If
  the graphics chip cannot load a model, the iPhone and iPad app uses the
  processor instead. The Fire and Android app carries the engine's processor
  part built for each generation of 64-bit ARM chip (plain, with the
  dot-product instructions, with the 8-bit matrix instructions, and the
  newer v9 ones) and loads the fastest one the device supports.
* In a long chat the engine keeps what it has already read. For models that
  cannot cut their memory back (LFM2.5 and Qwen3.5 are such models), it
  saves a checkpoint near the end of each message and carries on from it.
* Each model answers with the settings its makers recommend in its model
  card (temperature, top-k and penalties).
* Files attached with the + key can be text, code, Word documents or PDFs,
  read on the device. A file longer than the model's memory keeps its opening
  and passages from across it, and each message brings the passages that
  best match it.
* Models are read straight from where they are kept. The built-in model is
  read from inside the app package itself, so it never takes space twice.
* A computer can carry the weight. A Mac mini, or any computer running the
  Ingenium app, can lend its stronger models over your home Wi-Fi: on that
  computer, Settings, Your models on every device, switch on sharing; on the
  tablet or phone, enter the address and pairing code it shows in the same
  card and tap Connect. The chat then uses the computer's models (replies
  come from its engine), and the source row under the chat switches back to
  the device's own. Nothing leaves the home network.
* The apps run their models with no connection. They use the network only
  when you ask: a connection you set up in Settings (another computer running
  Ingenium, Ollama, or Claude), Web search or Research switched on with the
  + key beside the message box, or a file fetched from GitHub. The Android
  app has the internet permission for this; the iPhone and iPad app may ask
  once to find devices on your local network (for another computer running
  Ingenium or Ollama). Each app's test on GitHub also tries the internet once
  (Wikipedia) and reports it.
* Pictures (vision models) are not supported by the app engine yet; text chat,
  the Thinking switch and stopping a reply all work.

## How the apps are built and checked

Two workflows in `.github/workflows` do the work on GitHub's computers:

* **Build Ingenium for Fire and Android** compiles the engine for every kind
  of Android processor, packs the app with its model, installs it on an
  Android emulator, asks the built-in model a question, and only then
  publishes the APK.
* **Build Ingenium for iPhone and iPad** does the same on a Mac, with the
  iPhone simulator, and then publishes the unsigned IPA.

They run after each change that concerns them. To run one by hand, open the
**Actions** tab, choose the workflow, and press **Run workflow**. For the
iPhone and iPad build, ticking **Also photograph the app** there also starts
the app in an iPhone and an iPad simulator and keeps pictures of each page
with the run (under **Artifacts**); it adds about 4 minutes.

On a private repository, GitHub's free plan gives 2,000 build minutes a
month, and minutes on a Mac count ten times. The first two iPhone builds took
about 14 and 16 minutes, so each used roughly 140 to 160 minutes of the
allowance. Later builds reused the engine from GitHub's build cache and took
about 7 minutes, roughly 70 allowance minutes. Android builds run on Linux, take about 25 minutes and count once. A change to these
guides (the `.md` files) starts no build at all. Keep the repository private:
its files are the app's. (The signing key is kept in its secrets, never in its files: `signing/SIGNING.txt`.) These are GitHub's terms at the time of writing and may
have changed; the account's **Settings**, then **Billing**, shows the current
ones.

## What has and has not been tested

Tested: the engine on Linux with several models, the Android app's native
bridge against the real APK, the iPhone app's engine code with Swift on Linux,
and the page with a simulated app bridge in Chromium. The cloud builds then
test each finished app: on an Android emulator and in the iPhone simulator,
the app starts, loads its built-in model and is asked "What is the capital of
France?". In the first builds both answered "Paris". The Android build also
checks that the copy without the built-in model installs over the full app
and opens.

Not yet tested: a physical Fire tablet, iPhone or iPad. The emulator and the
simulator run on shared cloud computers, and the iPhone simulator cannot use
the graphics chip, so their speeds say little about your devices. Speed and
memory on your own devices are therefore not yet measured. If anything goes
wrong on a device, the Models page's **Run a system check** shows what the
device reports.
