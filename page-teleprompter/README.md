# Page teleprompter core

Host-testable core for a page-wise teleprompter on RayNeo iO glasses: split a
manuscript into pages, follow the reader's speech inside the current page, and
decide when to move the highlight or turn the page. Pure Foundation, no UIKit
and no BLE, so it builds and tests on macOS without the iOS SDK.

| File | Role |
|---|---|
| `TIOTokens.h/.m` | Grapheme tokeniser (NFKC + case fold), Chinese-numeral normaliser, semi-global aligner, acceptance policy |
| `PageTeleprompter.h/.m` | Pagination (`---` or form-feed markers, sentence breaks, grapheme-safe hard cuts) and a stateless single-page matcher |
| `FollowSession.h/.m` | Live controller: forward-only cursor, page-end crossover into the next page, change-only output |
| `ManuscriptStore.h/.m` | Import, edit, delete, 20 retained revisions, serial-queue transactions |

Offsets are UTF-8 byte offsets, matching the glasses protocol's `pageOffset` and
`highLightOffset`. The matcher takes plain recognised text, so any speech source
can drive it.

```sh
./test.sh          # 65 tests
```

Not yet wired into `official-addon`: the UIKit page, the type 8 sender and the
speech input. Policy constants are starting values to tune on recorded speech.
Non-commercial research use, under the repository license.
