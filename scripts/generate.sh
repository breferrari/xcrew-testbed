#!/bin/sh
# Regenerates the forms: one app (base/) expressed as each project form, at the
# repository root and under ios/. Runs on a Mac with Xcode 27.2 or later, Tuist, XcodeGen, MobileBuildMCP and Node
# (brew install tuist xcodegen getsentry/xcodebuildmcp/mobilebuildmcp); CI never runs it, it reads what this wrote.
# scripts/testbed/generate.sh [--build]   --build also builds each form for testing, to prove it's real
set -eu
# No step reads a terminal: one that tried would stop the run, its simulator still there.
exec < /dev/null
cd "$(dirname "$0")/.."
testbed=.
base=$testbed/base
build=${1:-}
xcode=$(xcodebuild -version | head -1 | sed 's/Xcode //')
tuist_version=$(tuist version | tail -1)
xcodegen_version=$(xcodegen version | sed 's/Version: //')

sources() {
  mkdir -p "$1"
  cp -R "$base/App" "$base/AppTests" "$1/"
}

# Each device or simulator id a capture names, numbered in sorted order: 00000000-0000-0000-0000-000000000001 and on.
uuids_out() {
  perl -0pe 'my $u = qr/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/; my %seen = map { uc($_) => 1 } /($u)/g; my $n = 0; my %id = map { $_ => sprintf("00000000-0000-0000-0000-%012d", ++$n) } sort keys %seen; s/($u)/$id{uc $1}/g'
}

xcodegen_spec() {
  cat > "$1/project.yml" <<EOF
name: App
options:
  bundleIdPrefix: dev.xcrew.testbed
  deploymentTarget:
    iOS: "18.0"
  defaultSourceDirectoryType: $2
targets:
  App:
    type: application
    platform: iOS
    sources: [App]
    settings:
      GENERATE_INFOPLIST_FILE: YES
  AppTests:
    type: bundle.unit-test
    platform: iOS
    sources: [AppTests]
    dependencies:
      - target: App
    settings:
      GENERATE_INFOPLIST_FILE: YES
schemes:
  App:
    build:
      targets:
        App: all
    test:
      targets: [AppTests]
EOF
}

# Generates a Tuist project in `$1`. Tuist's own convenience scheme runs `tuist generate` from the absolute path it
# was made in, so it never stays: a fixture holds no path of the Mac that made it.
tuist_generate() {
  (cd "$1" && tuist generate --no-open > /dev/null)
  find "$1" -name 'Generate Project.xcscheme' -delete
}

tuist_manifests() {
  cat > "$1/Tuist.swift" <<'EOF'
import ProjectDescription

let tuist = Tuist()
EOF
  cat > "$1/Project.swift" <<'EOF'
import ProjectDescription

let project = Project(
    name: "App",
    targets: [
        .target(name: "App", destinations: .iOS, product: .app, bundleId: "dev.xcrew.testbed.App", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["App/**"]),
        .target(name: "AppTests", destinations: .iOS, product: .unitTests, bundleId: "dev.xcrew.testbed.AppTests", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["AppTests/**"], dependencies: [.target(name: "App")]),
    ]
)
EOF
}

# The JSON form, built with Xcode's own `xcodeproj` tool. Build phases come before `group include`: included into a
# target without phases, a synchronized folder's files are all recorded as exclusions (docs/findings.md).
json_project() {
  (
    cd "$1"
    xcrun xcodeproj init App.xcodeproj > /dev/null
    x() { xcrun xcodeproj "$@" -P App.xcodeproj > /dev/null; }
    x target add App --product-type application
    x target add AppTests --product-type unit-test-bundle
    for target in App AppTests; do
      for kind in sources frameworks resources; do x target phase add --target "$target" "$kind"; done
    done
    x group add App --filesystem-path App
    x group add AppTests --filesystem-path AppTests
    x group include --group App --target App
    x group include --group AppTests --target AppTests
    x target add-dependency AppTests App
    x setting set SDKROOT iphoneos
    x setting set IPHONEOS_DEPLOYMENT_TARGET 18.0
    x setting set SWIFT_VERSION 5.0
    x setting set TARGETED_DEVICE_FAMILY 1,2
    x setting set ALWAYS_SEARCH_USER_PATHS NO
    x setting set ENABLE_TESTABILITY YES
    x setting set PRODUCT_BUNDLE_IDENTIFIER dev.xcrew.testbed.App --target App
    x setting set PRODUCT_BUNDLE_IDENTIFIER dev.xcrew.testbed.AppTests --target AppTests
    # shellcheck disable=SC2016 # Xcode expands these, not the shell.
    x setting set TEST_HOST '$(BUILT_PRODUCTS_DIR)/App.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/App' --target AppTests
    # shellcheck disable=SC2016
    x setting set BUNDLE_LOADER '$(TEST_HOST)' --target AppTests
  )
}

xcodegen_project() {
  xcodegen_spec "$1" "$2"
  xcodegen generate --quiet --spec "$1/project.yml" --project "$1"
}

fixture_json() {
  generator=$3
  version=""
  case $generator in
    tuist) version=$tuist_version ;;
    xcodegen) version=$xcodegen_version ;;
  esac
  cat > "$1/fixture.json" <<EOF
{
  "definition": "$2",
  "generator": "$generator",
  "generatorVersion": "$version",
  "layout": "$4",
  "xcode": "$xcode"
}
EOF
}

form() {
  name=$1 layout=$2 suffix="" folder=""
  if [ "$layout" = ios ]; then suffix=-ios folder=/ios; fi
  fixture=$testbed/forms/$name$suffix
  # The expectation is written by hand, not generated: it outlives the fixture's regeneration.
  expectation=$(cat "$fixture/expect.xcrew.json" 2>/dev/null || true)
  rm -rf "$fixture"
  project=$fixture$folder
  sources "$project"
  case $name in
    classic)
      xcodegen_project "$project" group
      rm "$project/project.yml"
      fixture_json "$fixture" pbxproj-groups none "$layout" ;;
    folders)
      xcodegen_project "$project" syncedFolder
      rm "$project/project.yml"
      grep -q PBXFileSystemSynchronizedRootGroup "$project/App.xcodeproj/project.pbxproj"
      fixture_json "$fixture" pbxproj-folders none "$layout" ;;
    json)
      json_project "$project"
      # `xcodeproj` writes no scheme: the JSON form shares the one XcodeGen wrote for the classic form.
      mkdir -p "$project/App.xcodeproj/xcshareddata/xcschemes"
      cp "$testbed/forms/classic$suffix$folder/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme" "$project/App.xcodeproj/xcshareddata/xcschemes/"
      fixture_json "$fixture" json none "$layout" ;;
    xcodegen)
      xcodegen_project "$project" group
      fixture_json "$fixture" pbxproj-groups xcodegen "$layout" ;;
    tuist)
      tuist_manifests "$project"
      tuist_generate "$project"
      fixture_json "$fixture" pbxproj-groups tuist "$layout" ;;
    tuist-ungenerated)
      tuist_manifests "$project"
      fixture_json "$fixture" none tuist "$layout" ;;
  esac
  if [ "$name" != tuist-ungenerated ]; then
    if [ -d "$project/App.xcworkspace" ]; then
      container=App.xcworkspace flag=-workspace
    else
      container=App.xcodeproj flag=-project
    fi
    (cd "$project" && xcodebuild -list "$flag" "$container" > /dev/null)
    if [ "$build" = --build ]; then
      derived=$(mktemp -d)
      (cd "$project" && xcodebuild build-for-testing "$flag" "$container" -scheme App -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -quiet)
      test -x "$derived/Build/Products/Debug-iphonesimulator/App.app/App"
      rm -rf "$derived"
    fi
  fi
  if [ -n "$expectation" ]; then printf '%s\n' "$expectation" > "$fixture/expect.xcrew.json"; fi
  # Opening or building a project writes the user's own state, under their name: never part of a fixture.
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

for name in classic folders json xcodegen tuist tuist-ungenerated; do
  for layout in root ios; do form "$name" "$layout"; done
done

# Projects shaped to trip tools up, each with the expectation it must still meet.
adversarial() {
  fixture=$testbed/adversarial/$1
  expectation=$(cat "$fixture/expect.xcrew.json" 2>/dev/null || true)
  rm -rf "$fixture"
  sources "$fixture"
  case $1 in
    project-swift-trap)
      # A source file named like Tuist's manifest, a folder or two down: not a Tuist project.
      mkdir -p "$fixture/App/Models"
      printf 'struct Project {\n    let name: String\n}\n' > "$fixture/App/Models/Project.swift"
      xcodegen_project "$fixture" group
      rm "$fixture/project.yml"
      fixture_json "$fixture" pbxproj-groups none root ;;
    json-macro-copy)
      # Tuist before 4.203 gave each macro target a phase that copies the plugin in place; this project has it in
      # the JSON format, as one converted after generation would.
      tuist_manifests "$fixture"
      json_project "$fixture"
      phase=$(mktemp)
      cat > "$phase" <<'SCRIPT'
#  This build phase serves two purposes:
#  - Force Xcode build system to compile the macOS executable transitively when compiling for non-macOS destinations
    cp -f "$BUILD_DIR/$CONFIGURATION/AMacros" "$BUILD_DIR/Debug$EFFECTIVE_PLATFORM_NAME/AMacros"
SCRIPT
      xcrun xcodeproj target phase add-script --target App --script "@$phase" -P "$fixture/App.xcodeproj" > /dev/null
      rm "$phase"
      mkdir -p "$fixture/App.xcodeproj/xcshareddata/xcschemes"
      cp "$testbed/forms/classic/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme" "$fixture/App.xcodeproj/xcshareddata/xcschemes/"
      fixture_json "$fixture" json tuist root ;;
  esac
  (cd "$fixture" && xcodebuild -list -project App.xcodeproj > /dev/null)
  if [ -n "$expectation" ]; then printf '%s\n' "$expectation" > "$fixture/expect.xcrew.json"; fi
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

for name in project-swift-trap json-macro-copy; do adversarial "$name"; done

# A modular Tuist app, one project per module in a chain: App builds on Feature, which builds on Core, each with
# its own tests. Across projects, a target depends on another through a proxy into that project.
modular() {
  fixture=$testbed/modular/tuist-modules
  rm -rf "$fixture"
  mkdir -p "$fixture"
  cat > "$fixture/Tuist.swift" <<'EOF'
import ProjectDescription

let tuist = Tuist()
EOF
  cat > "$fixture/Workspace.swift" <<'EOF'
import ProjectDescription

let workspace = Workspace(name: "Modules", projects: ["Modules/*"])
EOF
  module "$fixture" Core framework ''
  module "$fixture" Feature framework '.project(target: "Core", path: "../Core")'
  module "$fixture" App app '.project(target: "Feature", path: "../Feature")'
  tuist_generate "$fixture"
  fixture_json "$fixture" pbxproj-groups tuist root
  (cd "$fixture" && xcodebuild -list -workspace Modules.xcworkspace > /dev/null)
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

# One module: its sources, its tests, and its Project.swift, depending on `$4` when given.
module() {
  root=$1/Modules/$2
  mkdir -p "$root/Sources" "$root/Tests"
  printf 'public enum %s {\n    public static let name = "%s"\n}\n' "$2" "$2" > "$root/Sources/$2.swift"
  printf 'import Testing\n@testable import %s\n\n@Test func itIsNamed() {\n    #expect(%s.name == "%s")\n}\n' "$2" "$2" "$2" > "$root/Tests/$2Tests.swift"
  dependencies=""
  if [ -n "$4" ]; then dependencies=", dependencies: [$4]"; fi
  cat > "$root/Project.swift" <<EOF
import ProjectDescription

let project = Project(
    name: "$2",
    targets: [
        .target(name: "$2", destinations: .iOS, product: .$3, bundleId: "dev.xcrew.testbed.$2", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["Sources/**"]$dependencies),
        .target(name: "$2Tests", destinations: .iOS, product: .unitTests, bundleId: "dev.xcrew.testbed.$2Tests", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["Tests/**"], dependencies: [.target(name: "$2")]),
    ]
)
EOF
}

modular

# The field-acceptance fixture: a project shaped like the field report's (plans in the xcrew spec), with no identity.
# A Tuist workspace of four modules in layers, App on Feature on Data on Core, one scheme per module, coverage on in
# every scheme, a UI-test target, `.xcode-version` pinned a major version behind the Xcode that generates it, and a CI
# workflow that selects Xcode from that file. Feature's sources and tests are what the report's scenarios run: an
# extension half tested, five probe tests (passing, failing, flaky every other run, skipped, expected to fail), a crash,
# and a line that compiles with a warning.
field() {
  fixture=$testbed/field
  rm -rf "${fixture:?}"
  mkdir -p "$fixture/.github/workflows"
  cat > "$fixture/Tuist.swift" <<'EOF'
import ProjectDescription

let tuist = Tuist()
EOF
  cat > "$fixture/Workspace.swift" <<'EOF'
import ProjectDescription

let workspace = Workspace(name: "Field", projects: ["Modules/*"], generationOptions: .options(autogeneratedWorkspaceSchemes: .disabled))
EOF
  field_module "$fixture" Core framework ''
  field_module "$fixture" Data framework '.project(target: "Core", path: "../Core")'
  field_module "$fixture" Feature framework '.project(target: "Data", path: "../Data")'
  field_module "$fixture" App app '.project(target: "Feature", path: "../Feature")'
  cat > "$fixture/Modules/Feature/Sources/Greeting.swift" <<'EOF'
public struct Greeting {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

/// Half tested: `hello` runs in ProbeTests, `farewell` in no test.
public extension Greeting {
    var hello: String { "Hello, \(name)" }
    var farewell: String { "Goodbye, \(name)" }
}
EOF
  cat > "$fixture/Modules/Feature/Sources/Legacy.swift" <<'EOF'
/// Compiles with a warning: `unused` is never read.
public func legacyCount() -> Int {
    let unused = 1
    return 2
}
EOF
  cat > "$fixture/Modules/Feature/Tests/ProbeTests.swift" <<'EOF'
import Foundation
import XCTest
@testable import Feature

final class ProbeTests: XCTestCase {
    func testPasses() {
        XCTAssertEqual(Greeting(name: "Ada").hello, "Hello, Ada")
    }

    func testFails() {
        XCTAssertEqual(Greeting(name: "Ada").hello, "Hi, Ada")
    }

    /// Fails on every other run, counted in a file that outlives each process.
    func testFlaky() throws {
        let counter = FileManager.default.temporaryDirectory.appending(path: "field-flaky-count")
        let run = (Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "") ?? 0) + 1
        try String(run).write(to: counter, atomically: true, encoding: .utf8)
        XCTAssertEqual(run % 2, 0, "run \(run) is odd")
    }

    func testSkipped() throws {
        throw XCTSkip("waits for the farewell screen")
    }

    func testExpectedFailure() {
        XCTExpectFailure("the farewell wording isn't settled")
        XCTAssertEqual(Greeting(name: "Ada").farewell, "Bye, Ada")
    }
}

final class CrashTests: XCTestCase {
    func testOutOfRange() {
        let items: [Int] = []
        _ = items[1]
    }
}
EOF
  rm -f "$fixture/Modules/Feature/Tests/FeatureTests.swift"
  mkdir -p "$fixture/Modules/App/UITests"
  cat > "$fixture/Modules/App/Sources/FieldApp.swift" <<'EOF'
import Feature
import SwiftUI

@main
struct FieldApp: SwiftUI.App {
    var body: some Scene {
        WindowGroup {
            Text(Greeting(name: "Ada").hello).accessibilityIdentifier("greeting")
        }
    }
}
EOF
  cat > "$fixture/Modules/App/UITests/AppUITests.swift" <<'EOF'
import XCTest

@MainActor
final class AppUITests: XCTestCase {
    func testGreets() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["greeting"].waitForExistence(timeout: 5))
    }
}
EOF
  # The UI tests join App's project, beside its unit tests.
  perl -0pi -e 's/(\n    \]\n\))/\n        .target(name: "AppUITests", destinations: .iOS, product: .uiTests, bundleId: "dev.xcrew.testbed.AppUITests", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["UITests\/**"], dependencies: [.target(name: "App")]),$1/' "$fixture/Modules/App/Project.swift"
  # A major version behind the Xcode that generates the fixture, read from it, never written here.
  major=$(printf '%s' "$xcode" | cut -d. -f1)
  printf '%s.0\n' "$((major - 1))" > "$fixture/.xcode-version"
  cat > "$fixture/.github/workflows/ci.yml" <<'EOF'
name: CI
on: [pull_request]
jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v5
      - name: Select the Xcode the project pins
        run: sudo xcode-select -s "/Applications/Xcode_$(cat .xcode-version).app"
      - run: tuist generate --no-open && xcodebuild test -workspace Field.xcworkspace -scheme Feature -destination 'platform=iOS Simulator,name=iPhone 17'
EOF
  tuist_generate "$fixture"
  fixture_json "$fixture" pbxproj-groups tuist root
  (cd "$fixture" && xcodebuild -list -workspace Field.xcworkspace > /dev/null)
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

# One of the field fixture's modules: its sources, its tests, and a Project.swift whose one scheme per module has
# coverage on, depending on `$4` when given.
field_module() {
  module "$1" "$2" "$3" "$4"
  perl -0pi -e 's/let project = Project\(\n    name: "([^"]+)",/let project = Project(\n    name: "$1",\n    options: .options(automaticSchemesOptions: .enabled(codeCoverageEnabled: true)),/' "$1/Modules/$2/Project.swift"
}

field

# The captures' own simulator: an iPhone on the newest released iOS runtime, created for this run, booted once and reused
# by every capture, so none boots another, and deleted at the end. A beta runtime's system apps can crash on boot, and
# a crash shows a dialog on the Mac, so no capture may cause one: the run fails when a crash report appeared during it.
capture_simulator() {
  chosen=$(node -e '
    const { execFileSync } = require("child_process")
    const list = kind => JSON.parse(execFileSync("xcrun", ["simctl", "list", kind, "--json"]))[kind]
    // A released build has no letter after its number: 24B8117 is a release, 24B5110a a beta. A runtime made for one
    // device carries it in its identifier (iOS-27-2-iPhone19-4) and comes with the Xcode made for that device, so
    // only the plain ones count.
    const released = list("runtimes").filter(r => r.platform === "iOS" && r.isAvailable && /^\d+[A-Z]\d+$/.test(r.buildversion) && /\.iOS-\d+(-\d+)*$/.test(r.identifier))
    released.sort((a, b) => a.version.localeCompare(b.version, undefined, { numeric: true }))
    // XCREW_TESTBED_RUNTIME names one, when the newest crashes its own services: it still has to be a released one.
    const wanted = process.env.XCREW_TESTBED_RUNTIME
    const runtime = wanted ? released.find(r => r.identifier === wanted) : released.pop()
    // The newest iPhone it runs: the one first supported on the latest iOS, then by model number. A device that has a
    // runtime of its own (iOS-27-2-iPhone19-4 belongs to iPhone19,4) runs best on that one, so it is left out.
    const ownRuntime = new Set(list("runtimes").map(r => r.identifier.match(/\.iOS-\d+(?:-\d+)*-([A-Za-z]+\d+-\d+)$/)?.[1]).filter(Boolean))
    const types = new Map(list("devicetypes").filter(t => !ownRuntime.has(t.modelIdentifier.replace(",", "-"))).map(t => [t.identifier, t]))
    const model = t => (t.modelIdentifier.match(/\d+/g) ?? []).map(Number)
    const iPhones = (runtime?.supportedDeviceTypes ?? []).filter(t => t.productFamily === "iPhone").map(t => types.get(t.identifier)).filter(Boolean)
    iPhones.sort((a, b) => a.minRuntimeVersion - b.minRuntimeVersion || model(a)[0] - model(b)[0] || model(a)[1] - model(b)[1])
    const iPhone = iPhones.pop()
    if (runtime && iPhone) console.log(`${iPhone.identifier} ${runtime.identifier}`)
  ')
  if [ -z "$chosen" ] && [ -n "${XCREW_TESTBED_RUNTIME:-}" ]; then
    echo "generate.sh: XCREW_TESTBED_RUNTIME names $XCREW_TESTBED_RUNTIME, which isn't an installed released iOS runtime" >&2
    exit 1
  fi
  if [ -z "$chosen" ]; then
    sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
    if command -v xcodes > /dev/null; then
      echo "generate.sh: no released iOS runtime is installed: xcodes runtimes install \"iOS $sdk\"" >&2
    else
      echo "generate.sh: no released iOS runtime is installed: add iOS $sdk in Xcode > Settings > Components" >&2
    fi
    exit 1
  fi
  simulator=xcrew-testbed
  # shellcheck disable=SC2086 # two words: the device type and the runtime
  simulator_id=$(xcrun simctl create "$simulator" $chosen)
  crash_marker=$(mktemp)
  # The reports a step expected (crash_check's argument), excused for the rest of the run and nothing else.
  expected_reports=$(mktemp)
  # A run stopped any way still deletes its simulator: a signal exits, and exiting runs the cleanup. Job control's stop
  # (SIGTSTP, as when a step reads a terminal it doesn't own) exits too, rather than leaving the run stopped for good.
  trap finish_simulator EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 148' TSTP
  xcrun simctl boot "$simulator_id"
  xcrun simctl bootstatus "$simulator_id" -b > /dev/null
  # A runtime's own services may crash in the half minute after a boot: wait them out, and stop before any test if so.
  sleep 30
  crash_check
}

# Known Apple crashes of the runtime itself, which no capture causes: remove an entry once Apple fixes its runtime.
# iOS 27.2 (24B8117) on macOS 27.2 (26B123), 2026-10-30 (README, "Known runtime crashes"):
# - launching only Settings and Safari with simctl, nothing built, crashes AppIntentsLiveEntityService and
#   SettingsSearchReindexService about 30 s later, each an EXC_BREAKPOINT in XPCPeerRequirement.hasEntitlement ->
#   __XPC_API_MISUSE__;
# - on a fresh simulator, during a test run, assetsd aborts on an exception PhotoLibraryServices throws while preparing
#   its library (queue PLLibraryServicesStateNode, prep-pre-migration); nothing here uses Photos.
# A report is known only when its process, exception, queue and frames all match an entry. An entry may be added only
# for an Apple system process, with only Apple frames in the crashing thread, and with evidence that no capture's code
# is involved. A third new process crashing means this is the wrong tool: let the simulator settle longer after boot.
known_crash() {
  node -e '
    // frames are found in the crashing thread or, for an uncaught exception, in the backtrace that threw it.
    const known = [
      { process: "AppIntentsLiveEntityService", type: "EXC_BREAKPOINT", signal: "SIGTRAP", queue: "", frames: ["XPCPeerRequirement.hasEntitlement", "__XPC_API_MISUSE__"] },
      { process: "SettingsSearchReindexService", type: "EXC_BREAKPOINT", signal: "SIGTRAP", queue: "", frames: ["XPCPeerRequirement.hasEntitlement", "__XPC_API_MISUSE__"] },
      { process: "assetsd", type: "EXC_CRASH", signal: "SIGABRT", queue: "PLLibraryServicesStateNode", frames: ["prep-pre-migration", "objc_exception_throw", "PLLibraryServicesOperation"] },
    ]
    const text = require("fs").readFileSync(process.argv[1], "utf8")
    const report = JSON.parse(text.slice(text.indexOf("\n") + 1))
    const thread = (report.threads ?? []).find(t => t.triggered) ?? {}
    const symbols = [thread.queue ?? "", ...[...(thread.frames ?? []), ...(report.lastExceptionBacktrace ?? [])].map(f => f.symbol ?? "")]
    const matches = known.some(k => report.procName === k.process && report.exception?.type === k.type && report.exception?.signal === k.signal &&
      (thread.queue ?? "").includes(k.queue) && k.frames.every(f => symbols.some(s => s.includes(f))))
    process.exit(matches ? 0 : 1)
  ' "$1" 2> /dev/null
}

# The reports since the run began that name the capture simulator and aren't a known crash; the known ones are listed.
simulator_crashes() {
  find "$HOME/Library/Logs/DiagnosticReports" -newer "$crash_marker" -name '*.ips' 2> /dev/null | while IFS= read -r report; do
    if [ -n "${shutdown_marker:-}" ] && [ "$report" -nt "$shutdown_marker" ] && grep -q -F '"signal":"SIGKILL"' "$report"; then continue; fi
    grep -q -F "$simulator_id" "$report" || continue
    if [ -n "${expected_reports:-}" ] && grep -q -x -F "$report" "$expected_reports"; then continue; fi
    if known_crash "$report"; then
      echo "generate.sh: known Apple iOS 27.2 runtime crash, ignored: $report" >&2
    else
      echo "$report"
    fi
  done
}

# Stops the run at the first crash report that names the capture simulator; the trap still deletes it.
crash_check() {
  found=$(simulator_crashes)
  # A step that crashes a test on purpose names the test: exactly one report of the test runner with that test in its
  # crashing thread is excused, for that step alone. Any other crash, then or later, stops the run as ever.
  if [ -n "${1:-}" ] && [ -n "$found" ]; then
    matching=$(printf '%s\n' "$found" | while IFS= read -r report; do
      if expected_crash "$report" "$1"; then echo "$report"; fi
    done)
    if [ "$(printf '%s' "$matching" | grep -c .)" = 1 ]; then
      echo "generate.sh: the expected crash of $1, excused for this step: $matching" >&2
      printf '%s\n' "$matching" >> "$expected_reports"
      found=$(printf '%s\n' "$found" | grep -v -x -F "$matching" || true)
    fi
  fi
  if [ -n "$found" ]; then
    echo "generate.sh: stopping: the capture simulator ($simulator_id) crashed" >&2
    printf '%s\n' "$found" >&2
    exit 1
  fi
}

# Whether a crash report is the test runner's, with the test `$2` in its crashing thread's frames.
expected_crash() {
  node -e '
    const text = require("fs").readFileSync(process.argv[1], "utf8")
    const report = JSON.parse(text.slice(text.indexOf("\n") + 1))
    const thread = (report.threads ?? []).find(t => t.triggered) ?? {}
    const runner = /xctest|Runner/.test(report.procName ?? "")
    process.exit(runner && (thread.frames ?? []).some(f => (f.symbol ?? "").includes(process.argv[2])) ? 0 : 1)
  ' "$1" "$2" 2> /dev/null
}

finish_simulator() {
  status=$?
  shutdown_marker=$(mktemp)
  xcrun simctl shutdown "$simulator_id" 2> /dev/null || true
  xcrun simctl delete "$simulator_id"
  # The shutdown kills the simulator's services, and their SIGKILL reports land up to half a minute later: wait for
  # them, and leave out only those, so a real crash during the shutdown still counts.
  sleep 45
  # A report of the capture simulator names its id, in its coalition or its paths; the Mac's own apps may crash too,
  # which is no fault of the run.
  ours=$(simulator_crashes)
  others=$(find "$HOME/Library/Logs/DiagnosticReports" -newer "$crash_marker" -name '*.ips' 2> /dev/null | while IFS= read -r report; do
    grep -q -F "$simulator_id" "$report" || echo "$report"
  done)
  rm -f "$crash_marker" "$shutdown_marker" "$expected_reports"
  if [ -n "$others" ]; then
    echo "generate.sh: other crash reports appeared during the run, not the capture simulator's:" >&2
    echo "$others" >&2
  fi
  if [ -n "$ours" ]; then
    echo "generate.sh: the capture simulator ($simulator_id) crashed during the run:" >&2
    echo "$ours" >&2
    status=1
  fi
  exit "$status"
}

# A capture of a result bundle with repetitions: three tests run five times each, in a fresh process each time. One
# passes every run, one fails every run, one fails on every other run, counted in a file in the app's sandbox that
# outlives each process. Tests replay `tests.json`, xcresulttool's answer; nothing nondeterministic runs anywhere else.
repetitions() {
  fixture=$testbed/captures/repetitions
  rm -rf "$fixture"
  sources "$fixture"
  cat > "$fixture/AppTests/RepetitionTests.swift" <<'EOF'
import XCTest

final class RepetitionTests: XCTestCase {
    func testPassesEveryRun() {
        XCTAssertTrue(true)
    }

    func testFailsEveryRun() {
        XCTFail("fails on every run")
    }

    func testFailsEveryOtherRun() throws {
        let counter = FileManager.default.temporaryDirectory.appending(path: "xcrew-testbed-repetitions")
        let runs = (Int((try? String(contentsOf: counter, encoding: .utf8)) ?? "") ?? 0) + 1
        try String(runs).write(to: counter, atomically: true, encoding: .utf8)
        XCTAssertEqual(runs % 2, 0, "fails on every other run")
    }
}
EOF
  xcodegen_project "$fixture" group
  derived=$(mktemp -d)
  # The run fails by design: two of its tests fail.
  (cd "$fixture" && xcodebuild test -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" -resultBundlePath "$derived/Repetitions.xcresult" -only-testing:AppTests/RepetitionTests -test-iterations 5 -test-repetition-relaunch-enabled YES CODE_SIGNING_ALLOWED=NO -quiet > /dev/null 2>&1) || true
  # Failure messages name the test's source file by its absolute path: the fixture's folder becomes a neutral one.
  xcrun xcresulttool get test-results tests --path "$derived/Repetitions.xcresult" | sed "s#$(cd "$fixture" && pwd -P)#/testbed/captures/repetitions#g" | uuids_out > "$fixture/tests.json"
  rm -rf "$derived"
  fixture_json "$fixture" pbxproj-groups xcodegen root
  printf '{\n  "replay": "tests.json is xcresulttool get test-results tests on a run with -test-iterations 5 -test-repetition-relaunch-enabled YES, made on the Mac that generated it; tests read it and never run RepetitionTests",\n  "xcodebuild": "-only-testing:AppTests/RepetitionTests -test-iterations 5 -test-repetition-relaunch-enabled YES"\n}\n' > "$fixture/capture.json"
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

# A capture of a result bundle's coverage: one test runs one branch of `price(for:)` and leaves the other. Tests
# replay xccov's answers: whether the bundle has coverage, the archive's file list, and the per-line counts of
# Pricing.swift, its shape undocumented (`man xccov`). The archive names files as the build was started, so both
# spellings of the fixture's folder, as written and resolved, become a neutral one, in JSON's escaped form too.
coverage() {
  fixture=$testbed/captures/coverage
  rm -rf "$fixture"
  sources "$fixture"
  rm "$fixture/AppTests/SeededTests.swift"
  cat > "$fixture/App/Pricing.swift" <<'EOF'
/// A price in cents for a number of items, cheaper by the dozen.
func price(for items: Int) -> Int {
    // Ten percent off from twelve items.
    if items >= 12 {
        return items * 90
    }
    return items * 100
}
EOF
  cat > "$fixture/AppTests/PricingTests.swift" <<'EOF'
import XCTest
@testable import App

final class PricingTests: XCTestCase {
    func testAFewItemsPayFullPrice() {
        XCTAssertEqual(price(for: 2), 200)
    }
}
EOF
  xcodegen_project "$fixture" group
  derived=$(mktemp -d)
  bundle=$derived/Coverage.xcresult
  (cd "$fixture" && xcodebuild test -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" -resultBundlePath "$bundle" -only-testing:AppTests/PricingTests -enableCodeCoverage YES CODE_SIGNING_ALLOWED=NO -quiet > /dev/null 2>&1)
  written=$(cd "$fixture" && pwd)
  resolved=$(cd "$fixture" && pwd -P)
  neutral() {
    perl -pe 'BEGIN { ($w, $r, $n) = @ARGV; @ARGV = (); ($we, $re, $ne) = map { (my $e = $_) =~ s#/#\\/#g; $e } $w, $r, $n } s#\Q$we\E#$ne#g; s#\Q$re\E#$ne#g; s#\Q$w\E#$n#g; s#\Q$r\E#$n#g' "$written" "$resolved" /testbed/captures/coverage
  }
  xcrun xcresulttool get content-availability --path "$bundle" > "$fixture/content-availability.json"
  xcrun xccov view --archive --file-list --json "$bundle" | neutral > "$fixture/file-list.json"
  pricing=$(xcrun xccov view --archive --file-list "$bundle" | grep '/App/Pricing.swift$')
  xcrun xccov view --archive --file "$pricing" --json "$bundle" | neutral > "$fixture/Pricing.json"
  rm -rf "$derived"
  fixture_json "$fixture" pbxproj-groups xcodegen root
  printf '{\n  "replay": "content-availability.json is xcresulttool get content-availability, file-list.json and Pricing.json are xccov view --archive --file-list --json and --file <App/Pricing.swift> --json, on one run made on the Mac that generated it; tests read them and never run PricingTests",\n  "xcodebuild": "-only-testing:AppTests/PricingTests -enableCodeCoverage YES"\n}\n' > "$fixture/capture.json"
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

# Captures of builds that fail on the Mac, not in the code, as MobileBuildMCP's MCP results and the logs they name: a
# module in the module cache made corrupt, once in Clang's cache and once among the SDK's precompiled modules, and an
# iPhone name no simulator has. Tests replay the text; nothing breaks anywhere else.
environment() {
  fixture=$testbed/captures/environment
  rm -rf "$fixture"
  sources "$fixture"
  xcodegen_project "$fixture" group
  derived=$(mktemp -d)
  results=$(mktemp -d)
  resolved=$(cd "$fixture" && pwd -P)
  # The resolved spellings first, since each holds the written one (`/private/var/…` holds `/var/…`). The Mac's own
  # temporary folder last: xcodebuild writes an error result bundle there.
  neutral() {
    perl -pe 'BEGIN { ($rf, $wf, $rd, $wd, $h, $rt, $wt) = @ARGV; @ARGV = () } s#\Q$rf\E#/testbed/captures/environment#g; s#\Q$wf\E#/testbed/captures/environment#g; s#\Q$rd\E#/testbed/DerivedData#g; s#\Q$wd\E#/testbed/DerivedData#g; s#\Q$h\E#/testbed/home#g; s#\Q$rt\E#/testbed/tmp#g; s#\Q$wt\E#/testbed/tmp#g' \
      "$resolved" "$(cd "$fixture" && pwd)" "$(cd "$derived" && pwd -P)" "$derived" "$HOME" "$(cd "${TMPDIR:-/tmp}" && pwd -P)" "${TMPDIR%/}"
  }
  configure() {
    mkdir -p "$fixture/.mobilebuildmcp"
    printf "schemaVersion: 1\nsessionDefaults:\n  projectPath: '%s'\n  scheme: 'App'\n  simulatorName: '%s'\n  derivedDataPath: '%s'\n" "$resolved/App.xcodeproj" "$1" "$derived" > "$fixture/.mobilebuildmcp/config.yaml"
  }
  build() {
    node scripts/mcp-call.mjs "$fixture" build_sim
  }
  # A source changed since the last build, so the next one compiles again and reads the modules.
  touch_source() {
    printf '\n' >> "$fixture/App/ContentView.swift"
  }
  corrupt() {
    module=$(find "$derived/$1" -name "$2-*.pcm" | head -1)
    head -c 4096 "$module" > "$results/module" && mv "$results/module" "$module"
  }
  # xcodebuild lists every destination it knows after a failure, this Mac and the devices paired with it among them,
  # with their owner's name and their hardware ids; simulators and the placeholder destinations stay.
  devices_out() {
    perl -ne 'print unless /^\s*\{ platform:(?!\w+ Simulator)[^,]+, (?!id:dvtdevice-)/'
  }
  capture() {
    build > "$results/$1.txt"
    log=$(grep -o '~/[^ ]*\.log' "$results/$1.txt" | head -1 | sed "s#^~#$HOME#")
    neutral < "$results/$1.txt" | uuids_out > "$fixture/$1.txt"
    neutral < "$log" | devices_out | uuids_out > "$fixture/$1.log"
  }
  configure "$simulator"
  build | grep -q 'Build succeeded'
  corrupt ModuleCache.noindex Darwin
  touch_source
  capture module-cache-malformed
  rm -rf "$derived/ModuleCache.noindex" "$derived/SDKExplicitPrecompiledModules"
  build | grep -q 'Build succeeded'
  corrupt SDKExplicitPrecompiledModules SwiftShims
  touch_source
  capture module-cache-invalid
  # A name like an iPhone's reaches xcodebuild; MobileBuildMCP turns away one that names no platform itself.
  configure "iPhone 1"
  capture simulator-missing
  cp "$base/App/ContentView.swift" "$fixture/App/ContentView.swift"
  rm -rf "$fixture/.mobilebuildmcp" "$derived" "$results"
  fixture_json "$fixture" pbxproj-groups xcodegen root
  printf '{\n  "replay": "each .txt is MobileBuildMCP build_sim'"'"'s MCP result, and the .log beside it the build log it names: module-cache-malformed after one of Clang'"'"'s cached modules (Darwin) was cut short, module-cache-invalid after one of the SDK'"'"'s precompiled modules (SwiftShims) was, simulator-missing for an iPhone name no simulator has; tests read them and never build",\n  "mobilebuildmcp": "%s"\n}\n' "$(mobilebuildmcp --version | tail -1)" > "$fixture/capture.json"
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

# Captures of snapshot tests that fail, with both libraries in wide use, pinned by exact version: swift-snapshot-testing
# under XCTest and under Swift Testing, and iOSSnapshotTestCase. Each compares a 4-point square, recorded red and
# rendered blue, so every comparison fails. Committed: the failed tests' attachments as `xcresulttool export
# attachments` gives them (manifest.json and the files), once from `xcodebuild test` and once from MobileBuildMCP's
# test_sim, with the test tree and MobileBuildMCP's MCP result. Tests replay them; nothing renders anywhere else.
snapshots() {
  fixture=$testbed/captures/snapshots
  rm -rf "${fixture:?}"
  sources "$fixture"
  rm -rf "${fixture:?}/AppTests"
  mkdir -p "$fixture/SnapshotTests"
  cat > "$fixture/SnapshotTests/SnapshotTests.swift" <<'EOF'
import SnapshotTesting
import Testing
import UIKit
import XCTest
import iOSSnapshotTestCase

/// Whether this run records the references: the capture records them red, then compares a blue square against them.
let recording = ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] != nil

func squareView() -> UIView {
    let view = UIView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
    view.backgroundColor = recording ? .red : .blue
    return view
}

final class PointFreeXCTests: XCTestCase {
    func testSquare() {
        withSnapshotTesting(record: recording ? .all : .never) {
            assertSnapshot(of: squareView(), as: .image)
        }
    }
}

/// On the main actor: Swift Testing runs a test on the cooperative pool, and UIKit asserts when a view is made there.
@MainActor @Suite(.snapshots(record: recording ? .all : .never)) struct PointFreeSwiftTests {
    @Test func square() {
        assertSnapshot(of: squareView(), as: .image)
    }
}

final class UberTests: FBSnapshotTestCase {
    override func setUp() {
        super.setUp()
        recordMode = recording
    }

    func testSquare() {
        FBSnapshotVerifyView(squareView())
    }
}
EOF
  # Signed ad hoc, as a developer's simulator build is.
  cat > "$fixture/project.yml" <<'EOF'
name: App
options:
  bundleIdPrefix: dev.xcrew.testbed
  deploymentTarget:
    iOS: "18.0"
packages:
  SnapshotTesting:
    url: https://github.com/pointfreeco/swift-snapshot-testing
    exactVersion: 1.19.7
  iOSSnapshotTestCase:
    url: https://github.com/uber/ios-snapshot-test-case
    exactVersion: 8.0.0
targets:
  App:
    type: application
    platform: iOS
    sources: [App]
    settings:
      GENERATE_INFOPLIST_FILE: YES
      CODE_SIGN_IDENTITY: "-"
      CODE_SIGNING_ALLOWED: YES
  SnapshotTests:
    type: bundle.unit-test
    platform: iOS
    sources: [SnapshotTests]
    dependencies:
      - target: App
      - package: SnapshotTesting
      - package: iOSSnapshotTestCase
    settings:
      GENERATE_INFOPLIST_FILE: YES
      CODE_SIGN_IDENTITY: "-"
      CODE_SIGNING_ALLOWED: YES
schemes:
  App:
    build:
      targets:
        App: all
    test:
      targets: [SnapshotTests]
      environmentVariables:
        FB_REFERENCE_IMAGE_DIR: $(SOURCE_ROOT)/SnapshotTests/ReferenceImages
EOF
  xcodegen generate --quiet --spec "$fixture/project.yml" --project "$fixture"
  derived=$(mktemp -d)
  results=$(mktemp -d)
  resolved=$(cd "$fixture" && pwd -P)
  neutral() {
    perl -pe 'BEGIN { ($rf, $wf, $rd, $wd, $h) = @ARGV; @ARGV = () } s#\Q$rf\E#/testbed/captures/snapshots#g; s#\Q$wf\E#/testbed/captures/snapshots#g; s#\Q$rd\E#/testbed/DerivedData#g; s#\Q$wd\E#/testbed/DerivedData#g; s#\Q$h\E#/testbed/user#g' \
      "$resolved" "$(cd "$fixture" && pwd)" "$(cd "$derived" && pwd -P)" "$derived" "$HOME"
  }
  # Both runs fail by design: a test that records fails in both libraries, and so does every comparison after.
  (cd "$fixture" && TEST_RUNNER_SNAPSHOT_RECORD=1 xcodebuild test -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" -quiet > /dev/null 2>&1) || true
  crash_check
  (cd "$fixture" && xcodebuild test -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" -resultBundlePath "$results/Snapshots.xcresult" -quiet > /dev/null 2>&1) || true
  crash_check
  exported() {
    out=$fixture/$1
    rm -rf "${out:?}"
    mkdir -p "$out"
    # Every attachment of the failed tests: the libraries' images aren't associated with the failure, so --only-failures
    # would leave them out. Each test here fails, so none is a passing test's.
    xcrun xcresulttool export attachments --path "$2" --output-path "$out" > /dev/null
    if find "$out" -name '*.ips' | grep -q .; then echo "snapshots: a test crashed; see $2" >&2; exit 1; fi
    # The files are named by ids the manifest holds: number them as uuids_out numbers the manifest, in the same order,
    # so its exportedFileName still names them.
    n=0
    for id in $(grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' "$out/manifest.json" | tr 'a-f' 'A-F' | LC_ALL=C sort -u); do
      n=$((n + 1))
      for file in "$out/$id" "$out/$id".*; do
        if [ -e "$file" ]; then mv "$file" "$out/$(printf '00000000-0000-0000-0000-%012d' "$n")${file#"$out/$id"}"; fi
      done
    done
    for text in "$out"/manifest.json "$out"/*.txt; do
      neutral < "$text" | uuids_out > "$results/text" && mv "$results/text" "$text"
    done
    xcrun xcresulttool get test-results tests --path "$2" | neutral | uuids_out > "$out/tests.json"
  }
  exported xcodebuild "$results/Snapshots.xcresult"
  # The same tests through MobileBuildMCP, as Claude runs them.
  mkdir -p "$fixture/.mobilebuildmcp"
  printf "schemaVersion: 1\nsessionDefaults:\n  projectPath: '%s'\n  scheme: 'App'\n  simulatorName: '%s'\n  derivedDataPath: '%s'\n" "$resolved/App.xcodeproj" "$simulator" "$derived" > "$fixture/.mobilebuildmcp/config.yaml"
  node scripts/mcp-call.mjs "$fixture" test_sim > "$results/test_sim.txt"
  crash_check
  neutral < "$results/test_sim.txt" | uuids_out > "$fixture/test_sim.txt"
  # MobileBuildMCP lists its files as a tree: the workspace's folder, then each file below it.
  bundle=$(awk '/└── ~\/.*\/$/ { root = $NF } /result-bundles\/.*\.xcresult/ { for (i = 1; i <= NF; i++) if ($i ~ /\.xcresult$/) print root $i }' "$results/test_sim.txt" | head -1 | sed "s#^~#$HOME#")
  exported mobilebuildmcp "$bundle"
  rm -rf "${fixture:?}/.mobilebuildmcp" "${derived:?}" "${results:?}"
  fixture_json "$fixture" pbxproj-groups xcodegen root
  printf '{\n  "replay": "xcodebuild/ and mobilebuildmcp/ are xcresulttool export attachments (every attachment, since the images are not associated with the failure) and get test-results tests on one run each of three failing snapshot tests, from xcodebuild test and from MobileBuildMCP test_sim, whose MCP result is test_sim.txt; made on the Mac that generated them, tests read them and never render",\n  "swiftSnapshotTesting": "1.19.7",\n  "iOSSnapshotTestCase": "8.0.0",\n  "mobilebuildmcp": "%s"\n}\n' "$(mobilebuildmcp --version | tail -1)" > "$fixture/capture.json"
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

# Each uuid in a folder's files and file names, numbered as uuids_out numbers them, but once across them all, so an
# attachment's file, its manifest entry and its activity keep naming each other. Binary files count too: XCTest's
# archived UI snapshots hold the device's id as text, and a number is as long as the id it replaces, so they stay valid.
numbered() {
  perl -e '
    my $dir = shift;
    my $u = qr/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/;
    opendir(my $d, $dir) or die "$dir: $!"; my @files = grep { -f "$dir/$_" } readdir $d; closedir $d;
    my (%seen, %body);
    for my $f (@files) {
      $seen{uc $_} = 1 for $f =~ /($u)/g;
      open my $h, "<:raw", "$dir/$f" or die; local $/; $body{$f} = <$h>; close $h;
      $seen{uc $_} = 1 for $body{$f} =~ /($u)/g;
    }
    my $n = 0; my %id = map { $_ => sprintf("00000000-0000-0000-0000-%012d", ++$n) } sort keys %seen;
    for my $f (@files) {
      (my $t = $body{$f}) =~ s/($u)/$id{uc $1}/g;
      if ($t ne $body{$f}) { open my $h, ">:raw", "$dir/$f" or die; print $h $t; close $h }
      (my $g = $f) =~ s/($u)/$id{uc $1}/g;
      rename "$dir/$f", "$dir/$g" or die if $g ne $f;
    }
  ' "$1"
}

# A capture of failing UI tests, for reading what a run kept about the moment each one failed: the steps before it,
# the screenshots and recording, and the app's accessibility hierarchy. One screen shows a title, a plan and a button.
# One test taps a button that isn't there, one waits for a label the screen no longer has, one fails an assertion two
# steps after its taps, one passes, and one fails under one of the test plan's two configurations only. Committed:
# xcresulttool's test tree, each failed test's activities and details, and its attachments as `export attachments`
# gives them, from `xcodebuild test` and from MobileBuildMCP's test_sim. Images are cut to 16 points and recordings
# re-encoded at the lowest preset, so they stay small. Tests replay them; nothing runs a UI test anywhere else.
uitests() {
  fixture=$testbed/captures/uitests
  rm -rf "${fixture:?}"
  mkdir -p "$fixture/App" "$fixture/UITests"
  cat > "$fixture/App/AppApp.swift" <<'EOF'
import SwiftUI

@main
struct AppApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
EOF
  cat > "$fixture/App/ContentView.swift" <<'EOF'
import SwiftUI

/// The plan the test plan's configuration names, passed on by the UI test.
let plan = ProcessInfo.processInfo.environment["PLAN"] ?? "A"

struct ContentView: View {
    @State private var steps = 0

    var body: some View {
        VStack {
            Text(steps == 0 ? "Welcome" : "Done").accessibilityIdentifier("title")
            Text("Plan \(plan)").accessibilityIdentifier("plan")
            Button("Continue") { steps += 1 }.accessibilityIdentifier("continue")
        }
    }
}
EOF
  cat > "$fixture/UITests/UITests.swift" <<'EOF'
import XCTest

@MainActor
final class UITests: XCTestCase {
    func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PLAN"] = ProcessInfo.processInfo.environment["PLAN"]
        app.launch()
        return app
    }

    /// No element has this identifier.
    func testMissingElement() {
        launch().buttons["checkout"].tap()
    }

    /// The title once read "Hello"; it reads "Welcome" now.
    func testRenamedLabel() {
        XCTAssertTrue(launch().staticTexts["Hello"].waitForExistence(timeout: 2))
    }

    /// Both taps pass; the assertion after them fails.
    func testFailsAfterTaps() {
        let app = launch()
        app.buttons["continue"].tap()
        app.buttons["continue"].tap()
        XCTAssertEqual(app.staticTexts["title"].label, "Welcome")
    }

    /// Passes under the test plan's "Plan A" and fails under "Plan B".
    func testPlanA() {
        XCTAssertTrue(launch().staticTexts["Plan A"].waitForExistence(timeout: 2))
    }

    func testPasses() {
        XCTAssertTrue(launch().buttons["continue"].exists)
    }
}
EOF
  # Signed ad hoc, as a developer's simulator build is.
  cat > "$fixture/project.yml" <<'EOF'
name: App
options:
  bundleIdPrefix: dev.xcrew.testbed
  deploymentTarget:
    iOS: "18.0"
targets:
  App:
    type: application
    platform: iOS
    sources: [App]
    settings:
      GENERATE_INFOPLIST_FILE: YES
      CODE_SIGN_IDENTITY: "-"
      CODE_SIGNING_ALLOWED: YES
  UITests:
    type: bundle.ui-testing
    platform: iOS
    sources: [UITests]
    dependencies:
      - target: App
    settings:
      GENERATE_INFOPLIST_FILE: YES
      CODE_SIGN_IDENTITY: "-"
      CODE_SIGNING_ALLOWED: YES
schemes:
  App:
    build:
      targets:
        App: all
    test:
      testPlans:
        - path: App.xctestplan
          defaultPlan: true
EOF
  # The test plan names its target by the id XcodeGen gives it, which depends only on the spec: generate once, with an
  # empty plan since XcodeGen refuses a missing one, to learn it, then again with the plan in place. Its settings stay
  # at Xcode's defaults, which is what is captured.
  printf '{ "configurations" : [], "defaultOptions" : {}, "testTargets" : [], "version" : 1 }\n' > "$fixture/App.xctestplan"
  xcodegen generate --quiet --spec "$fixture/project.yml" --project "$fixture"
  target=$(perl -0ne 'print $1 if /(\w{24}) \/\* UITests \*\/ = \{\s*isa = PBXNativeTarget;/' "$fixture/App.xcodeproj/project.pbxproj")
  if [ -z "$target" ]; then echo "uitests: no UITests target in the generated project" >&2; exit 1; fi
  cat > "$fixture/App.xctestplan" <<EOF
{
  "configurations" : [
    {
      "id" : "00000000-0000-0000-0000-000000000101",
      "name" : "Plan A",
      "options" : {
        "environmentVariableEntries" : [ { "key" : "PLAN", "value" : "A" } ]
      }
    },
    {
      "id" : "00000000-0000-0000-0000-000000000102",
      "name" : "Plan B",
      "options" : {
        "environmentVariableEntries" : [ { "key" : "PLAN", "value" : "B" } ]
      }
    }
  ],
  "defaultOptions" : {

  },
  "testTargets" : [
    {
      "target" : {
        "containerPath" : "container:App.xcodeproj",
        "identifier" : "$target",
        "name" : "UITests"
      }
    }
  ],
  "version" : 1
}
EOF
  xcodegen generate --quiet --spec "$fixture/project.yml" --project "$fixture"
  derived=$(mktemp -d)
  results=$(mktemp -d)
  resolved=$(cd "$fixture" && pwd -P)
  neutral() {
    perl -pe 'BEGIN { ($rf, $wf, $rd, $wd, $h) = @ARGV; @ARGV = () } s#\Q$rf\E#/testbed/captures/uitests#g; s#\Q$wf\E#/testbed/captures/uitests#g; s#\Q$rd\E#/testbed/DerivedData#g; s#\Q$wd\E#/testbed/DerivedData#g; s#\Q$h\E#/testbed/user#g' \
      "$resolved" "$(cd "$fixture" && pwd)" "$(cd "$derived" && pwd -P)" "$derived" "$HOME"
  }
  # Fails by design: four of the five tests fail under at least one configuration.
  (cd "$fixture" && xcodebuild test -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" -resultBundlePath "$results/UITests.xcresult" -quiet > /dev/null 2>&1) || true
  crash_check
  kept() {
    out=$fixture/$1
    rm -rf "${out:?}"
    mkdir -p "$out"
    # Every attachment, as the snapshot capture found the failure flag unreliable for attachments.
    xcrun xcresulttool export attachments --path "$2" --output-path "$out" > /dev/null
    if find "$out" -name '*.ips' | grep -q .; then echo "uitests: a test crashed; see $2" >&2; exit 1; fi
    xcrun xcresulttool get test-results tests --path "$2" > "$out/tests.json"
    for test in $(node -e '
      const walk = n => [...(n.nodeType === "Test Case" && n.result === "Failed" ? [n.nodeIdentifier] : []), ...(n.children ?? []).flatMap(walk)]
      console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).testNodes.flatMap(walk).join("\n"))
    ' "$out/tests.json"); do
      name=$(printf '%s' "$test" | sed 's#.*/##; s#()$##')
      xcrun xcresulttool get test-results activities --test-id "$test" --path "$2" > "$out/activities-$name.json"
      xcrun xcresulttool get test-results test-details --test-id "$test" --path "$2" > "$out/details-$name.json"
    done
    for file in "$out"/*; do
      case $(file -b --mime-type "$file") in
        image/*) sips -Z 16 "$file" > /dev/null ;;
        video/*)
          avconvert --preset PresetLowQuality --source "$file" --output "$results/small.mov" --replace > /dev/null
          mv "$results/small.mov" "$file" ;;
        text/* | application/json) neutral < "$file" > "$results/text" && mv "$results/text" "$file" ;;
      esac
    done
    numbered "$out"
  }
  kept xcodebuild "$results/UITests.xcresult"
  # The same tests through MobileBuildMCP, as Claude runs them.
  mkdir -p "$fixture/.mobilebuildmcp"
  printf "schemaVersion: 1\nsessionDefaults:\n  projectPath: '%s'\n  scheme: 'App'\n  simulatorName: '%s'\n  derivedDataPath: '%s'\n" "$resolved/App.xcodeproj" "$simulator" "$derived" > "$fixture/.mobilebuildmcp/config.yaml"
  node scripts/mcp-call.mjs "$fixture" test_sim > "$results/test_sim.txt"
  crash_check
  neutral < "$results/test_sim.txt" | uuids_out > "$fixture/test_sim.txt"
  # MobileBuildMCP lists its files as a tree: the workspace's folder, then each file below it.
  bundle=$(awk '/└── ~\/.*\/$/ { root = $NF } /result-bundles\/.*\.xcresult/ { for (i = 1; i <= NF; i++) if ($i ~ /\.xcresult$/) print root $i }' "$results/test_sim.txt" | head -1 | sed "s#^~#$HOME#")
  kept mobilebuildmcp "$bundle"
  rm -rf "${fixture:?}/.mobilebuildmcp" "${derived:?}" "${results:?}"
  fixture_json "$fixture" pbxproj-groups xcodegen root
  printf '{\n  "replay": "xcodebuild/ and mobilebuildmcp/ each hold one run of five UI tests under a test plan of two configurations, from xcodebuild test and from MobileBuildMCP test_sim (whose MCP result is test_sim.txt): xcresulttool export attachments (every attachment; images cut to 16 points, recordings re-encoded small), get test-results tests, and each failed test'"'"'s activities and test-details, with one numbering of ids across a folder; made on the Mac that generated them, tests read them and never run a UI test",\n  "mobilebuildmcp": "%s"\n}\n' "$(mobilebuildmcp --version | tail -1)" > "$fixture/capture.json"
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

# Captures of the field fixture's scenarios (the field acceptance plan in the xcrew spec), as MobileBuildMCP answers
# them to Claude: its MCP results, the logs they name, and what xcresulttool and xccov answer about each run's bundle.
# They run on a copy of field/, so a scenario's edit never reaches the fixture. Tests replay them.
# - probes: the five probe tests, five times each, relaunched every time (scenario B)
# - crash: the crashing test, with its crash log (C)
# - coverage: one test run with coverage on, the half-tested file's line counts, and each target's counts (A)
# - lldb-expr: LLDB's `expr` on the running app under the default debugger backend (N)
# - two-display: a two-display device's screenshot error, from MobileBuildMCP's tool and simctl's message, not a run (K)
# - empty-filter: a selection matching no test (D)
# - type-error: a build failing on a plain type error, with the pinned Xcode not the one building (E)
# FIELD_CAPTURES names the scenarios to take again (`coverage type-error`), keeping the others' captures; unset,
# all of them are taken afresh.
field_captures() {
  out=$testbed/captures/field
  wanted=${FIELD_CAPTURES:-probes coverage empty-filter type-error crash lldb-expr two-display}
  if [ -z "${FIELD_CAPTURES:-}" ]; then rm -rf "${out:?}"; fi
  mkdir -p "$out"
  takes() { case " $wanted " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  work=$(mktemp -d)/field
  cp -R "$testbed/field" "$work"
  derived=$(mktemp -d)
  results=$(mktemp -d)
  resolved=$(cd "$work" && pwd -P)
  # Each folder in every spelling a tool writes it: resolved (`/private/var/…`) and as written (`/var/…`), and each
  # with JSON's escaped slashes, the resolved first since it holds the written one. Then any user's home folder, as a
  # crash log writes macOS's own `USER` placeholder for one.
  neutral() {
    perl -pe 'BEGIN { my @pairs = @ARGV; @ARGV = (); while (my ($from, $to) = splice(@pairs, 0, 2)) { (my $escaped = $from) =~ s#/#\\/#g; (my $to_escaped = $to) =~ s#/#\\/#g; push @rules, [$from, $to], [$escaped, $to_escaped] } } for my $rule (@rules) { my ($from, $to) = @$rule; s/\Q$from\E/$to/g } s#/U[s]ers/[^/"\\]+/#/testbed/user/#g; s#\\/U[s]ers\\/[^/"\\]+\\/#\\/testbed\\/user\\/#g' \
      "$resolved" /testbed/field "$work" /testbed/field "$(cd "$derived" && pwd -P)" /testbed/DerivedData "$derived" /testbed/DerivedData "$HOME" /testbed/user \
      "$(cd "${TMPDIR:-/tmp}" && pwd -P)" /testbed/tmp "${TMPDIR%/}" /testbed/tmp
  }
  mkdir -p "$work/.mobilebuildmcp"
  # The simulator, UI automation and debugging tools: the scenarios take a screenshot and attach LLDB, under
  # MobileBuildMCP's default debugger backend, DAP.
  printf "schemaVersion: 1\nenabledWorkflows: ['simulator', 'ui-automation', 'debugging']\nsessionDefaults:\n  workspacePath: '%s'\n  scheme: 'Feature'\n  simulatorName: '%s'\n  derivedDataPath: '%s'\n" "$resolved/Field.xcworkspace" "$simulator" "$derived" > "$work/.mobilebuildmcp/config.yaml"
  # One MobileBuildMCP call, its result kept as `<name>.txt` and the log it names as `<name>.log`.
  call() {
    node scripts/mcp-call.mjs "$work" "$2" "$3" > "$results/$1.txt" || true
    keep "$1" "${4:-}"
  }
  # Several calls in one MobileBuildMCP session, as a stateful tool needs, the last one's result kept: `calls <name>
  # <tool> <arguments> [<tool> <arguments> …]`.
  calls() {
    name=$1
    shift
    node scripts/mcp-call.mjs "$work" "$@" > "$results/$name.txt" || true
    keep "$name"
  }
  keep() {
    # An expected crash's report lands a little after the process ends: wait for it, so this step's check sees it.
    if [ -n "${2:-}" ]; then sleep 20; fi
    crash_check "${2:-}"
    neutral < "$results/$1.txt" | uuids_out > "$out/$1.txt"
    log=$(grep -o '~/[^ ]*\.log' "$results/$1.txt" | head -1 | sed "s#^~#$HOME#")
    if [ -n "$log" ] && [ -f "$log" ]; then neutral < "$log" | uuids_out > "$out/$1.log"; fi
  }
  # The bundle a test call names, and what xcresulttool says of it: its tests, and the details of each failed test.
  bundle_of() {
    awk '/└── ~\/.*\/$/ { root = $NF } /result-bundles\/.*\.xcresult/ { for (i = 1; i <= NF; i++) if ($i ~ /\.xcresult$/) print root $i }' "$results/$1.txt" | head -1 | sed "s#^~#$HOME#"
  }
  answers() {
    bundle=$(bundle_of "$1")
    [ -n "$bundle" ] || return 0
    xcrun xcresulttool get test-results tests --path "$bundle" --compact | neutral | uuids_out > "$out/$1.tests.json"
    xcrun xcresulttool get test-results summary --path "$bundle" --compact | neutral | uuids_out > "$out/$1.summary.json"
    for test in $(node -e '
      const walk = n => [...(n.nodeType === "Test Case" && n.result === "Failed" ? [n.nodeIdentifier] : []), ...(n.children ?? []).flatMap(walk)]
      console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).testNodes.flatMap(walk).join("\n"))
    ' "$out/$1.tests.json"); do
      name=$(printf '%s' "$test" | sed 's#/#.#g; s#()$##')
      xcrun xcresulttool get test-results test-details --test-id "$test" --path "$bundle" --compact | neutral | uuids_out > "$out/$1.details.$name.json"
    done
  }
  if takes probes; then call probes test_sim '{"extraArgs":["-only-testing:FeatureTests/ProbeTests","-test-iterations","5","-test-repetition-relaunch-enabled","YES"]}'
  answers probes; fi
  if takes coverage; then
    call coverage test_sim '{"extraArgs":["-only-testing:FeatureTests/ProbeTests/testPasses"]}'
    bundle=$(bundle_of coverage)
    if [ -n "$bundle" ]; then
      xcrun xccov view --archive --file-list --json "$bundle" > "$results/files.json"
      neutral < "$results/files.json" > "$out/coverage.files.json"
      # xccov answers for a file only as its own list spells it.
      greeting=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).find(f => f.endsWith("/Greeting.swift")) ?? "")' "$results/files.json")
      xcrun xccov view --archive --file "$greeting" --json "$bundle" | neutral > "$out/coverage.Greeting.json"
      # Each target's files and line counts: which are test bundles, and which the run reached.
      xcrun xccov view --report --json "$bundle" | neutral > "$out/coverage.report.json"
    fi
  fi
  # N: LLDB's `expr` on the running app, under MobileBuildMCP's default debugger backend, which refuses it.
  if takes lldb-expr; then
    calls lldb-expr session_set_defaults '{"scheme":"App"}' build_run_sim '{}' debug_attach_sim '{"bundleId":"dev.xcrew.testbed.App"}' debug_lldb_command '{"command":"expr 1 + 1"}'
  fi
  # K: a screenshot of a device with two displays. Its device, the iPhone Duo, runs only on a runtime of its own, not
  # a released one, so nothing boots: MobileBuildMCP's own screenshot tool runs against an `xcrun` that lists the
  # device as booted and fails `simctl io … screenshot` with simctl's message, read from CoreSimulator's simctl
  # (`Cannot choose between %lu displays. Specify one with --display:`, then a line per display, which only a run can
  # fill and is left out). The live pass takes it for real.
  if takes two-display; then
    fake=$(mktemp -d)
    cat > "$fake/xcrun" <<'XCRUN'
#!/bin/sh
case "$*" in
  "simctl list devices -j"*) echo '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4":[{"udid":"00000000-0000-4000-8000-000000000001","name":"iPhone Duo","state":"Booted","isAvailable":true}]}}' ;;
  "simctl io 00000000-0000-4000-8000-000000000001 screenshot "*) echo 'Cannot choose between 2 displays. Specify one with --display:' >&2; exit 1 ;;
  *) exec /usr/bin/xcrun "$@" ;;
esac
XCRUN
    chmod +x "$fake/xcrun"
    PATH="$fake:$PATH" node scripts/mcp-call.mjs "$work" session_set_defaults '{"simulatorId":"00000000-0000-4000-8000-000000000001"}' screenshot '{}' > "$results/two-display.txt" || true
    neutral < "$results/two-display.txt" | uuids_out > "$out/two-display.txt"
    rm -rf "$fake"
  fi
  if takes empty-filter; then call empty-filter test_sim '{"extraArgs":["-only-testing:FeatureTests/NoSuchTests"]}'; fi
  if takes type-error; then
    printf '\npublic let typeError: Int = "not a number"\n' >> "$work/Modules/Feature/Sources/Greeting.swift"
    call type-error build_sim '{}'
    cp "$testbed/field/Modules/Feature/Sources/Greeting.swift" "$work/Modules/Feature/Sources/Greeting.swift"
  fi
  # Last, so a surprise here costs no other capture; its one expected crash is excused for this call alone.
  if takes crash; then
  call crash test_sim '{"extraArgs":["-only-testing:FeatureTests/CrashTests"]}' testOutOfRange
  answers crash
  # The crash log the bundle attached, as xcrew reads it.
  bundle=$(bundle_of crash)
  if [ -n "$bundle" ]; then
    mkdir -p "$results/crash-export"
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$results/crash-export" --only-failures > /dev/null
    report=$(find "$results/crash-export" -name '*.ips' | head -1)
    if [ -n "$report" ]; then neutral < "$report" | uuids_out > "$out/crash.ips"; fi
  fi
  fi
  rm -rf "${work:?}" "${derived:?}" "${results:?}"
  printf '{\n  "replay": "each <scenario>.txt is MobileBuildMCP'"'"'s MCP result on a copy of field/, the .log beside it the log it names, and .tests.json, .summary.json and .details.<test>.json what xcresulttool answered about its result bundle; crash.ips is the crashing test'"'"'s crash log, coverage.*.json what xccov answered; tests read them and never build",\n  "two-display": "from source and the report, not a run: MobileBuildMCP'"'"'s own screenshot tool against an xcrun that fails simctl io … screenshot with simctl'"'"'s message from CoreSimulator'"'"'s simctl, its per-display lines left out; the field acceptance'"'"'s live pass takes it for real",\n  "mobilebuildmcp": "%s"\n}\n' "$(mobilebuildmcp --version | tail -1)" > "$out/capture.json"
  echo "$out"
}

capture_simulator
repetitions
coverage
environment
snapshots
uitests
field_captures

scripts/leaks.sh
