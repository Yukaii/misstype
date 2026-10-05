# Feel comparison protocol (blind typing, macOS)

Goal: compare how much correcting a user actually does, which the headless
numbers cannot capture. One person, one Mac, both IMEs installed with their
fresh-install defaults (note any setting you change, e.g. 注音狂打 on).

## Setup
1. Pick 10 sentences from `probes.tsv` (mix of 5–12 syllables). Same list, same
   order for both IMEs; alternate which IME goes first each round.
2. A plain text field (TextEdit, plain text). Screen recording on, so keystrokes
   and fixes can be counted afterwards instead of tallied by hand.
3. Two passes per sentence, each 10 sentences:
   - **Normal**: type at a comfortable speed, looking at the screen.
   - **Blind**: eyes closed or screen covered until the sentence is finished
     (the project's starting scenario: continuous input recovered afterwards).

## Record per sentence (spreadsheet, one row each)
| field | how |
| --- | --- |
| ime, mode (normal/blind), sentence id | |
| wrong_chars | characters in the result that differ from the target (edit distance) |
| fix_keystrokes | Backspace/Delete/arrow/candidate-pick presses needed to reach the target |
| restarted | 1 if you deleted back to the start and retyped |
| seconds | first key to final correct text |

`fix_keystrokes` is the "correction burden": counted from the recording, not
estimated. Count a candidate pick as one keystroke and re-opening the
candidate window as one more.

## After each pass (1–5)
- smoothness (did it interrupt me?), trust (would I keep typing without looking?),
  want-to-keep-using.

## Report
Mean wrong_chars, mean fix_keystrokes, restarts, seconds, and the three scores
per IME and mode; list anything you changed from defaults. With n = 10 per cell
treat differences below about one character per sentence as noise. Do not
publish raw typed text: only sentence ids from the synthetic `probes.tsv`.
