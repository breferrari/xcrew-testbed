#!/bin/sh
# Regenerates the forms: one app (base/) expressed as each project form, at the
# repository root and under ios/. Runs on a Mac with Xcode 27.2 or later, Tuist, XcodeGen, MobileBuildMCP and Node
# (brew install tuist xcodegen getsentry/xcodebuildmcp/mobilebuildmcp); CI never runs it, it reads what this wrote.
# scripts/testbed/generate.sh [--build]   --build also builds each form for testing, to prove it's real
set -eu
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
    const runtime = released.pop()
    // The newest iPhone it runs: the one first supported on the latest iOS, then by model number.
    const types = new Map(list("devicetypes").map(t => [t.identifier, t]))
    const model = t => (t.modelIdentifier.match(/\d+/g) ?? []).map(Number)
    const iPhones = (runtime?.supportedDeviceTypes ?? []).filter(t => t.productFamily === "iPhone").map(t => types.get(t.identifier)).filter(Boolean)
    iPhones.sort((a, b) => a.minRuntimeVersion - b.minRuntimeVersion || model(a)[0] - model(b)[0] || model(a)[1] - model(b)[1])
    const iPhone = iPhones.pop()
    if (runtime && iPhone) console.log(`${iPhone.identifier} ${runtime.identifier}`)
  ')
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
  trap finish_simulator EXIT
  xcrun simctl boot "$simulator_id"
  xcrun simctl bootstatus "$simulator_id" -b > /dev/null
}

finish_simulator() {
  status=$?
  xcrun simctl shutdown "$simulator_id" 2> /dev/null || true
  xcrun simctl delete "$simulator_id"
  # A report of the capture simulator names its id, in its coalition or its paths; the Mac's own apps may crash too,
  # which is no fault of the run.
  reports=$(find "$HOME/Library/Logs/DiagnosticReports" -newer "$crash_marker" -name '*.ips' 2> /dev/null)
  rm -f "$crash_marker"
  ours=$(if [ -n "$reports" ]; then echo "$reports" | while IFS= read -r report; do grep -l -F "$simulator_id" "$report" || true; done; fi)
  others=$(if [ -n "$reports" ]; then echo "$reports" | while IFS= read -r report; do grep -q -F "$simulator_id" "$report" || echo "$report"; done; fi)
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
  # The resolved spellings first, since each holds the written one (`/private/var/…` holds `/var/…`).
  neutral() {
    perl -pe 'BEGIN { ($rf, $wf, $rd, $wd, $h) = @ARGV; @ARGV = () } s#\Q$rf\E#/testbed/captures/environment#g; s#\Q$wf\E#/testbed/captures/environment#g; s#\Q$rd\E#/testbed/DerivedData#g; s#\Q$wd\E#/testbed/DerivedData#g; s#\Q$h\E#/testbed/home#g' \
      "$resolved" "$(cd "$fixture" && pwd)" "$(cd "$derived" && pwd -P)" "$derived" "$HOME"
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
  (cd "$fixture" && TEST_RUNNER_SNAPSHOT_RECORD=1 xcodebuild test -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -quiet > /dev/null 2>&1) || true
  (cd "$fixture" && xcodebuild test -project App.xcodeproj -scheme App -destination "platform=iOS Simulator,id=$simulator_id" -derivedDataPath "$derived" -resultBundlePath "$results/Snapshots.xcresult" CODE_SIGNING_ALLOWED=NO -quiet > /dev/null 2>&1) || true
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
  neutral < "$results/test_sim.txt" | uuids_out > "$fixture/test_sim.txt"
  # MobileBuildMCP lists its files as a tree: the workspace's folder, then each file below it.
  bundle=$(awk '/└── ~\/.*\/$/ { root = $NF } /result-bundles\/.*\.xcresult/ { for (i = 1; i <= NF; i++) if ($i ~ /\.xcresult$/) print root $i }' "$results/test_sim.txt" | head -1 | sed "s#^~#$HOME#")
  exported mobilebuildmcp "$bundle"
  rm -rf "${fixture:?}/.mobilebuildmcp" "${derived:?}" "${results:?}"
  fixture_json "$fixture" pbxproj-groups xcodegen root
  printf '{\n  "replay": "xcodebuild/ and mobilebuildmcp/ are xcresulttool export attachments --only-failures and get test-results tests on one run each of three failing snapshot tests, from xcodebuild test and from MobileBuildMCP test_sim, whose MCP result is test_sim.txt; made on the Mac that generated them, tests read them and never render",\n  "swiftSnapshotTesting": "1.19.7",\n  "iOSSnapshotTestCase": "8.0.0",\n  "mobilebuildmcp": "%s"\n}\n' "$(mobilebuildmcp --version | tail -1)" > "$fixture/capture.json"
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

capture_simulator
repetitions
coverage
environment
snapshots

scripts/leaks.sh
