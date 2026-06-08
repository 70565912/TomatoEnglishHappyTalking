# Volc Ark Seedream Image API Notes

Source:

- Official API reference: https://www.volcengine.com/docs/82379/1541523?lang=zh
- Official examples: https://www.volcengine.com/docs/82379/1824692

Last checked: 2026-06-07

## Project Defaults

- Image provider: Volcengine Ark Images API.
- Endpoint: `https://ark.cn-beijing.volces.com/api/v3/images/generations`
- Auth: `Authorization: Bearer <ARK_API_KEY>`
- Local key file: `security/ark.txt`
- Default model: `doubao-seedream-5-0-260128`
- Default output: `response_format=url`, `output_format=png`, `watermark=false`
- Remote request size: `2560x1440`.
- Local stored picture-book size: original remote PNG, currently `2560x1440`.
- User-facing display frame: CSS/layout scales the image to the app's 16:9
  picture-book viewport, typically equivalent to `1280x720`.
- Picture-book generation policy: one image per article/chapter. The single
  page covers all sentence indexes in that chapter.
- Automatic reference-image generation is disabled by default to minimize API
  calls. Existing or new reference-image experiments require
  `TOMATO_PICTURE_BOOK_REFERENCE_IMAGES=true`.
- Visible text is allowed when it naturally belongs in the illustration, such
  as book-title lettering, signs, playing-card marks, labels, notes, or map
  details. Do not reintroduce a blanket text-free restriction.

`security/AccessKey.txt` is no longer used for picture-book image generation.
Do not restore the old Visual API / AK-SK fallback path.

## Request Shape

Minimum text-to-image request:

```json
{
  "model": "doubao-seedream-5-0-260128",
  "prompt": "A warm English picture-book chapter illustration based on this book and chapter story. Natural title lettering or story-world text may appear if useful.",
  "size": "2560x1440",
  "response_format": "url",
  "output_format": "png",
  "watermark": false,
  "sequential_image_generation": "disabled"
}
```

Reference image request:

```json
{
  "model": "doubao-seedream-5-0-260128",
  "prompt": "Use the reference only for character and style consistency.",
  "image": ["data:image/png;base64,..."],
  "size": "2560x1440",
  "response_format": "url",
  "output_format": "png",
  "watermark": false,
  "sequential_image_generation": "disabled"
}
```

Sequential/group request:

```json
{
  "model": "doubao-seedream-5-0-260128",
  "prompt": "Generate 4 coherent picture-book scene images...",
  "size": "2560x1440",
  "response_format": "url",
  "output_format": "png",
  "watermark": false,
  "sequential_image_generation": "auto",
  "sequential_image_generation_options": {
    "max_images": 4
  }
}
```

## Important Limits

- The official API uses API Key authentication, not AK/SK signing.
- Prompt supports Chinese and English.
- Prompt should stay concise; the official guidance recommends roughly no more
  than 300 Chinese characters or 600 English words.
- Supported `size` modes include `2K`, `3K`, `4K`, and explicit pixel sizes in
  the official API family. This app displays and caches `1280x720`, but
  Seedream 5.0 rejected remote `1280x720` in a real network probe with:
  `InvalidParameter ... image size must be at least 3686400 pixels`. Therefore
  the remote request uses the smallest 16:9 size that satisfies that limit,
  `2560x1440`. Save the original remote image locally and let the UI scale it
  down for display; do not do a second image-generation call for resizing.
- Live Flutter tests must clear `flutter_test`'s default `HttpClient` override
  before calling remote APIs. Otherwise every HTTP request is blocked locally and
  appears as HTTP 400, which must not be interpreted as an Ark API response.
- `doubao-seedream-5.0-lite`, `doubao-seedream-4.5`, and
  `doubao-seedream-4.0` support reference images; the official docs state up to
  14 reference images for these models.
- Reference image data URI format must be like
  `data:image/png;base64,<base64_image>`.
- Sequential generation uses `sequential_image_generation: "auto"` and
  `sequential_image_generation_options.max_images`.

## Prompt Rules For This App

- Generate one picture-book illustration per chapter/article, not one image per
  paragraph or sentence. `picture_book_pages` is still used as the storage table,
  but normal generation writes a single page with `pageIndex=0`,
  `sentenceStartIndex=0`, and `sentenceEndIndex` covering the final sentence.
- Base the prompt on the book/series title, chapter title, and condensed current
  chapter story. Prioritize the current chapter over unrelated earlier-chapter
  characters or settings.
- Visible text is allowed when it naturally belongs in the story world. The app
  overlays subtitles separately, so generated text should be optional decoration
  or atmosphere, not the only way to understand the scene.
- Keep the book or series name in the prompt when available, but never hard-code
  one specific book title globally.
- For public-domain classics, include the current book title and chapter
  context to improve character accuracy.
- Use local safe prompt templates by default. Do not call Ark text generation
  once per chapter in normal runtime. AI chapter-prompt refinement is an explicit
  experiment switch: `TOMATO_PICTURE_BOOK_AI_PAGE_PROMPTS=true`.
- Series bible AI updates are also opt-in:
  `TOMATO_PICTURE_BOOK_AI_SERIES_BIBLE=true`.
- Automatic style/character reference-image generation is also opt-in:
  `TOMATO_PICTURE_BOOK_REFERENCE_IMAGES=true`. Default production flow should
  spend one image call per chapter when the cache is cold.
- Sequential/group image generation is also opt-in:
  `TOMATO_VOLC_IMAGE_GROUP_PAGES=true`. A 2026-06-07 Alice full-flow run found
  4-image sequential requests could exceed the 120 second receive timeout and
  then fall back to single-image generation, which risks wasting calls.
- That fallback run is not a valid visual-quality comparison for true group
  output, because the ready page images were generated by the app's single-image
  fallback. A dedicated no-fallback 2-image group probe on 2026-06-07 was blocked
  by Ark with `HTTP 429 SetLimitExceeded`, saying the account reached the
  inference limit for `doubao-seedream-5-0` and the model service was paused by
  Safe Experience Mode. Do not claim group image quality or continuity has been
  verified until that account limit is lifted and a no-fallback group probe
  succeeds.
- Convert risky story wording into safe visual descriptions before sending the
  prompt. Preserve scene intent, character emotion, and action, but avoid direct
  harmful or violent wording.
- Cache every successful remote result with model, remote size, output format,
  prompt version, reference hashes, and series/page metadata in the cache key.
- Do not cache failed responses, request headers, API keys, or mock fallback
  results.
