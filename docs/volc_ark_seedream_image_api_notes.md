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
- Picture-book generation policy: one sequential image group per
  article/chapter. Each confirmed v4 scene maps to exactly one
  `picture_book_pages` row and one returned image.
- Picture-book prompt v4 does not pass reference images. Book-level continuity
  comes from the editable book description plus the confirmed chapter plan.
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

- Generate one coherent picture-book image sequence per chapter/article. The
  confirmed v4 plan has at most 14 scenes; image 1 maps to scene 1, image N
  maps to scene N, and the app does not use the group as candidate alternatives.
- `picture_book_pages` stores one row per confirmed scene, with
  `sentenceStartIndex` and `sentenceEndIndex` covering that scene. All rows
  together must cover the full chapter sentence range.
- Base each prompt on the book/series title, book description, chapter title,
  current v4 scene, story brief, and chapter brief. Prioritize the current
  chapter over unrelated earlier-chapter characters or settings.
- Visible text is allowed when it naturally belongs in the story world. The app
  overlays subtitles separately, so generated text should be optional decoration
  or atmosphere, not the only way to understand the scene.
- Keep the book or series name in the prompt when available, but never hard-code
  one specific book title globally.
- For public-domain classics, include the current book title and chapter
  context to improve character accuracy.
- Prompt review uses `picture_book_prompt_v4` /
  `picture_book_chapter_plan_v4`. It produces editable `storyBrief`,
  `chapterBrief`, `scenes[]`, and `groupPrompt`, then waits for
  `pictureBook.confirmPromptReview` before submitting any image request.
- Do not restore the old series bible, character-card, or reference-image
  switches. Default cold-cache production flow should spend one v4 planning text
  call and one sequential image-group call per confirmed chapter.
- When the current cloud provider is Volcengine, `PictureBookImageService`
  dispatches to `VolcImageService.generatePictureBookImageGroup(...,
  useSequential: true)` for the product flow. It sets
  `sequential_image_generation_options.max_images` to the confirmed scene count
  and does not fall back to single-image generation or another provider when
  the group fails.
- The lower-level `TOMATO_VOLC_IMAGE_GROUP_PAGES` switch is still useful for
  legacy/probe paths that call batch helpers without explicitly requesting
  sequential generation.
- Sequential group generation is asynchronous from the product UI's point of
  view, but the Ark HTTP call itself may take several minutes per image before
  returning. Do not use a fixed 120 second receive timeout for chapter group
  tests. `VolcImageService` now derives the request receive timeout from the
  requested image count: by default 150 seconds per image, with a 180 second
  minimum and 2700 second cap. These can be adjusted with
  `TOMATO_VOLC_IMAGE_SECONDS_PER_IMAGE`,
  `TOMATO_VOLC_IMAGE_MIN_RECEIVE_TIMEOUT_SECONDS`, and
  `TOMATO_VOLC_IMAGE_MAX_RECEIVE_TIMEOUT_SECONDS`.
- A 2026-06-08 Alice E27 live UI-equivalent run created 14 storyboard pages but
  failed under the previous 120 second receive timeout. Treat that as a client
  timeout limit, not proof that the remote model cannot generate the sequence.
  The next live verification should use the Windows QA remote control flow:
  start the App with `TOMATO_QA_REMOTE=true`, run
  `npm run qa:picture-book-live`, wait for the async UI state, and do not click
  retry unless another full group request is explicitly allowed.
- Convert risky story wording into safe visual descriptions before sending the
  prompt. Preserve scene intent, character emotion, and action, but avoid direct
  harmful or violent wording.
- Cache every successful remote result with model, remote size, output format,
  prompt version, reference hashes, and series/page metadata in the cache key.
- Do not cache failed responses, request headers, API keys, or mock fallback
  results.
