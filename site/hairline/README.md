# Hero figure

`keys.js` is the keyboard drawn beside the hero: a Zhuyin keyboard whose keys
sink under the pointer, neighbours following less the farther they are. It is
written to the rules of the `hairline-create` skill from
[Hairline](https://github.com/lucasmarkes/hairline) (MIT, `LICENSE`), in the
skill's figure format, so the skill's checks run on it unchanged.

`kernel.js` is the skill's `kernel.js` from commit `bc78224`, with one line
appended (`export { HL };`) so Vite can import it. `../hero-figure.js` plays the
part of the skill's bench: it mounts the figure into `.hero-figure`.

To check the figure after a change, from any scratch directory:

```sh
git clone --depth 1 https://github.com/lucasmarkes/hairline /tmp/hairline
node /tmp/hairline/skills/hairline-create/look.mjs <repo>/site/hairline/keys.js \
  --answer 60,21,10 --edge 7,7,10 --edge 150,49,10
```

Known: the look reports the press moves 23% of the ink at 240px (it asks for
37%). A keycap's travel is short; deeper travel makes the caps read as towers.
