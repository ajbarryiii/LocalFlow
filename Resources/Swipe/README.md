# Swipe typing licenses

The iPhone keyboard's swipe bundle (`SWIPE_BUNDLE_DIR`, see `iOS/README.md`)
is copied into `LocalFlowKeyboard.appex/Swipe/` together with these files:

- `LICENSE-AOSP-wordlist.txt`: the Apache License 2.0 notice of the Android
  Open Source Project's English word list, from which the swipe lexicon
  (`lexicon.bin`: the words and their frequencies) is built.
- `LICENSE-swipe-data.txt`: the MIT License of the swipe.futo.org swipe
  dataset (FUTO), on which the swipe encoder model (`SwipeEncoder.mlmodelc`)
  was trained.

The model and the lexicon themselves stay outside Git.
