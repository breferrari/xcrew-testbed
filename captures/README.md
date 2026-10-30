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
- **An empty selection** reports "Test succeeded".
- **No locked build database.** A second build into the same DerivedData while another `xcodebuild` builds there succeeds, even with that `xcodebuild` stopped (SIGSTOP). The build runs in Xcode's build service, not in the `xcodebuild` process. So a locked build database seen in the field isn't reproduced here. It needs a stuck build service, which a capture must not cause, since Xcode itself shares it.
- **The expected crash.** The crashing test crashes on purpose. Its capture step excuses exactly that one report, the test runner's with `testOutOfRange` in its crashing thread, for that step alone. Any other crash, before or after, stops the run as ever.

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
