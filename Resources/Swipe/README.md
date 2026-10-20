# Swipe typing licenses

The iPhone keyboard's swipe bundle (`SWIPE_BUNDLE_DIR`, see `iOS/README.md`)
is copied into `LocalFlowKeyboard.appex/Swipe/` together with these files:

- `LICENSE-AOSP-wordlist.txt`: the Apache License 2.0 notice of the Android
  Open Source Project's English word list, from which the swipe lexicon
  (`lexicon.bin`: the words and their frequencies) is built.
- `LICENSE-swipe-data.txt`: the MIT License of the swipe.futo.org swipe
  dataset (FUTO), on which the swipe encoder model (`SwipeEncoder.mlmodelc`)
  was trained.
- `LICENSE-spelling-data.txt`: credits for autocorrect's spelling tables
  (`autocorrect/spelling.lfwe`, when the bundle has them): Wikipedia's
  "Lists of common misspellings" (CC BY-SA 4.0) and the Aalto typing37k
  dataset (Palin et al. 2019). Only aggregated edit probabilities ship.

The model and the lexicon themselves stay outside Git.
