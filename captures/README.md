# Captures

What tools answered about a real run, committed so tests replay it and never build, run or render. Each folder's `capture.json` says what its files are and how they were made. Nothing nondeterministic runs outside the Mac that made it.

## repetitions

*Xcode 27.2, `xcodebuild` with `-test-iterations 5 -test-repetition-relaunch-enabled YES`, 2026-10-30.*

- A result bundle's test tree (`xcresulttool get test-results tests`) after five runs of three tests.
- One test passes every run, one fails every run, and one fails on every other run.

## coverage

*Xcode 27.2, `xcodebuild` with `-enableCodeCoverage YES`, 2026-10-30.*

- What `xccov` answered about one test run with coverage on: whether the bundle has coverage, the files it holds, and one file's per-line counts.
- The test runs one branch of `price(for:)` and not the other.

## environment

*Xcode 27.2, MobileBuildMCP 2.7.1's `build_sim`, 2026-10-30.*

What MobileBuildMCP answered, through MCP, about builds that fail on the Mac rather than in the code, each with the build log it names:

- `module-cache-malformed`: a corrupt module in Clang's module cache;
- `module-cache-invalid`: a corrupt one among the SDK's precompiled modules;
- `simulator-missing`: an iPhone simulator name no simulator has.

## snapshots

*Xcode 27.2, MobileBuildMCP 2.7.1, 2026-10-30.*

Three snapshot tests that fail, a square recorded red and rendered blue: swift-snapshot-testing under XCTest and under Swift Testing, and iOSSnapshotTestCase. It holds each failed test's attachments as `xcresulttool export attachments` gives them, from `xcodebuild test` and from MobileBuildMCP's `test_sim`.

- **No image is tied to the failure.** Both libraries attach the reference, the failing render and the difference as images, and xcresulttool marks none of them as associated with the failure (`isAssociatedWithFailure: false`). Only the issue's text is. So `export attachments --only-failures` leaves the images out.
- **Names.** An image's suggested name is `<name>_<n>_<id>.png`: `reference`, `failure` and `difference` for swift-snapshot-testing, `Reference Image`, `Failed Image` and `Diffed Image` for iOSSnapshotTestCase.
- **Numbering.** Under XCTest `<n>` counts 0, 1, 2 within one test. Under Swift Testing each image is 0, in no set order.
- **No extension.** swift-snapshot-testing's XCTest images are exported without a file extension, though each is a PNG and its suggested name ends `.png`.

## uitests

*Xcode 27.2, iOS 27.2 (24B8117), MobileBuildMCP 2.7.1, the test plan left at Xcode's defaults, 2026-10-30.*

Five XCTest UI tests under a test plan with two configurations, `Plan A` and `Plan B`:

- one taps a button that isn't there;
- one waits for a label the screen no longer shows;
- one fails an assertion after two taps that pass;
- one fails under `Plan B` only;
- one passes.

It holds each run's test tree, each failed test's activities and details, and its attachments, from `xcodebuild test` and from `test_sim`.

- **Recordings.** XCTest keeps a screen recording for each failed run of a test, one per configuration, and nothing for a passing run (`testPasses` has no attachments, and `testPlanA` has none under `Plan A`). It keeps no screenshot image at all.
- **A recording ends at the failure.** It starts with the test and stops at the failure: each lasts within 0.1 s of the time from its own `timestamp` to the failing activity's `startTime`. So its last frame is the screen at the failure.
- **Hierarchies.** When a query fails (an element not found, a wait that ran out), XCTest adds the app's accessibility hierarchy twice: as text (`App UI hierarchy for <bundle id>`) and as an archived "UI Snapshot" (a binary property list). It adds one "Debug description" of the query chain per attempt. An assertion on an element it found (`XCTAssertEqual` on a label) adds no hierarchy.
- **The text hierarchy** has one element per line, indented by depth: its type, its frame, and its `identifier` and `label` when set.
- **What's tied to the failure.** In `get test-results activities`, the failing step is the one activity with `isAssociatedWithFailure: true`, and it holds the hierarchy attachments. In the export manifest, only a failed query's hierarchy is `isAssociatedWithFailure: true`. The recordings and the debug descriptions are `false`.
- **Configurations apart.** Every attachment in the manifest names its `configurationName`, `deviceName` and `deviceId`, and each run in `activities` names its device and test-plan configuration. So a failure under one configuration only, `testPlanA` under `Plan B`, can be told apart without reading anything else.
- **Both servers alike.** `test_sim` keeps the same kinds of attachment as `xcodebuild test`.
- **Ids in binaries.** The archived snapshots and synthesized events hold the device's id as text, so the capture numbers ids inside binary files too, and `leaks.sh` looks for them there.
- **Small recordings.** The capture re-encodes the recordings at `avconvert`'s lowest preset to keep them small. They are real recordings, at a lower size.

## field

*Xcode 27.2, iOS 27.2 (24B8117), MobileBuildMCP 2.7.1, 2026-10-30.*

What MobileBuildMCP's `test_sim` and `build_sim` answered about the field fixture's scenarios, with what `xcresulttool` and `xccov` answered about each run's bundle. They run on a copy of `field/`, so a scenario's edit never reaches the fixture.

| Scenario | What runs |
|---|---|
| `probes` | the five probe tests, five times each, relaunched every time |
| `crash` | the crashing test, with its crash log |
| `coverage` | one test run with coverage on, the half-tested file's line counts, and each target's counts |
| `empty-filter` | a selection matching no test |
| `type-error` | a plain type error, with the pinned Xcode not the one building |
| `lldb-expr` | LLDB's `expr` on the running app under the default debugger backend |
| `two-display` | a two-display device's screenshot error, from MobileBuildMCP's tool and simctl's message; from source, not a run |

What they show:

- **Repeated probes.** MobileBuildMCP's text lists the flaky test once per failing run ("run 1 is odd", 3, 5) with no verdict, gives no skip reason, and doesn't count the expected failure. Its summary reads "2 tests failed, 1 passed, 1 skipped". The bundle's test list has each run.
- **The crash.** The error text ("Index out of range") appears only among the errors. The failure line names the test with no file:line ("Crash: xctest at CrashTests.testOutOfRange()").
- **An empty selection** reports "Test succeeded" with no count, as MobileBuildMCP writes for any test run it has no count for. `empty-filter.summary.json`, from its result bundle, counts 0 tests (`totalTestCount: 0`): that is what says none ran. Re-taken on 2026-10-31 with its bundle's answers, so its text is a cold build's, with the fixture's one warning.
- **No locked build database.** A second build into the same DerivedData while another `xcodebuild` builds there succeeds, even with that `xcodebuild` stopped (SIGSTOP). The build runs in Xcode's build service, not in the `xcodebuild` process. So a locked build database seen in the field isn't reproduced here. It needs a stuck build service, which a capture must not cause, since Xcode itself shares it.
- **The expected crash.** The crashing test crashes on purpose. Its capture step excuses exactly that one report, the test runner's with `testOutOfRange` in its crashing thread, for that step alone. Any other crash, before or after, stops the run as ever.

## concurrency

*Xcode 27.2, MobileBuildMCP 2.7.1, 2026-10-31. Builds only: the capture simulator was Shutdown after `build_sim`, never booted.*

xcodebuild's own logs of `concurrency/`'s `Warnings` and `App` schemes, for a generic iOS Simulator destination, and MobileBuildMCP's `build_sim` of `Warnings` with the log it names.

| File | What it holds |
|---|---|
| `xcodebuild-warnings.log` | the frameworks' seven warnings, each written two or four times |
| `xcodebuild-errors.log` | the app's one error, in the Swift 6 language mode |
| `build_sim.txt`, `build_sim.log` | the same seven warnings, as MobileBuildMCP lists them once each, and its log |

What they show:

- **Each diagnostic ends with its group**, as `[#MutableGlobalVariable]`. A group under another is written `[#RegionIsolation::SendingRisksDataRace]`, parent first.
- **Not every concurrency diagnostic has a group.** A `Sendable` struct's non-Sendable stored property is reported with none.
- **Errors carry their group too:** the app's `var 'appCount' is not concurrency-safe … [#MutableGlobalVariable]`.
- **Logs repeat a diagnostic.** xcodebuild's log writes each warning two or four times. MobileBuildMCP's result lists it once.

## raw

*Xcode 27.2, iOS 27.2, MobileBuildMCP 2.7.1, 2026-10-31.*

MobileBuildMCP's answers whole, as JSON-RPC gives them (`content` and `structuredContent`), each with the log it names: `test_sim` on a copy of `field/`, and `build_sim` on a copy of `concurrency/`. `scripts/mcp-call.mjs` keeps them with `MCP_RAW=1`. They replace text captures as the tests reading those move to them.

| File | What runs |
|---|---|
| `serial.json`, `serial.log` | `FeatureTests/ProbeTests` with `-parallel-testing-enabled NO` |
| `swift-testing.json`, `swift-testing.log` | the `Core` scheme's Swift Testing tests |
| `profile.json`, `profile.log` | a call that names no scheme, under a `sessionDefaultsProfiles` profile whose scheme is `Data` |
| `empty-filter.json`, `empty-filter.log` | `-only-testing:FeatureTests/NoSuchTests`, the selection `field/empty-filter` makes, matching no test (2026-10-31, booted once) |
| `timing.json`, `timing.log`, `timing.crash.ips` | `FeatureTests/ProbeTests` and `FeatureTests/CrashTests` with `-parallel-testing-enabled NO` and `showTestTiming: true` in the project's config, the crash log exported from the bundle (2026-10-31, booted once) |
| `session-defaults.json`, `profile-switched.json` | `session_show_defaults` with two profiles, `probe` (scheme `Feature`) active and `unit` (scheme `Data`), then `session_use_defaults_profile` to `unit`, neither persisted, the simulator never booted (2026-10-31) |
| `build_sim.json`, `build_sim.log` | `build_sim` of `concurrency/`'s `Warnings` scheme, which builds with its warnings, the simulator never booted (2026-10-31) |

What they show:

- **Claude Code hands the mod the text.** A passing run's `content` is text too, `✅ 1 test passed, 0 failed, 0 skipped`, and its JSON is only in `structuredContent`. So is a passing build's: `✅ Build succeeded.`, its 7 warnings in `structuredContent.data.diagnostics.warnings` as `message` and `location`.
- **`showTestTiming` adds `Test Results:`.** With it on, a test run's text lists each test, `✅ ProbeTests/testPasses (0.000s)`, `⏭️ ProbeTests/testSkipped (0.009s)`, before the summary line. The test that crashed isn't listed, though it counts among the failures, and the expected failure is listed as passed.
- **The session tools answer in text too.** `session_show_defaults`'s `content` is a tree, `📁 probe` and `├ scheme: Feature` for each profile, and it doesn't mark the current one: only `structuredContent.data.currentProfile` names it. `session_use_defaults_profile`'s text is `✅ Activated profile (unit profile)`.
- **A run matching no test says so only in its JSON.** The text is `✅ Test succeeded.` with no count; `structuredContent.data.summary` is `SUCCEEDED` with `counts` of 0 passed, 0 failed, 0 skipped.
- **No result names its scheme.** `structuredContent.data` holds `summary`, `artifacts` and `diagnostics`, and the text has no `Scheme:` line.
- **`test_sim` takes its scheme from the session defaults.** A call that passes `scheme` is refused: "scheme: scheme is required." `tools/list` gives `test_sim` no `scheme` parameter.
- **A serial run's log** writes `Test Case '-[FeatureTests.ProbeTests testFails]' failed (0.006 seconds).` **A Swift Testing run's** writes `✔ Test itIsNamed() passed after 0.001 seconds.` Neither is the parallel runner's `Test case '…'`.
- **Paths:** `structuredContent`'s artifact paths are written from `~`. The rest is neutralised as the other captures are, JSON-escaped spellings included.

**Bundle answers.** Beside `serial`, `swift-testing`, `profile` and `shapes` are their result bundles' answers to what xcrew asks, as `field/`'s are:
- `<name>.tests.json` and `<name>.summary.json`, from `xcresulttool get test-results tests` and `summary`;
- `<name>.details.<Class.test>.json`, from `test-details`, for each test that failed or failed as expected: serial's `testFails`, `testFlaky` and `testExpectedFailure`, and shapes' `fails` and `knownIssue` (a known issue reads as an expected failure).

`scripts/generate.sh raw-answers` read them on 2026-10-31 from the bundles MobileBuildMCP kept from the runs above, booting nothing. Each run's work copy, a temporary folder gone since, is found in the answers and neutralised to `/testbed/<fixture>`, as the run's log was. A capture taken afresh writes its answers itself, `empty-filter`'s and `parallel`'s too. xcresulttool writes a duration in the Mac's locale: `"duration":"Ran for 0,0056 seconds"` under a locale whose decimal mark is a comma. Its `durationInSeconds` and counts are JSON numbers.

### shapes

*Xcode 27.2, iOS 27.2, MobileBuildMCP 2.7.1, 2026-10-31.* `swift-testing/`'s `ShapesTests` holds six Swift Testing tests:
- `passes()`;
- `fails()`, the one failure;
- `skipped()`, `.disabled("skipped on purpose")`;
- `knownIssue()`, a `withKnownIssue`;
- `parameterised(value:)` over 1, 2 and 3;
- `waits()`, which sleeps 5 s.

The step checks the run came to exactly that (one failure, `fails()`; `skipped()` skipped; the parameterised and waiting tests passed) and stops otherwise. `shapes.json` and `shapes.log` are the result and its log. `shapes-snapshots.json` lists where the markers stood in each copy of the live log, taken each second while the run went. `shapes-midrun.log` is the last copy with the tests started and no verdict yet.

What they show:

- **MobileBuildMCP counts `❌ 1 test failed, 3 passed, 1 skipped`** for six tests. The parameterised test is one, not three. `knownIssue()` is in neither passed nor failed: Swift Testing writes it `━ Test knownIssue() passed after 0.001 seconds with 1 known issue`, not with `✔`.
- **`Testing started` is written only after the tests.** In the ten copies, the tests had started from the seventh (`Test Suite 'All tests' started at` at line 495, `◇ Test run started.` at 498), and none holds `Testing started` or `** TEST EXECUTE`. In the finished log, `Testing started` is the last line, after `** TEST EXECUTE FAILED **`.

### parallel

`scripts/generate.sh parallel` runs `parallel/`'s bundle: `ProbeTests` with a pass, a failure and an `XCTSkip`, and `SlowTests` with a 5 s wait. The scheme runs them in parallel, at most two workers (`-parallel-testing-worker-count 2`), so at most three simulators. The step checks the run came to one failure (`testFails`), one skipped and `testWaits` passed, on the parallel runner, and stops otherwise. It writes `parallel.json`, `parallel.log`, `parallel-snapshots.json` and `parallel-midrun.log`, as shapes does. The mid-run copy is the last one with the tests' build done (`** TEST BUILD SUCCEEDED **`) or the tests started, and no verdict yet.

Its files aren't committed yet: its run left a crash report from a system service in one of xcodebuild's clones that no known entry covers.

## Crash reports

A simulator's services are killed when it shuts down, and each leaves a report. `shutdown_kill` excuses one only when all four hold:
- it was written after its simulator's shutdown began (below);
- it's `EXC_CRASH` with `SIGKILL`;
- it ended by `XPC_EXIT_REASON_SIGTERM_TIMEOUT` (launchd's SIGTERM, then SIGKILL when the service didn't exit);
- it's in the coalition of this run's capture simulator or one of its clones, `com.apple.CoreSimulator.SimDevice.<id>`.

A shutdown begins at the simulator's first observed departure from Booted. For the capture simulator it begins at that or at `finish_simulator`'s shutdown, whichever is earlier.

During a test call the script reads both device sets each second: the default one, and the testing set (`xcrun simctl --set testing list`), where xcodebuild makes a parallel run's clones. A clone is this run's when it appears there during the call. The first read that finds a simulator, once seen Booted, shut down or gone, marks its departure. xcodebuild shuts the capture simulator down to clone it, and shuts its clones down as the run ends, before `test_sim` returns. A departure is seen a second or more late, so a report written in that gap counts. A report counts as this run's when it names any of these ids. The cleanup lists the run's clones, and deletes one xcodebuild left only when it's named a clone of the capture simulator.

The rule never goes by the process name, and any other SIGKILL counts as a crash. `scripts/generate.sh self-test` checks this on made-up reports. On 2026-10-31 every report the raw and shapes runs left was one of these: tccd, routined, siriactionsd, newsd, generativeexperiencesd and dtdeviceinfod. The empty-filter run's were tccd, routined, generativeexperiencesd and dmd; build_sim's, never booted, left none.

## Which names take captures

Only a full run, `scripts/generate.sh` or `--build`, takes every capture. A step's name takes only that step's captures. A fixture's name that's no step's makes only that fixture, and boots nothing. A name that's neither stops with a usage line, writing nothing. Before 2026-10-31 a fixture's name, or any other, made what it named and then went on to take every capture. `scripts/generate.sh self-test` runs a fixture's name and an unknown one on a copy, with an `xcrun` that fails when asked to create or boot a simulator.

## xcode-mcp

Not taken yet: `scripts/generate.sh xcode-mcp` writes the Xcode MCP's raw answers to `initialize` and `tools/list` here, when run by hand with Xcode open on `field/`.

## Neutralising

- The captures' neutralisers rewrite a temporary folder of the Mac (`$TMPDIR`, with or without its `/private` prefix), which `leaks.sh` also fails on. The [README's Leaks section](../README.md#leaks) has what it looks for.
- Adding that check found one in `environment/simulator-missing.log`, where `xcodebuild` had written an error result bundle into the Mac's own temporary folder. That file is fixed, and both neutralisers now map that folder too.
- A crash log writes macOS's `USER` placeholder for a home folder. The field neutraliser maps it to `/testbed/user` like any other, since `leaks.sh` fails on any user's home folder, as xcrew's own privacy test checks every committed file.

## Known runtime crashes

Crashes of Apple's runtime itself, which no capture causes. `generate.sh` lists them as "known Apple iOS 27.2 runtime crash, ignored" and goes on. `known_crash` holds them, and each entry goes once Apple's runtime no longer crashes.

### AppIntentsLiveEntityService and SettingsSearchReindexService

*iOS 27.2 (24B8117) on macOS 27.2 (26B123), Xcode 27.2, 2026-10-30.*

- On a fresh iPhone 18 Pro Max simulator, launching any app crashes both services about 30 seconds later.
- Nothing needs building: launching only Settings and Safari does it.
- Each crash is an `EXC_BREAKPOINT` whose crashing thread is in `XPCPeerRequirement.hasEntitlement` → `__XPC_API_MISUSE__`, under `XPCSystem.Session.handleReceivedRequest`.
- launchd restarts the service, and it crashes again. They show no crash dialog on the Mac.
- The same crashes came under macOS 27.0.1, and after `xcodebuild test` launched an app whether it was signed ad hoc or not signed at all.

The probe that showed it:

| Time | Event |
|---|---|
| 15:15:58 | `simctl create`, then boot |
| 15:16:52 | booted and 30 s passed: no crash |
| 15:16:52 | `simctl launch com.apple.Preferences` |
| 15:16:53 | `simctl launch com.apple.mobilesafari` |
| 15:17:23 | SettingsSearchReindexService starts and crashes 0.2 s later |
| 15:17:26 | AppIntentsLiveEntityService starts and crashes 0.3 s later |
| 15:17:36 | AppIntentsLiveEntityService restarts and crashes again |

### assetsd

*The same runtime, a fresh simulator, 2026-10-30.*

- During the snapshot capture's third test run (MobileBuildMCP's `test_sim`), assetsd, the Photos library service, started at 15:24:18 and aborted at 15:24:24.
- It aborted on an uncaught exception that PhotoLibraryServices threw in `PLLibraryServicesOperation` on the queue `PLLibraryServicesStateNode(…: prep-pre-migration)`: an `EXC_CRASH` with `SIGABRT`, about 3 seconds after the test run ended.
- Nothing the captures build uses Photos.

### Adding an entry

An entry joins `known_crash` only for an Apple system process, with only Apple frames in its crashing thread, and with evidence that no capture's code is involved. If yet another Apple process crashes, the list is the wrong tool: let the fresh simulator settle longer after boot instead.
