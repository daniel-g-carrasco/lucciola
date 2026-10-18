# Lucciola website

One static page, `index.html`, with no build step: the home page and the guide are two views of the same document (`#guide`, guide sections as `#g-...`). Fonts come from Google Fonts; everything else is inline.

Changes here do not trigger an image build (`site/**` is in `build.yml`'s `paths-ignore`).
