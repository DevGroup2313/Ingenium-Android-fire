INGENIUM  |  Copyright (c) 2026 Yannie D. Forest. All rights reserved.
NO LICENCE IS GRANTED. No copying, adaptation, redistribution, reverse
engineering or commercial use without the author's written permission.
See LICENCE.txt. Every distributed copy carries a build marker.
--------------------------------------------------------------------------

INGENIUM ON YOUR FIRE TABLET, ANDROID DEVICE, IPHONE OR IPAD
============================================================

The short version
-----------------
This repository builds the apps for you on GitHub. Open the repository's
Releases page, find "Ingenium (latest build)", and take:

  Ingenium-Android-Fire.apk            for a Fire tablet or Android device
  Ingenium-iPhone-iPad-unsigned.ipa    for an iPhone or iPad

Each app is standalone: the engine and a model are inside it, and it works
with no connection. You can add your own GGUF models and remove them, and
hide or bring back the built-in one.

The full steps, including how Apple's signing rule works for iPhone and
iPad, are in INSTALL_MOBILE.md.


The browser route (no install)
------------------------------
ingenium.html in this folder is the whole application in one file, and it
now carries its engine inside it. Open it in a browser and it runs models
you choose, offline. On a tablet a browser is slower than the app, because
it can use only one processor core; the app above uses up to four.


What is in this repository
--------------------------
  ingenium.html                  the application (engine inside) for browsers
  INSTALL_MOBILE.md              installing and using the apps
  ingenium_android_project/      the Android and Fire app
  ingenium_ios_project/          the iPhone and iPad app
  native/                        the engine both apps share (llama.cpp)
  mobile_models.json             which model each app carries
  tools/                         small build helpers
  .github/workflows/             the cloud builds
  signing/                       the signing keys in one encrypted file, and the old key (seen in public) until the new one signs (see SIGNING.txt)
  licences/, THIRD_PARTY_NOTICES.txt   licences of the parts Ingenium uses
  bake_engine.py                 re-bakes the engine into ingenium.html
