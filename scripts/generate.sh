#!/bin/sh
# Regenerates the forms: one app (base/) expressed as each project form, at the
# repository root and under ios/. Runs on a Mac with Xcode 27.2 or later, Tuist, XcodeGen, MobileBuildMCP and Node
# (brew install tuist xcodegen getsentry/xcodebuildmcp/mobilebuildmcp); CI never runs it, it reads what this wrote.
# scripts/testbed/generate.sh [--build]   --build also builds each form for testing, to prove it's real
# scripts/testbed/generate.sh concurrency   only the concurrency fixture and its capture, on a capture simulator never booted
# scripts/testbed/generate.sh raw           only the raw MobileBuildMCP test captures (RAW_CAPTURES names which), on the capture simulator
# scripts/testbed/generate.sh raw-answers   only the committed raw captures' bundle answers, from the bundles on this Mac; boots nothing
# scripts/testbed/generate.sh raw-build     only the raw MobileBuildMCP build capture, on a capture simulator never booted
# scripts/testbed/generate.sh raw-session   only the raw MobileBuildMCP session tools' answers, on a capture simulator never booted
# scripts/testbed/generate.sh shapes        only the swift-testing fixture and its raw capture, on the capture simulator
# scripts/testbed/generate.sh multi-pass    only the plans fixture and the raw captures of runs with several passes or a
#                                           cancel, on the capture simulator; never in a full run (multi_pass_captures)
# scripts/testbed/generate.sh neutral-paths only rewrites every committed capture's PATH through scripts/neutral-path.sh; boots nothing
# scripts/testbed/generate.sh field-logs    only the logs of committed field captures (FIELD_CAPTURES names which), from this Mac's MobileBuildMCP workspaces; boots nothing
# scripts/testbed/generate.sh parallel      only the parallel fixture and its raw capture, on the capture simulator and its clones
# scripts/testbed/generate.sh self-test     checks the crash rules on made-up reports, and that a fixture's or an unknown name boots nothing; boots nothing
# scripts/testbed/generate.sh field-captures   only the field captures (FIELD_CAPTURES names which), on the capture simulator
# scripts/testbed/generate.sh xcode-mcp     only the Xcode MCP's captures, never in a full run: it needs Xcode open
set -eu
# No step reads a terminal: one that tried would stop the run, its simulator still there.
exec < /dev/null
cd "$(dirname "$0")/.."
testbed=.
base=$testbed/base
build=${1:-}
# A step runs in a full run, and alone when it's the one named, which `named` notes.
named=
runs() { case $build in "" | --build) return 0 ;; *) [ "$build" = "$1" ] && named=1 ;; esac; }
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

# Each folder in every spelling a tool writes it, `<from> <to>` pairs, the resolved spelling first since it holds the
# written one, each also with JSON's escaped slashes; then this Mac's home and temporary folder, and any user's home
# folder, as a crash log writes macOS's own `USER` placeholder for one. A pair whose folder is empty, as TMPDIR is when
# unset, is skipped: it would match between every character.
neutralise() {
  perl -pe 'BEGIN { my @pairs = @ARGV; @ARGV = (); while (my ($from, $to) = splice(@pairs, 0, 2)) { next unless length $from; (my $escaped = $from) =~ s#/#\\/#g; (my $to_escaped = $to) =~ s#/#\\/#g; push @rules, [$from, $to], [$escaped, $to_escaped] } } for my $rule (@rules) { my ($from, $to) = @$rule; s/\Q$from\E/$to/g } s#/U[s]ers/[^/"\\]+/#/testbed/user/#g; s#\\/U[s]ers\\/[^/"\\]+\\/#\\/testbed\\/user\\/#g' \
    "$@" "$HOME" /testbed/user "$(cd "${TMPDIR:-/tmp}" && pwd -P)" /testbed/tmp "${TMPDIR%/}" /testbed/tmp | neutral_path
}

# neutral_path and its defaults: scripts/neutral-path.sh.
. scripts/neutral-path.sh

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

if runs forms; then
  for name in classic folders json xcodegen tuist tuist-ungenerated; do
    for layout in root ios; do form "$name" "$layout"; done
  done
fi

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

if runs adversarial; then for name in project-swift-trap json-macro-copy; do adversarial "$name"; done; fi

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

if runs modular; then modular; fi

# The field fixture: a project shaped like a large production app, with no identity.
# A Tuist workspace of four modules in layers, App on Feature on Data on Core, one scheme per module, coverage on in
# every scheme, a UI-test target, `.xcode-version` pinned a major version behind the Xcode that generates it, and a CI
# workflow that selects Xcode from that file. Feature's sources and tests are what the field scenarios run: an
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
  field_module "$fixture" Data framework '.project(target: "Core", path: "../Core")' Core
  field_module "$fixture" Feature framework '.project(target: "Data", path: "../Data")' Data
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
# coverage on, depending on `$4` when given. Its source imports `$5`, the module below it, and uses it, as a module of
# a layered app does.
field_module() {
  module "$1" "$2" "$3" "$4"
  if [ -n "${5:-}" ]; then
    printf 'import %s\n\npublic enum %s {\n    public static let name = "%s"\n    public static let below = %s.name\n}\n' "$5" "$2" "$2" "$5" > "$1/Modules/$2/Sources/$2.swift"
  fi
  perl -0pi -e 's/let project = Project\(\n    name: "([^"]+)",/let project = Project(\n    name: "$1",\n    options: .options(automaticSchemesOptions: .enabled(codeCoverageEnabled: true)),/' "$1/Modules/$2/Project.swift"
}

if runs field; then field; fi

# The strict-concurrency fixture: an XcodeGen project of two frameworks in the Swift 5 language mode with complete
# concurrency checking, each source drawing diagnostics of named groups, and an app in the Swift 6 mode whose global
# variable is an error. One warning outside concurrency (`NoUsage`) and one with no group (a `Sendable` struct's
# non-Sendable property) are there too. The `Warnings` scheme builds the frameworks; `App` builds the app and fails.
concurrency() {
  fixture=$testbed/concurrency
  rm -rf "${fixture:?}"
  mkdir -p "$fixture/Kit" "$fixture/Feature" "$fixture/App"
  cat > "$fixture/Kit/Kit.swift" <<'EOF'
public var sharedCount = 0

public final class Box {
    public var value = 0
    public init() {}
}

public struct Holder: Sendable {
    public let box: Box
}

public func capture(_ box: Box) {
    Task.detached {
        print(box.value)
    }
}

public actor Store {
    public init() {}
    public func keep(_ box: Box) {}
}

public func hand(_ box: Box, to store: Store) async {
    await store.keep(box)
    box.value = 1
}

@MainActor public final class Screen {
    public init() {}
    public func draw() {}
}

public func leftover() {
    let unused = 1
}
EOF
  cat > "$fixture/Feature/Feature.swift" <<'EOF'
import Kit

public var featureFlags: [String] = []

public func later(_ box: Box) {
    Task.detached {
        box.value += 1
    }
}
EOF
  cat > "$fixture/App/App.swift" <<'EOF'
import Feature
import Kit
import SwiftUI

@main
struct ConcurrencyApp: App {
    var body: some Scene {
        WindowGroup { Text("Concurrency") }
    }
}

var appCount = 0
EOF
  cat > "$fixture/project.yml" <<'EOF'
name: Concurrency
options:
  bundleIdPrefix: dev.xcrew.testbed
  deploymentTarget:
    iOS: "18.0"
targets:
  Kit:
    type: framework
    platform: iOS
    sources: [Kit]
    settings:
      GENERATE_INFOPLIST_FILE: YES
      SWIFT_VERSION: "5.0"
      SWIFT_STRICT_CONCURRENCY: complete
  Feature:
    type: framework
    platform: iOS
    sources: [Feature]
    dependencies:
      - target: Kit
    settings:
      GENERATE_INFOPLIST_FILE: YES
      SWIFT_VERSION: "5.0"
      SWIFT_STRICT_CONCURRENCY: complete
  App:
    type: application
    platform: iOS
    sources: [App]
    dependencies:
      - target: Feature
    settings:
      GENERATE_INFOPLIST_FILE: YES
      SWIFT_VERSION: "6.0"
schemes:
  Warnings:
    build:
      targets:
        Kit: all
        Feature: all
  App:
    build:
      targets:
        App: all
EOF
  xcodegen generate --quiet --spec "$fixture/project.yml" --project "$fixture"
  fixture_json "$fixture" pbxproj-groups xcodegen root
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

if runs concurrency; then concurrency; fi

# A Swift Testing fixture with each shape of result in one suite: a passing test, a failing one, one disabled with a
# reason, one whose failure is a known issue, one parameterised over three arguments, and one that waits five seconds, so a
# run has a window to read its log in mid-tests. An XcodeGen framework and its tests, in a scheme of their own, so no
# other fixture or capture changes.
swift_testing() {
  fixture=$testbed/swift-testing
  rm -rf "${fixture:?}"
  mkdir -p "$fixture/Kit" "$fixture/KitTests"
  cat > "$fixture/Kit/Kit.swift" <<'EOF'
public enum Kit {
    public static let name = "Kit"
}
EOF
  cat > "$fixture/KitTests/ShapesTests.swift" <<'EOF'
import Testing
@testable import Kit

@Suite struct ShapesTests {
    @Test func passes() {
        #expect(Kit.name == "Kit")
    }

    @Test func fails() {
        #expect(Kit.name == "Other", "the name is Kit")
    }

    @Test(.disabled("skipped on purpose")) func skipped() {}

    @Test func knownIssue() {
        withKnownIssue("a known issue") {
            #expect(Kit.name == "Other")
        }
    }

    @Test(arguments: [1, 2, 3]) func parameterised(value: Int) {
        #expect(value > 0)
    }

    @Test func waits() async throws {
        try await Task.sleep(for: .seconds(5))
    }
}
EOF
  mkdir -p "$fixture/CancelTests"
  cat > "$fixture/CancelTests/CancelTests.swift" <<'EOF'
import Testing
@testable import Kit

@Suite struct CancelTests {
    @Test func passes() {
        #expect(Kit.name == "Kit")
    }

    @Test func cancels() throws {
        try Test.cancel("cancelled on purpose")
    }
}
EOF
  cat > "$fixture/project.yml" <<'EOF'
name: SwiftTesting
options:
  bundleIdPrefix: dev.xcrew.testbed
  deploymentTarget:
    iOS: "18.0"
targets:
  Kit:
    type: framework
    platform: iOS
    sources: [Kit]
    settings:
      GENERATE_INFOPLIST_FILE: YES
  KitTests:
    type: bundle.unit-test
    platform: iOS
    sources: [KitTests]
    dependencies:
      - target: Kit
    settings:
      GENERATE_INFOPLIST_FILE: YES
  CancelTests:
    type: bundle.unit-test
    platform: iOS
    sources: [CancelTests]
    dependencies:
      - target: Kit
    settings:
      GENERATE_INFOPLIST_FILE: YES
schemes:
  Kit:
    build:
      targets:
        Kit: all
    test:
      targets: [KitTests]
  Cancel:
    build:
      targets:
        Kit: all
    test:
      targets: [CancelTests]
EOF
  xcodegen generate --quiet --spec "$fixture/project.yml" --project "$fixture"
  fixture_json "$fixture" pbxproj-groups xcodegen root
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

if runs swift-testing || [ "$build" = shapes ]; then swift_testing; fi

# An XCTest bundle whose scheme's test plan has two configurations, `First` and `Second`, with no options of their own:
# a pass, a failure and a skip, run once in each.
plans_fixture() {
  fixture=$testbed/plans
  rm -rf "${fixture:?}"
  mkdir -p "$fixture/Kit" "$fixture/KitTests"
  cat > "$fixture/Kit/Kit.swift" <<'EOF'
public enum Kit {
    public static let name = "Kit"
}
EOF
  cat > "$fixture/KitTests/ProbeTests.swift" <<'EOF'
import XCTest
@testable import Kit

final class ProbeTests: XCTestCase {
    func testPasses() {
        XCTAssertEqual(Kit.name, "Kit")
    }

    func testFails() {
        XCTAssertEqual(Kit.name, "Other", "the name is Kit")
    }

    func testSkipped() throws {
        throw XCTSkip("skipped on purpose")
    }
}
EOF
  cat > "$fixture/project.yml" <<'EOF'
name: Plans
options:
  bundleIdPrefix: dev.xcrew.testbed
  deploymentTarget:
    iOS: "18.0"
targets:
  Kit:
    type: framework
    platform: iOS
    sources: [Kit]
    settings:
      GENERATE_INFOPLIST_FILE: YES
  KitTests:
    type: bundle.unit-test
    platform: iOS
    sources: [KitTests]
    dependencies:
      - target: Kit
    settings:
      GENERATE_INFOPLIST_FILE: YES
schemes:
  Kit:
    build:
      targets:
        Kit: all
    test:
      testPlans:
        - path: Plans.xctestplan
          defaultPlan: true
EOF
  # The plan names its target by the id XcodeGen gives it, so it's written once the project is.
  printf '{ "configurations" : [], "defaultOptions" : {}, "testTargets" : [], "version" : 1 }\n' > "$fixture/Plans.xctestplan"
  xcodegen generate --quiet --spec "$fixture/project.yml" --project "$fixture"
  target=$(awk '/Begin PBXNativeTarget section/ { on = 1 } /End PBXNativeTarget section/ { on = 0 } on && /\/\* KitTests \*\/ = \{/ { print $1; exit }' "$fixture/Plans.xcodeproj/project.pbxproj")
  [ -n "$target" ] || { echo "generate.sh: the plans fixture's KitTests target has no id" >&2; exit 1; }
  cat > "$fixture/Plans.xctestplan" <<EOF
{
  "configurations" : [
    { "id" : "00000000-0000-0000-0000-00000000000A", "name" : "First", "options" : {} },
    { "id" : "00000000-0000-0000-0000-00000000000B", "name" : "Second", "options" : {} }
  ],
  "defaultOptions" : {},
  "testTargets" : [
    { "target" : { "containerPath" : "container:Plans.xcodeproj", "identifier" : "$target", "name" : "KitTests" } }
  ],
  "version" : 1
}
EOF
  fixture_json "$fixture" pbxproj-groups xcodegen root
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

if runs plans || [ "$build" = multi-pass ]; then plans_fixture; fi

# An XCTest bundle its scheme runs in parallel: a pass, a failure and a skip in one class, a 5 s wait in another, so the
# two classes can run on separate clones of the simulator.
parallel_fixture() {
  fixture=$testbed/parallel
  rm -rf "${fixture:?}"
  mkdir -p "$fixture/Kit" "$fixture/KitTests"
  cat > "$fixture/Kit/Kit.swift" <<'EOF'
public enum Kit {
    public static let name = "Kit"
}
EOF
  cat > "$fixture/KitTests/ProbeTests.swift" <<'EOF'
import XCTest
@testable import Kit

final class ProbeTests: XCTestCase {
    func testPasses() {
        XCTAssertEqual(Kit.name, "Kit")
    }

    func testFails() {
        XCTAssertEqual(Kit.name, "Other", "the name is Kit")
    }

    func testSkipped() throws {
        throw XCTSkip("skipped on purpose")
    }
}
EOF
  cat > "$fixture/KitTests/SlowTests.swift" <<'EOF'
import XCTest

final class SlowTests: XCTestCase {
    func testWaits() async throws {
        try await Task.sleep(for: .seconds(5))
    }
}
EOF
  cat > "$fixture/project.yml" <<'EOF'
name: Parallel
options:
  bundleIdPrefix: dev.xcrew.testbed
  deploymentTarget:
    iOS: "18.0"
targets:
  Kit:
    type: framework
    platform: iOS
    sources: [Kit]
    settings:
      GENERATE_INFOPLIST_FILE: YES
  KitTests:
    type: bundle.unit-test
    platform: iOS
    sources: [KitTests]
    dependencies:
      - target: Kit
    settings:
      GENERATE_INFOPLIST_FILE: YES
schemes:
  Kit:
    build:
      targets:
        Kit: all
    test:
      targets:
        - name: KitTests
          parallelizable: true
EOF
  xcodegen generate --quiet --spec "$fixture/project.yml" --project "$fixture"
  fixture_json "$fixture" pbxproj-groups xcodegen root
  find "$fixture" -name xcuserdata -prune -exec rm -rf {} +
  echo "$fixture"
}

if runs parallel; then parallel_fixture; fi

# The captures' own simulator: an iPhone on the newest released iOS runtime, created for this run, booted once and reused
# by every capture, so none boots another, and deleted at the end. A parallel run's clones are xcodebuild's, which it
# boots and deletes itself. A beta runtime's system apps can crash on boot, and
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
  # `$run_ids`: this run's simulators, one id a line, the capture simulator first, then any clone a parallel run made.
  # `$watch`: what watch_run saw of each.
  run_ids=$(mktemp)
  watch=$(mktemp -d)
  printf '%s\n' "$simulator_id" > "$run_ids"
  # The reports a step expected (crash_check's argument), excused for the rest of the run and nothing else.
  expected_reports=$(mktemp)
  # A run stopped any way still deletes its simulator: a signal exits, and exiting runs the cleanup. Job control's stop
  # (SIGTSTP, as when a step reads a terminal it doesn't own) exits too, rather than leaving the run stopped for good.
  trap finish_simulator EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 148' TSTP
  # A capture that only builds names the simulator and never boots it.
  if [ "${1:-}" = --no-boot ]; then return 0; fi
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

# A simulator's service killed by its own shutdown, not a crash: EXC_CRASH with SIGKILL, ended by
# XPC_EXIT_REASON_SIGTERM_TIMEOUT (launchd's SIGTERM, then SIGKILL when the service didn't exit), in the coalition of
# this run's capture simulator or one of its clones, and written after that simulator's shutdown began: its first
# observed departure from Booted (watch_run), or for the capture simulator finish_simulator's shutdown, whichever is
# earlier. A departure is seen a second or more late, so a report written in that gap counts. All four, never the
# process name: any other SIGKILL counts.
shutdown_kill() {
  owner=$(node -e '
    const text = require("fs").readFileSync(process.argv[1], "utf8")
    const report = JSON.parse(text.slice(text.indexOf("\n") + 1))
    const killed = report.exception?.type === "EXC_CRASH" && report.exception?.signal === "SIGKILL"
    const byShutdown = report.termination?.indicator === "XPC_EXIT_REASON_SIGTERM_TIMEOUT"
    const prefix = "com.apple.CoreSimulator.SimDevice."
    const coalition = report.coalitionName ?? ""
    if (killed && byShutdown && coalition.startsWith(prefix)) console.log(coalition.slice(prefix.length))
  ' "$1" 2> /dev/null) || return 1
  [ -n "$owner" ] || return 1
  if [ -n "${watch:-}" ] && [ -f "$watch/$owner.departed" ] && [ "$1" -nt "$watch/$owner.departed" ]; then return 0; fi
  [ "$owner" = "$simulator_id" ] && [ -n "${shutdown_marker:-}" ] && [ "$1" -nt "$shutdown_marker" ]
}

# The reports since the run began that name one of this run's simulators and aren't a known crash; the known ones are
# listed.
simulator_crashes() {
  find "$HOME/Library/Logs/DiagnosticReports" -newer "$crash_marker" -name '*.ips' 2> /dev/null | while IFS= read -r report; do
    if shutdown_kill "$report"; then continue; fi
    grep -q -F -f "$run_ids" "$report" || continue
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
    echo "generate.sh: stopping: the capture simulator ($simulator_id) or a clone of it crashed" >&2
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
  # A run stopped mid-call stops the call too, so xcodebuild makes no clone after this.
  if [ -n "${call:-}" ]; then kill "$call" 2> /dev/null || true; fi
  shutdown_marker=$(mktemp)
  xcrun simctl shutdown "$simulator_id" 2> /dev/null || true
  xcrun simctl delete "$simulator_id"
  # xcodebuild deletes its clones when the run ends. One it left is deleted here, and only one of this run's that is
  # named a clone of the capture simulator: a device another project's run made in the testing set is never touched.
  clones=$(tail -n +2 "$run_ids")
  for clone in $clones; do
    if xcrun simctl --set testing list devices 2> /dev/null | grep -q -F "of $simulator ($clone)"; then
      echo "generate.sh: xcodebuild left its clone $clone; deleting it" >&2
      touch "$watch/$clone.departed"
      sleep 1
      xcrun simctl --set testing shutdown "$clone" 2> /dev/null || true
      xcrun simctl --set testing delete "$clone" 2> /dev/null || true
    fi
  done
  # The shutdown kills the simulator's services, and their SIGKILL reports land up to half a minute later: wait for
  # them, and leave out only those, so a real crash during the shutdown still counts.
  sleep 45
  # A report of the capture simulator names its id, in its coalition or its paths; the Mac's own apps may crash too,
  # which is no fault of the run.
  ours=$(simulator_crashes)
  others=$(find "$HOME/Library/Logs/DiagnosticReports" -newer "$crash_marker" -name '*.ips' 2> /dev/null | while IFS= read -r report; do
    grep -q -F -f "$run_ids" "$report" || echo "$report"
  done)
  if [ -n "$clones" ]; then echo "generate.sh: this run's clones: $(printf '%s' "$clones" | tr '\n' ' ')" >&2; fi
  rm -f "$crash_marker" "$shutdown_marker" "$expected_reports" "$run_ids"
  rm -rf "${watch:?}"
  if [ -n "$others" ]; then
    echo "generate.sh: other crash reports appeared during the run, not this run's simulators':" >&2
    echo "$others" >&2
  fi
  if [ -n "$ours" ]; then
    echo "generate.sh: the capture simulator ($simulator_id) or a clone of it crashed during the run:" >&2
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
    perl -pe 'BEGIN { ($w, $r, $n) = @ARGV; @ARGV = (); ($we, $re, $ne) = map { (my $e = $_) =~ s#/#\\/#g; $e } $w, $r, $n } s#\Q$we\E#$ne#g; s#\Q$re\E#$ne#g; s#\Q$w\E#$n#g; s#\Q$r\E#$n#g' "$written" "$resolved" /testbed/captures/coverage | neutral_path
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
      "$resolved" "$(cd "$fixture" && pwd)" "$(cd "$derived" && pwd -P)" "$derived" "$HOME" "$(cd "${TMPDIR:-/tmp}" && pwd -P)" "${TMPDIR%/}" | neutral_path
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
      "$resolved" "$(cd "$fixture" && pwd)" "$(cd "$derived" && pwd -P)" "$derived" "$HOME" | neutral_path
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
      "$resolved" "$(cd "$fixture" && pwd)" "$(cd "$derived" && pwd -P)" "$derived" "$HOME" | neutral_path
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

# Captures of the field fixture's scenarios, as MobileBuildMCP answers
# them to Claude: its MCP results, the logs they name, and what xcresulttool and xccov answer about each run's bundle.
# They run on a copy of field/, so a scenario's edit never reaches the fixture. Tests replay them.
# - probes: the five probe tests, five times each, relaunched every time
# - crash: the crashing test, with its crash log
# - coverage: one test run with coverage on, the half-tested file's line counts, and each target's counts
# - lldb-expr: LLDB's `expr` on the running app under the default debugger backend
# - two-display: a two-display device's screenshot error, from MobileBuildMCP's tool and simctl's message, not a run
# - empty-filter: a selection matching no test
# - type-error: a build failing on a plain type error, with the pinned Xcode not the one building
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
  neutral() { neutralise "$resolved" /testbed/field "$work" /testbed/field "$(cd "$derived" && pwd -P)" /testbed/DerivedData "$derived" /testbed/DerivedData; }
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
    log=$(named_log "$results/$1.txt")
    if [ -n "$log" ] && [ -f "$log" ]; then neutral < "$log" | uuids_out > "$out/$1.log"; fi
  }
  # The bundle a test call names.
  bundle_of() {
    awk '/└── ~\/.*\/$/ { root = $NF } /result-bundles\/.*\.xcresult/ { for (i = 1; i <= NF; i++) if ($i ~ /\.xcresult$/) print root $i }' "$results/$1.txt" | head -1 | sed "s#^~#$HOME#"
  }
  answers() {
    bundle=$(bundle_of "$1")
    [ -n "$bundle" ] || return 0
    bundle_answers "$bundle" "$1"
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
  # lldb-expr: LLDB's `expr` on the running app, under MobileBuildMCP's default debugger backend, which refuses it.
  if takes lldb-expr; then
    calls lldb-expr session_set_defaults '{"scheme":"App"}' build_run_sim '{}' debug_attach_sim '{"bundleId":"dev.xcrew.testbed.App"}' debug_lldb_command '{"command":"expr 1 + 1"}'
  fi
  # two-display: a screenshot of a device with two displays. Its device, the iPhone Duo, runs only on a runtime of its own, not
  # a released one, so nothing boots: MobileBuildMCP's own screenshot tool runs against an `xcrun` that lists the
  # device as booted and fails `simctl io … screenshot` with simctl's message, read from CoreSimulator's simctl
  # (`Cannot choose between %lu displays. Specify one with --display:`, then a line per display, which only a run can
  # fill and is left out). A real run needs a Mac with that device's runtime.
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
  # With what its bundle says: the text writes "Test succeeded" with no count for no test run and for counts unknown alike.
  if takes empty-filter; then
    call empty-filter test_sim '{"extraArgs":["-only-testing:FeatureTests/NoSuchTests"]}'
    answers empty-filter
  fi
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
  printf '{\n  "replay": "each <scenario>.txt is MobileBuildMCP'"'"'s MCP result on a copy of field/, the .log beside it the log it names, and .tests.json, .summary.json and .details.<test>.json what xcresulttool answered about its result bundle; crash.ips is the crashing test'"'"'s crash log, coverage.*.json what xccov answered; tests read them and never build",\n  "two-display": "not a run: taken from MobileBuildMCP'"'"'s source and the reported error text, MobileBuildMCP'"'"'s own screenshot tool against an xcrun that fails simctl io … screenshot with simctl'"'"'s message from CoreSimulator'"'"'s simctl, its per-display lines left out; a real run needs a Mac with that device'"'"'s runtime",\n  "mobilebuildmcp": "%s"\n}\n' "$(mobilebuildmcp --version | tail -1)" > "$out/capture.json"
  echo "$out"
}

# The concurrency fixture's diagnostics, as each tool gives them: xcodebuild's own logs of the `Warnings` scheme and of
# the `App` scheme, which fails, and MobileBuildMCP's build_sim of `Warnings` with the log it names. Only builds: the
# capture simulator is named, not booted, and its state after build_sim is said; were it booted, its crashes count as
# any capture's.
concurrency_captures() {
  out=$testbed/captures/concurrency
  rm -rf "${out:?}"
  mkdir -p "$out"
  work=$(mktemp -d)/concurrency
  cp -R "$testbed/concurrency" "$work"
  derived=$(mktemp -d)
  results=$(mktemp -d)
  resolved=$(cd "$work" && pwd -P)
  neutral() { neutralise "$resolved" /testbed/concurrency "$work" /testbed/concurrency "$(cd "$derived" && pwd -P)" /testbed/DerivedData "$derived" /testbed/DerivedData; }
  for scheme in Warnings App; do
    (cd "$work" && xcodebuild build -project Concurrency.xcodeproj -scheme "$scheme" -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived") > "$results/$scheme.log" 2>&1 || true
  done
  neutral < "$results/Warnings.log" | uuids_out > "$out/xcodebuild-warnings.log"
  neutral < "$results/App.log" | uuids_out > "$out/xcodebuild-errors.log"
  rm -rf "${derived:?}"
  derived=$(mktemp -d)
  mkdir -p "$work/.mobilebuildmcp"
  printf "schemaVersion: 1\nsessionDefaults:\n  projectPath: '%s'\n  scheme: 'Warnings'\n  simulatorName: '%s'\n  derivedDataPath: '%s'\n" "$resolved/Concurrency.xcodeproj" "$simulator" "$derived" > "$work/.mobilebuildmcp/config.yaml"
  node scripts/mcp-call.mjs "$work" build_sim > "$results/build_sim.txt" || true
  state=$(xcrun simctl list devices --json | node -e 'const d = JSON.parse(require("fs").readFileSync(0, "utf8")).devices; console.log(Object.values(d).flat().find(x => x.udid === process.argv[1])?.state ?? "gone")' "$simulator_id")
  echo "generate.sh: the capture simulator was $state after build_sim" >&2
  if [ "$state" != Shutdown ]; then crash_check; fi
  neutral < "$results/build_sim.txt" | uuids_out > "$out/build_sim.txt"
  log=$(grep -o '~/[^ ]*\.log' "$results/build_sim.txt" | head -1 | sed "s#^~#$HOME#")
  if [ -n "$log" ] && [ -f "$log" ]; then neutral < "$log" | uuids_out > "$out/build_sim.log"; fi
  rm -rf "${work:?}" "${derived:?}" "${results:?}"
  printf '{\n  "replay": "xcodebuild-warnings.log and xcodebuild-errors.log are xcodebuild'"'"'s own logs of concurrency/'"'"'s Warnings and App schemes, for a generic iOS Simulator destination; build_sim.txt is MobileBuildMCP'"'"'s MCP result for Warnings and build_sim.log the log it names; tests read them and never build",\n  "simulator": "%s",\n  "mobilebuildmcp": "%s"\n}\n' "$state after build_sim, never booted by the capture" "$(mobilebuildmcp --version | tail -1)" > "$out/capture.json"
  echo "$out"
}

# What captures/raw holds, for every step that writes there.
raw_manifest() {
  printf '{\n  "replay": "each <name>.json is MobileBuildMCP'"'"'s whole JSON-RPC result, content and structuredContent, <name>.log the log it names, and <name>.tests.json, .summary.json and .details.<test>.json what xcresulttool answered about the result bundle it names. On a copy of field/: serial is test_sim of FeatureTests/ProbeTests with -parallel-testing-enabled NO, swift-testing the Core scheme'"'"'s Swift Testing tests, profile a call naming no scheme under a profile whose scheme is Data, empty-filter a selection matching no test, timing FeatureTests/ProbeTests and FeatureTests/CrashTests with -parallel-testing-enabled NO and showTestTiming on, its crash log as timing.crash.ips, test-build-failed FeatureTests/ProbeTests with a type error written into its test file. session-defaults session_show_defaults with two profiles, probe active, and profile-switched session_use_defaults_profile to unit, neither persisted, retry FeatureTests/ProbeTests with -parallel-testing-enabled NO -retry-tests-on-failure -test-iterations 3. On a copy of plans/: configurations is the Kit scheme'"'"'s test plan, its configurations First and Second. On a copy of concurrency/: build_sim is the Warnings scheme'"'"'s build, its simulator never booted. On a copy of swift-testing/: shapes is the Kit scheme'"'"'s run, shapes-iterations the same with -test-iterations 2, cancel the Cancel scheme'"'"'s. Each <name>-snapshots.json and <name>-midrun.log is the live log, copied each second while it ran. Tests read them and never build",\n  "mobilebuildmcp": "%s"\n}\n' "$(mobilebuildmcp --version | tail -1)" > "$testbed/captures/raw/capture.json"
}

# Result bundle `$1`'s answers to what xcrew asks it, as `<name>` (`$2`) in `$out`, through the calling step's `neutral`:
# `<name>.tests.json` and `<name>.summary.json`, and `<name>.details.<Class.test>.json` for each test that failed or
# failed as expected, an XCTest expected failure or a Swift Testing known issue. Each answer must be JSON, or the step
# stops. xcresulttool writes a duration in the Mac's locale ("0,00013 seconds" where a comma is the decimal mark), and
# it's kept as written.
bundle_answers() {
  bundle_answer "$1" "$out/$2.tests.json" tests
  bundle_answer "$1" "$out/$2.summary.json" summary
  failed=$(node -e '
    const walk = n => [...(n.nodeType === "Test Case" && ["Failed", "Expected Failure"].includes(n.result) ? [n.nodeIdentifier] : []), ...(n.children ?? []).flatMap(walk)]
    console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).testNodes.flatMap(walk).join("\n"))
  ' "$out/$2.tests.json")
  printf '%s\n' "$failed" | while IFS= read -r test; do
    [ -n "$test" ] || continue
    bundle_answer "$1" "$out/$2.details.$(printf '%s' "$test" | sed 's#/#.#g; s#()$##').json" test-details --test-id "$test"
  done
}

# One xcresulttool answer about bundle `$1`, neutralised into `$2`: `get test-results <the rest>`. Stops the step when
# xcresulttool fails or its answer isn't JSON.
bundle_answer() {
  answer=$(xcrun xcresulttool get test-results "$3" ${4:+"$4"} ${5:+"$5"} --path "$1" --compact) || { echo "generate.sh: xcresulttool couldn't answer $3 for $1" >&2; exit 1; }
  printf '%s\n' "$answer" | neutral | uuids_out > "$2"
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$2" 2> /dev/null || { echo "generate.sh: $2 isn't JSON" >&2; exit 1; }
}

# The log a MobileBuildMCP result's text names, written from `~`: on its own, or as `logs/…` in the folder tree below
# its workspace's `└── ~/…/` line, as a test run's result writes it.
named_log() {
  log=$(grep -o '~/[^ ]*\.log' "$1" | head -1)
  if [ -z "$log" ]; then
    root=$(grep -o '└── ~/[^ ]*/$' "$1" | head -1 | sed 's#^└── ##')
    file=$(grep -oE 'logs/[^ ]+\.log' "$1" | head -1)
    if [ -n "$root" ] && [ -n "$file" ]; then log=$root$file; fi
  fi
  printf '%s' "$log" | sed "s#^~#$HOME#"
}

# The result bundle a raw capture's JSON names, written from `~`, when it's on this Mac.
raw_bundle() {
  bundle=$(grep -o '~/[^ "\\]*\.xcresult' "$1" | head -1 | sed "s#^~#$HOME#")
  if [ -n "$bundle" ] && [ -d "$bundle" ]; then echo "$bundle"; fi
}

# Raw MobileBuildMCP results, whole as JSON-RPC answers them (`content` and `structuredContent`), with the log each names:
# a serial XCTest run, a Swift Testing run, a run under a session-defaults profile that names its scheme, called with
# no scheme, a selection matching no test, a serial run with a crash and `showTestTiming` on, and a run whose test target
# doesn't build. On a copy of field/, on
# the capture simulator. RAW_CAPTURES names the
# ones to take again (`empty-filter`); unset, all of them. Either way the folder's other captures stay.
raw_captures() {
  out=$testbed/captures/raw
  wanted=${RAW_CAPTURES:-serial swift-testing profile empty-filter timing test-build-failed}
  takes() { case " $wanted " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
  mkdir -p "$out"
  work=$(mktemp -d)/field
  cp -R "$testbed/field" "$work"
  derived=$(mktemp -d)
  results=$(mktemp -d)
  resolved=$(cd "$work" && pwd -P)
  neutral() { neutralise "$resolved" /testbed/field "$work" /testbed/field "$(cd "$derived" && pwd -P)" /testbed/DerivedData "$derived" /testbed/DerivedData; }
  configure() {
    mkdir -p "$work/.mobilebuildmcp"
    printf '%s' "$1" > "$work/.mobilebuildmcp/config.yaml"
  }
  # One raw call, kept as `<name>.json`, and the log it names as `<name>.log`; `$3` names a test expected to crash.
  raw() {
    MCP_RAW=1 node scripts/mcp-call.mjs "$work" test_sim "$2" > "$results/$1.json" || true
    # An expected crash's report lands a little after the process ends: wait for it, so this step's check sees it.
    if [ -n "${3:-}" ]; then sleep 20; fi
    crash_check "${3:-}"
    neutral < "$results/$1.json" | uuids_out > "$out/$1.json"
    log=$(grep -o '~/[^ "\\]*\.log' "$results/$1.json" | head -1 | sed "s#^~#$HOME#")
    if [ -n "$log" ] && [ -f "$log" ]; then neutral < "$log" | uuids_out > "$out/$1.log"; fi
    bundle=$(raw_bundle "$results/$1.json")
    if [ -n "$bundle" ]; then bundle_answers "$bundle" "$1"; fi
  }
  # test_sim takes its scheme from the session defaults, never as an argument ("scheme is required" otherwise).
  defaults() {
    printf "schemaVersion: 1\nsessionDefaults:\n  workspacePath: '%s'\n  scheme: '%s'\n  simulatorName: '%s'\n  derivedDataPath: '%s'\n" "$resolved/Field.xcworkspace" "$1" "$simulator" "$derived"
  }
  for name in $wanted; do rm -f "$out/$name.json" "$out/$name.log" "$out/$name.tests.json" "$out/$name.summary.json" "$out/$name".details.*.json "$out/$name.crash.ips"; done
  if takes serial; then
    configure "$(defaults Feature)"
    raw serial '{"extraArgs":["-only-testing:FeatureTests/ProbeTests","-parallel-testing-enabled","NO"]}'
  fi
  if takes swift-testing; then
    configure "$(defaults Core)"
    raw swift-testing '{}'
  fi
  if takes profile; then
    configure "$(printf "schemaVersion: 1\nsessionDefaultsProfiles:\n  unit:\n    workspacePath: '%s'\n    scheme: 'Data'\n    simulatorName: '%s'\n    derivedDataPath: '%s'\nactiveSessionDefaultsProfile: unit\n" "$resolved/Field.xcworkspace" "$simulator" "$derived")"
    raw profile '{}'
  fi
  # The same selection as field/'s empty-filter, whose bundle answers are kept there.
  if takes empty-filter; then
    configure "$(defaults Feature)"
    raw empty-filter '{"extraArgs":["-only-testing:FeatureTests/NoSuchTests"]}'
  fi
  # A test run whose test target doesn't build: a type error written into the probes' test file, on the copy alone and
  # taken out after. The run came to that, or the capture proves nothing: the step checks the call failed and its
  # result names the error's file and line, and stops otherwise.
  if takes test-build-failed; then
    probes=$work/Modules/Feature/Tests/ProbeTests.swift
    line=$(($(wc -l < "$probes") + 2))
    printf '\nlet testBuildError: Int = "not a number"\n' >> "$probes"
    configure "$(defaults Feature)"
    raw test-build-failed '{"extraArgs":["-only-testing:FeatureTests/ProbeTests"]}'
    cp "$testbed/field/Modules/Feature/Tests/ProbeTests.swift" "$probes"
    node -e '
      const result = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))
      const text = (result.content ?? []).map(part => part.text ?? "").join("")
      const wrong = [[result.isError === true, "the call failed"], [text.includes(`ProbeTests.swift:${process.argv[2]}`), `the result names ProbeTests.swift:${process.argv[2]}`]].filter(([holds]) => !holds)
      if (wrong.length > 0) { console.error(`generate.sh: stopping: the test build failure capture isn\x27t one: ${wrong.map(([, what]) => what).join(", ")} didn\x27t hold`); process.exit(1) }
    ' "$out/test-build-failed.json" "$line"
  fi
  # field/'s probes and its crash, serial, with `showTestTiming` on, which lists every test under `Test Results:`. Its one
  # expected crash, testOutOfRange, is excused for this call alone, and the crash log the bundle attached is kept.
  if takes timing; then
    configure "$(defaults Feature)
showTestTiming: true
"
    raw timing '{"extraArgs":["-only-testing:FeatureTests/ProbeTests","-only-testing:FeatureTests/CrashTests","-parallel-testing-enabled","NO"]}' testOutOfRange
    bundle=$(raw_bundle "$results/timing.json")
    if [ -n "$bundle" ]; then
      mkdir -p "$results/timing-export"
      xcrun xcresulttool export attachments --path "$bundle" --output-path "$results/timing-export" --only-failures > /dev/null
      report=$(find "$results/timing-export" -name '*.ips' | head -1)
      if [ -n "$report" ]; then neutral < "$report" | uuids_out > "$out/timing.crash.ips"; fi
    fi
  fi
  rm -rf "${work:?}" "${derived:?}" "${results:?}"
  raw_manifest
  echo "$out"
}

# MobileBuildMCP's session tools' answers whole, as JSON-RPC gives them: session_show_defaults with two profiles, the
# first active, and session_use_defaults_profile switching to the second. Neither persists: each changes only the
# server's own session, so the project's config must come out as it went in, or the step stops. On a copy of field/,
# its simulator named and never booted.
raw_session_captures() {
  out=$testbed/captures/raw
  mkdir -p "$out"
  rm -f "$out/session-defaults.json" "$out/profile-switched.json"
  work=$(mktemp -d)/field
  cp -R "$testbed/field" "$work"
  derived=$(mktemp -d)
  results=$(mktemp -d)
  resolved=$(cd "$work" && pwd -P)
  neutral() { neutralise "$resolved" /testbed/field "$work" /testbed/field "$(cd "$derived" && pwd -P)" /testbed/DerivedData "$derived" /testbed/DerivedData; }
  mkdir -p "$work/.mobilebuildmcp"
  profile() { printf "  %s:\n    workspacePath: '%s'\n    scheme: '%s'\n    simulatorName: '%s'\n    derivedDataPath: '%s'\n" "$1" "$resolved/Field.xcworkspace" "$2" "$simulator" "$derived"; }
  printf 'schemaVersion: 1\nsessionDefaultsProfiles:\n%s%sactiveSessionDefaultsProfile: probe\n' "$(profile probe Feature)
" "$(profile unit Data)
" > "$work/.mobilebuildmcp/config.yaml"
  config=$(shasum -a 256 < "$work/.mobilebuildmcp/config.yaml")
  MCP_RAW=1 node scripts/mcp-call.mjs "$work" session_show_defaults '{}' > "$results/session-defaults.json" || true
  MCP_RAW=1 node scripts/mcp-call.mjs "$work" session_use_defaults_profile '{"profile":"unit"}' > "$results/profile-switched.json" || true
  if [ "$(shasum -a 256 < "$work/.mobilebuildmcp/config.yaml")" != "$config" ]; then
    echo "generate.sh: stopping: a session call wrote the project's config" >&2
    exit 1
  fi
  state=$(xcrun simctl list devices --json | node -e 'const d = JSON.parse(require("fs").readFileSync(0, "utf8")).devices; console.log(Object.values(d).flat().find(x => x.udid === process.argv[1])?.state ?? "gone")' "$simulator_id")
  echo "generate.sh: the capture simulator was $state after the session calls" >&2
  if [ "$state" != Shutdown ]; then crash_check; fi
  for name in session-defaults profile-switched; do neutral < "$results/$name.json" | uuids_out > "$out/$name.json"; done
  rm -rf "${work:?}" "${derived:?}" "${results:?}"
  raw_manifest
  echo "$out"
}

# MobileBuildMCP's build_sim answer whole, as JSON-RPC gives it, with the log it names: concurrency/'s Warnings scheme,
# which builds with its concurrency warnings. It only builds: its simulator is named and never booted.
raw_build_capture() {
  out=$testbed/captures/raw
  mkdir -p "$out"
  rm -f "$out/build_sim.json" "$out/build_sim.log"
  work=$(mktemp -d)/concurrency
  cp -R "$testbed/concurrency" "$work"
  derived=$(mktemp -d)
  results=$(mktemp -d)
  resolved=$(cd "$work" && pwd -P)
  neutral() { neutralise "$resolved" /testbed/concurrency "$work" /testbed/concurrency "$(cd "$derived" && pwd -P)" /testbed/DerivedData "$derived" /testbed/DerivedData; }
  mkdir -p "$work/.mobilebuildmcp"
  printf "schemaVersion: 1\nsessionDefaults:\n  projectPath: '%s'\n  scheme: 'Warnings'\n  simulatorName: '%s'\n  derivedDataPath: '%s'\n" "$resolved/Concurrency.xcodeproj" "$simulator" "$derived" > "$work/.mobilebuildmcp/config.yaml"
  MCP_RAW=1 node scripts/mcp-call.mjs "$work" build_sim > "$results/build_sim.json" || true
  state=$(xcrun simctl list devices --json | node -e 'const d = JSON.parse(require("fs").readFileSync(0, "utf8")).devices; console.log(Object.values(d).flat().find(x => x.udid === process.argv[1])?.state ?? "gone")' "$simulator_id")
  echo "generate.sh: the capture simulator was $state after build_sim" >&2
  if [ "$state" != Shutdown ]; then crash_check; fi
  neutral < "$results/build_sim.json" | uuids_out > "$out/build_sim.json"
  log=$(grep -o '~/[^ "\\]*\.log' "$results/build_sim.json" | head -1 | sed "s#^~#$HOME#")
  if [ -n "$log" ] && [ -f "$log" ]; then neutral < "$log" | uuids_out > "$out/build_sim.log"; fi
  rm -rf "${work:?}" "${derived:?}" "${results:?}"
  raw_manifest
  echo "$out"
}

# The Xcode MCP's answers, raw: its handshake and its tools. Never part of a full run, and run only by hand on this Mac,
# on this repository's own fixture: the selected Xcode must already be open, opened by its own path, with field/'s
# workspace in it, and Xcode asks whether to let the caller in, which only the person at the Mac answers. The build and
# test calls join once the tools list shows their arguments.
xcode_mcp_captures() {
  out=$testbed/captures/xcode-mcp
  app=$(xcode-select -p | sed 's#/Contents/Developer$##')
  if ! pgrep -f -x "$app/Contents/MacOS/Xcode" > /dev/null; then
    echo "generate.sh: open $app first, by that path, with $testbed/field/Field.xcworkspace in it" >&2
    exit 1
  fi
  rm -rf "${out:?}"
  mkdir -p "$out"
  resolved=$(cd "$testbed/field" && pwd -P)
  neutral() { neutralise "$resolved" /testbed/field; }
  for step in initialize tools/list; do
    name=$(printf '%s' "$step" | tr '/' '-')
    MCP_RAW=1 MCP_SERVER=xcode node scripts/mcp-call.mjs "$testbed/field" "$step" > "$out/$name.raw" || true
    neutral < "$out/$name.raw" | uuids_out > "$out/$name.json"
    rm -f "$out/$name.raw"
  done
  printf '{\n  "replay": "initialize.json and tools-list.json are the Xcode MCP'"'"'s (xcrun mcpbridge) raw answers to the handshake and to tools/list, Xcode open on field/; tests read them",\n  "xcode": "%s"\n}\n' "$xcode" > "$out/capture.json"
  bash scripts/leaks.sh
  echo "$out"
}

# One raw test_sim call in `$work`, kept as `<results>/<name>.json`, its live log copied each second while it runs as
# `snapshot-<n>.log`, and this run's simulators watched each second (watch_run).
watched_call() {
  started=$(mktemp)
  before=$(mktemp)
  device_states --set testing | cut -d ' ' -f 1 > "$before"
  MCP_RAW=1 node scripts/mcp-call.mjs "$work" test_sim "$3" > "$1/$2.json" &
  call=$!
  n=0
  while kill -0 "$call" 2> /dev/null; do
    live=$(find "$HOME/Library/Developer/MobileBuildMCP/workspaces" -path '*/logs/test_sim_*.log' -newer "$started" 2> /dev/null | head -1)
    if [ -n "$live" ]; then n=$((n + 1)); cp "$live" "$1/snapshot-$(printf '%03d' "$n").log"; fi
    watch_run "$before"
    sleep 1
  done
  wait "$call" || true
  call=
  watch_run "$before"
  rm -f "$started" "$before"
}

# One look at this run's simulators. A clone is this run's when it appears in the testing device set, where xcodebuild
# makes a parallel run's clones, and wasn't there before the call (`$1`); the set is read each second, since xcodebuild
# deletes its clones as the run ends. A simulator seen Booted gets `<id>.booted` in `$watch`, and the first look that
# finds it otherwise, shut down or gone, gets `<id>.departed`: the moment its shutdown's reports count from
# (shutdown_kill). xcodebuild shuts the capture simulator down to clone it, and its clones as the run ends.
watch_run() {
  testing=$(device_states --set testing)
  printf '%s\n' "$testing" | cut -d ' ' -f 1 | grep . | grep -v -x -F -f "$1" | grep -v -x -F -f "$run_ids" >> "$run_ids" || true
  states=$(device_states; printf '%s\n' "$testing")
  while IFS= read -r id; do
    state=$(printf '%s\n' "$states" | grep -F "$id " | cut -d ' ' -f 2-)
    if [ "$state" = Booted ]; then
      touch "$watch/$id.booted"
    elif [ -f "$watch/$id.booted" ] && [ ! -f "$watch/$id.departed" ]; then
      touch "$watch/$id.departed"
    fi
  done < "$run_ids"
}

# Each simulator in a device set as `<id> <state>`, one a line: the default set, or the one `--set <name>` names.
device_states() {
  xcrun simctl "$@" list devices --json 2> /dev/null | node -e '
    // simctl may answer nothing while CoreSimulator is busy cloning: that look sees no device.
    const text = require("fs").readFileSync(0, "utf8")
    const devices = (text.trim() ? JSON.parse(text).devices : null) ?? {}
    for (const device of Object.values(devices).flat()) console.log(`${device.udid} ${device.state}`)
  '
}

# Where each marker stood in each copy of `<results>`'s live log, as `<name>-snapshots.json`, and the copy taken
# mid-tests as `<name>-midrun.log`: the last with the tests' build done or the tests started, and no verdict yet. A
# parallel run's log holds no test line before its verdict, so its copy is the last after `** TEST BUILD SUCCEEDED **`.
# MobileBuildMCP writes "Testing started" itself, after the tests.
midrun_copy() {
  node -e '
    const fs = require("fs")
    const [folder, out] = process.argv.slice(1)
    const markers = { testingStarted: /^Testing started$/, testSuiteStarted: /^Test Suite .* started at /, swiftTestingStarted: /^◇ Test run started\.$/, testExecute: /^\*\* TEST EXECUTE /, firstResult: /^Test [Cc]ase '.*' (passed|failed|skipped)/, testBuildSucceeded: /^\*\* TEST BUILD SUCCEEDED \*\*$/ }
    const snapshots = fs.readdirSync(folder).filter(name => /^snapshot-\d+\.log$/.test(name)).sort().map(name => {
      const lines = fs.readFileSync(`${folder}/${name}`, "utf8").split("\n")
      const at = Object.fromEntries(Object.entries(markers).map(([key, pattern]) => [key, (lines.findIndex(line => pattern.test(line)) + 1) || null]))
      return { snapshot: name, lines: lines.length, ...at }
    })
    fs.writeFileSync(out, JSON.stringify({ everySeconds: 1, snapshots }, null, 2) + "\n")
  ' "$1" "$out/$2-snapshots.json"
  middle=$(node -e '
    const listing = require(process.argv[1]).snapshots
    const mid = listing.filter(s => (s.testSuiteStarted || s.swiftTestingStarted || s.firstResult || s.testBuildSucceeded) && !s.testExecute).pop()
    if (mid) console.log(mid.snapshot)
  ' "$out/$2-snapshots.json")
  if [ -n "$middle" ]; then neutral < "$1/$middle" | uuids_out > "$out/$2-midrun.log"; fi
}


# A watched raw test_sim run of the fixture `$1`, whose project is `$2`, kept in captures/raw as `<name>.json` (`$3`) and
# the log it names as `<name>.log`, with where the live log's markers stood each second (midrun_copy). `$4` is
# test_sim's arguments, and `$5` a node check the result and log must pass, or the capture proves nothing and the step
# stops. `$6` is the scheme, `Kit` unless named; a project that's a `.xcworkspace` is opened as one. On the capture
# simulator.
watched_capture() {
  out=$testbed/captures/raw
  mkdir -p "$out"
  rm -f "$out/$3.json" "$out/$3.log" "$out/$3-snapshots.json" "$out/$3-midrun.log" "$out/$3.tests.json" "$out/$3.summary.json" "$out/$3".details.*.json
  work=$(mktemp -d)/$1
  cp -R "$testbed/$1" "$work"
  derived=$(mktemp -d)
  results=$(mktemp -d)
  resolved=$(cd "$work" && pwd -P)
  label=/testbed/$1
  neutral() { neutralise "$resolved" "$label" "$work" "$label" "$(cd "$derived" && pwd -P)" /testbed/DerivedData "$derived" /testbed/DerivedData; }
  mkdir -p "$work/.mobilebuildmcp"
  case $2 in *.xcworkspace) container=workspacePath ;; *) container=projectPath ;; esac
  printf "schemaVersion: 1\nsessionDefaults:\n  %s: '%s'\n  scheme: '%s'\n  simulatorName: '%s'\n  derivedDataPath: '%s'\n" "$container" "$resolved/$2" "${6:-Kit}" "$simulator" "$derived" > "$work/.mobilebuildmcp/config.yaml"
  watched_call "$results" "$3" "$4"
  crash_check
  log=$(grep -o '~/[^ "\\]*\.log' "$results/$3.json" | head -1 | sed "s#^~#$HOME#")
  node -e "$5" "$results/$3.json" "$log"
  midrun_copy "$results" "$3"
  neutral < "$results/$3.json" | uuids_out > "$out/$3.json"
  if [ -n "$log" ] && [ -f "$log" ]; then neutral < "$log" | uuids_out > "$out/$3.log"; fi
  bundle=$(raw_bundle "$results/$3.json")
  if [ -n "$bundle" ]; then bundle_answers "$bundle" "$3"; fi
  rm -rf "${work:?}" "${derived:?}" "${results:?}"
  echo "$out/$3.json"
}

# Swift Testing's shapes of result in one suite, the swift-testing fixture's. The run must come to what the suite holds:
# one failure, `fails()`, the disabled test skipped, and the parameterised and waiting tests passed.
shapes_captures() {
  watched_capture swift-testing SwiftTesting.xcodeproj shapes '{}' '
    const fs = require("fs")
    const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    const data = result.structuredContent?.data ?? {}
    const failures = data.diagnostics?.testFailures ?? []
    const log = fs.readFileSync(process.argv[2], "utf8")
    const wrong = [
      [result.structuredContent?.schema === "mobilebuildmcp.output.test-result", "the run completed"],
      [failures.length === 1 && failures[0].test === "fails()", "exactly one failure, fails()"],
      [data.summary?.counts?.failed === 1, "one failed"],
      [/Test skipped\(\) skipped/.test(log), "skipped() skipped"],
      [/Test parameterised\(value:\) with 3 test cases passed/.test(log), "parameterised ran its three cases"],
      [/Test waits\(\) passed/.test(log), "waits() passed"],
    ].filter(([ok]) => !ok).map(([, what]) => what)
    if (wrong.length) { console.error(`generate.sh: the shapes run did not come to what its suite holds: ${wrong.join(", ")}`); process.exit(1) }
  '
}

# XCTest's parallel runner, the parallel fixture's, two workers at most, so three simulators at most, never a number
# xcodebuild picks. The run must come to what the bundle holds, on the parallel runner: one failure, testFails, one
# skipped, and the waiting test passed. On the capture simulator and the clones xcodebuild makes of it.
parallel_captures() {
  watched_capture parallel Parallel.xcodeproj parallel '{"extraArgs":["-parallel-testing-enabled","YES","-parallel-testing-worker-count","2"]}' '
    const fs = require("fs")
    const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    const data = result.structuredContent?.data ?? {}
    const failures = data.diagnostics?.testFailures ?? []
    const log = fs.readFileSync(process.argv[2], "utf8")
    const wrong = [
      [result.structuredContent?.schema === "mobilebuildmcp.output.test-result", "the run completed"],
      [failures.length === 1 && /testFails/.test(failures[0].test ?? ""), "exactly one failure, testFails"],
      [data.summary?.counts?.failed === 1, "one failed"],
      [data.summary?.counts?.skipped === 1, "one skipped"],
      [/ on .Clone /.test(log), "the parallel runner ran it"],
      [/testWaits.* passed/.test(log), "testWaits passed"],
    ].filter(([ok]) => !ok).map(([, what]) => what)
    if (wrong.length) { console.error(`generate.sh: the parallel run did not come to what its bundle holds: ${wrong.join(", ")}`); process.exit(1) }
  '
}

# The bundle answers of the raw captures already committed, from the bundles MobileBuildMCP kept on this Mac: no
# simulator, no new run. All are written, or none: a bundle that's gone is named, and an answer that fails stops the
# step before anything is moved in. Each run's work copy was a temporary folder, gone since; it's found in the answers
# and neutralised as the capture's own step did. Not empty-filter, whose answers field/ keeps, nor parallel, which isn't
# committed, nor multi-pass's four; a fresh `raw`, `parallel` or `multi-pass` capture writes its own.
raw_answers() {
  kept="serial swift-testing profile shapes"
  gone=
  for name in $kept; do
    if [ -z "$(raw_bundle "$testbed/captures/raw/$name.json")" ]; then gone="$gone $name"; fi
  done
  if [ -n "$gone" ]; then
    echo "generate.sh: the result bundle of each of these raw captures is gone, so nothing was written:$gone" >&2
    exit 1
  fi
  out=$(mktemp -d)
  trap 'rm -rf "${out:?}"' EXIT
  for name in $kept; do
    bundle=$(raw_bundle "$testbed/captures/raw/$name.json")
    case $name in shapes) fixture=swift-testing ;; *) fixture=field ;; esac
    # A run whose answers name no file of its work copy maps none.
    work=$(xcrun xcresulttool get test-results tests --path "$bundle" --compact | grep -oE "(/private)?/var/folders/[^/\"]+/[^/\"]+/T/tmp\.[A-Za-z0-9]+/$fixture/" | head -1 | sed 's#^/private##; s#/$##' || true)
    work=${work:-/nonexistent/$fixture}
    neutral() { neutralise "/private$work" "/testbed/$fixture" "$work" "/testbed/$fixture"; }
    bundle_answers "$bundle" "$name"
  done
  raw_manifest
  for name in $kept; do
    rm -f "$testbed/captures/raw/$name.tests.json" "$testbed/captures/raw/$name.summary.json" "$testbed/captures/raw/$name".details.*.json
  done
  mv "$out"/* "$testbed/captures/raw/"
  echo "$testbed/captures/raw"
}

# Runs that test each case more than once, and a cancelled Swift Testing test, raw, each watched as shapes is: field/'s
# ProbeTests retried on failure (xcodebuild runs a failed test again at once, within the same pass, up to three tries), the plans fixture's two configurations, the swift-testing suite twice over, and its
# Cancel scheme. One boot serves them all, and the first that doesn't come to what it holds stops the run. Each check
# asks only what's known before the run (it completed, its tests ran as written), never the shape it's taken to show.
# Never part of a full run: `testFlaky` fails on a fresh simulator's first run, which retry's check counts on, and the
# full run's probes leave it on a later one.
multi_pass_captures() {
  watched_capture field Field.xcworkspace retry '{"extraArgs":["-only-testing:FeatureTests/ProbeTests","-parallel-testing-enabled","NO","-retry-tests-on-failure","-test-iterations","3"]}' '
    const fs = require("fs")
    const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    const log = fs.readFileSync(process.argv[2], "utf8")
    const fails = log.split("\n").filter(line => /testFails\]. failed/.test(line)).length
    const wrong = [
      [result.structuredContent?.schema === "mobilebuildmcp.output.test-result", "the run completed"],
      [fails === 3, "testFails failed, and was run again until its third try"],
      [/testFlaky\]. failed[\s\S]*testFlaky\]. passed/.test(log), "testFlaky failed, then passed when run again"],
    ].filter(([ok]) => !ok).map(([, what]) => what)
    if (wrong.length) { console.error(`generate.sh: the retry run did not come to what it holds: ${wrong.join(", ")}`); process.exit(1) }
  ' Feature
  watched_capture plans Plans.xcodeproj configurations '{"extraArgs":["-parallel-testing-enabled","NO"]}' '
    const fs = require("fs")
    const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    const log = fs.readFileSync(process.argv[2], "utf8")
    const wrong = [
      [result.structuredContent?.schema === "mobilebuildmcp.output.test-result", "the run completed"],
      [/testFails\]. failed/.test(log), "testFails failed"],
      [/testPasses\]. passed/.test(log), "testPasses passed"],
    ].filter(([ok]) => !ok).map(([, what]) => what)
    if (wrong.length) { console.error(`generate.sh: the configurations run did not come to what it holds: ${wrong.join(", ")}`); process.exit(1) }
  '
  watched_capture swift-testing SwiftTesting.xcodeproj shapes-iterations '{"extraArgs":["-test-iterations","2"]}' '
    const fs = require("fs")
    const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    const log = fs.readFileSync(process.argv[2], "utf8")
    const wrong = [
      [result.structuredContent?.schema === "mobilebuildmcp.output.test-result", "the run completed"],
      [/Test fails\(\) failed after/.test(log), "fails() failed"],
      [/Test passes\(\) passed after/.test(log), "passes() passed"],
    ].filter(([ok]) => !ok).map(([, what]) => what)
    if (wrong.length) { console.error(`generate.sh: the shapes-iterations run did not come to what it holds: ${wrong.join(", ")}`); process.exit(1) }
  '
  watched_capture swift-testing SwiftTesting.xcodeproj cancel '{}' '
    const fs = require("fs")
    const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    const log = fs.readFileSync(process.argv[2], "utf8")
    const wrong = [
      [result.structuredContent?.schema === "mobilebuildmcp.output.test-result", "the run completed"],
      [/Test passes\(\) passed after/.test(log), "passes() passed"],
      [/Test cancels\(\)/.test(log), "cancels() ran"],
    ].filter(([ok]) => !ok).map(([, what]) => what)
    if (wrong.length) { console.error(`generate.sh: the cancel run did not come to what it holds: ${wrong.join(", ")}`); process.exit(1) }
  ' Cancel
  raw_manifest
}

# The logs of committed field captures, kept beside them as `<name>.log`, from the MobileBuildMCP workspace each names
# on this Mac: no run. A log is kept only when it's the test bed's own: its xcodebuild opened a temporary copy of
# field/'s Field.xcworkspace. Its work copy and DerivedData, temporary folders gone since, are read from its own command
# line and neutralised as field/'s step does. All are written, or none.
field_logs() {
  out=$testbed/captures/field
  wanted=${FIELD_CAPTURES:-probes}
  staged=$(mktemp -d)
  trap 'rm -rf "${staged:?}"' EXIT
  for name in $wanted; do
    log=$(named_log "$out/$name.txt")
    if [ -z "$log" ]; then echo "generate.sh: $name's result names no log, so nothing was written" >&2; exit 1; fi
    if [ ! -f "$log" ]; then echo "generate.sh: $name's log is gone from this Mac, so nothing was written" >&2; exit 1; fi
    work=$(grep -oE -- '-workspace [^ ]+/field/Field\.xcworkspace' "$log" | head -1 | sed 's#^-workspace ##; s#/Field\.xcworkspace$##; s#^/private##')
    case $work in */T/tmp.*/field) ;; *) echo "generate.sh: $name's log isn't a run of the test bed's field/, so nothing was written" >&2; exit 1 ;; esac
    derived=$(grep -oE -- '-derivedDataPath [^ ]+' "$log" | head -1 | sed 's#^-derivedDataPath ##; s#^/private##')
    derived=${derived:-/nonexistent/DerivedData}
    neutral() { neutralise "/private$work" /testbed/field "$work" /testbed/field "/private$derived" /testbed/DerivedData "$derived" /testbed/DerivedData; }
    neutral < "$log" | uuids_out > "$staged/$name.log"
  done
  mv "$staged"/* "$out/"
  echo "$out"
}

# Every committed capture file whose PATH isn't neutral yet, rewritten in place through `neutral_path`: no run, and
# nothing but its PATH values changes.
neutral_paths() {
  git ls-files -z captures forms adversarial modular field | xargs -0 grep -l -I 'PATH' 2> /dev/null | while IFS= read -r file; do
    neutral=$(mktemp)
    neutral_path < "$file" > "$neutral"
    if cmp -s "$file" "$neutral"; then rm -f "$neutral"; else cat "$neutral" > "$file"; rm -f "$neutral"; echo "$file"; fi
  done
}

# The crash rules on made-up reports: at finish_simulator's shutdown, and mid-run as a parallel run clones.
crash_self_test() {
  folder=$(mktemp -d)
  watch=$(mktemp -d)
  simulator_id=00000000-0000-4000-8000-000000000001
  clone=00000000-0000-4000-8000-000000000002
  unseen=00000000-0000-4000-8000-000000000003
  stranger=00000000-0000-4000-8000-000000000004
  run_ids=$(mktemp)
  printf '%s\n%s\n%s\n' "$simulator_id" "$clone" "$unseen" > "$run_ids"
  # report <termination indicator> <file name> [<simulator id>]
  report() {
    printf '{"app_name":"tccd"}\n{"procName":"tccd","coalitionName":"com.apple.CoreSimulator.SimDevice.%s","exception":{"type":"EXC_CRASH","signal":"SIGKILL"},"termination":{"namespace":"LIBXPC","indicator":"%s"}}\n' "${3:-$simulator_id}" "$1" > "$folder/$2.ips"
  }
  failed=0
  excused() { shutdown_kill "$folder/$1.ips" || { echo "generate.sh self-test: $2 isn't excused" >&2; failed=1; }; }
  counted() { if shutdown_kill "$folder/$1.ips"; then echo "generate.sh self-test: $2 is excused" >&2; failed=1; fi; }
  report XPC_EXIT_REASON_SIGTERM_TIMEOUT before
  sleep 1
  shutdown_marker=$(mktemp)
  sleep 1
  report XPC_EXIT_REASON_SIGTERM_TIMEOUT shutdown
  report "Namespace SIGNAL, Code 9" other
  report XPC_EXIT_REASON_SIGTERM_TIMEOUT unseen-at-shutdown "$unseen"
  excused shutdown "a shutdown's kill"
  counted unseen-at-shutdown "a clone's kill after the capture simulator's shutdown, never seen leaving Booted itself"
  counted other "a SIGKILL with another termination reason"
  counted before "a kill written before the shutdown"
  rm -f "$shutdown_marker"
  shutdown_marker=
  report XPC_EXIT_REASON_SIGTERM_TIMEOUT cloning-before
  report XPC_EXIT_REASON_SIGTERM_TIMEOUT clone-before-look "$clone"
  sleep 1
  touch "$watch/$simulator_id.departed" "$watch/$clone.departed"
  sleep 1
  report XPC_EXIT_REASON_SIGTERM_TIMEOUT cloning
  report XPC_EXIT_REASON_SIGTERM_TIMEOUT clone-after "$clone"
  report XPC_EXIT_REASON_SIGTERM_TIMEOUT unseen "$unseen"
  report XPC_EXIT_REASON_SIGTERM_TIMEOUT stranger "$stranger"
  excused cloning "the capture simulator's kill after it was seen shutting down to be cloned"
  counted cloning-before "the capture simulator's kill before it was seen leaving Booted"
  excused clone-after "a clone's kill after it was seen leaving Booted"
  counted clone-before-look "a clone's kill in the second before the look that saw it leave"
  counted unseen "a kill of a clone never seen leaving Booted"
  counted stranger "a kill of a simulator not this run's"
  rm -rf "${folder:?}" "${watch:?}" "$run_ids"
  watch=
  run_ids=
  [ "$failed" = 0 ] && echo "generate.sh self-test: the crash rules hold"
  return "$failed"
}

# A name that isn't a full run boots nothing: a fixture's makes that fixture and stops, and one that's no step's or
# fixture's stops with a usage line, writing nothing. Each runs on a copy of scripts/ and base/, with an xcrun that
# fails, and notes it in `asked`, when it's asked to create or boot a simulator.
modes_self_test() {
  copy=$(mktemp -d)
  notes=$(mktemp -d)
  cp -R scripts base "$copy/"
  mkdir -p "$copy/bin"
  printf '#!/bin/sh\ncase "$1 $2" in "simctl create" | "simctl boot") echo "$*" >> "%s/asked"; exit 1 ;; esac\nexec "%s" "$@"\n' "$notes" "$(command -v xcrun)" > "$copy/bin/xcrun"
  chmod +x "$copy/bin/xcrun"
  failed=0
  if ! PATH="$copy/bin:$PATH" sh "$copy/scripts/generate.sh" swift-testing > "$notes/fixture.log" 2>&1; then
    echo "generate.sh self-test: making the swift-testing fixture alone failed: $(tail -3 "$notes/fixture.log")" >&2
    failed=1
  fi
  if [ -f "$notes/asked" ]; then echo "generate.sh self-test: a fixture's name asked for a simulator: $(cat "$notes/asked")" >&2; failed=1; fi
  rm -f "$notes/asked"
  touch "$notes/before"
  if PATH="$copy/bin:$PATH" sh "$copy/scripts/generate.sh" no-such-name > /dev/null 2> "$notes/usage"; then echo "generate.sh self-test: an unknown name succeeded" >&2; failed=1; fi
  grep -q "usage:" "$notes/usage" || { echo "generate.sh self-test: an unknown name gave no usage line" >&2; failed=1; }
  if [ -f "$notes/asked" ]; then echo "generate.sh self-test: an unknown name asked for a simulator: $(cat "$notes/asked")" >&2; failed=1; fi
  [ -z "$(find "$copy" -newer "$notes/before")" ] || { echo "generate.sh self-test: an unknown name wrote files" >&2; failed=1; }
  rm -rf "${copy:?}" "${notes:?}"
  [ "$failed" = 0 ] && echo "generate.sh self-test: a name that isn't a full run boots nothing"
  return "$failed"
}

# neutral_path on each spelling of a PATH a tool writes, each against the line it must become: an echo's, an escaped
# space, a JSON string's, a quoted value, an Xcode elsewhere than /Applications, and other variables left alone.
path_self_test() {
  given=$(mktemp)
  wanted=$(mktemp)
  cat > "$given" <<'PATHS'
    export PATH\=/Applications/Xcode-27.2.0.app/Contents/Developer/usr/bin:/testbed/user/tools/bin:/opt/tools/bin
PATH=/testbed/user/Library/Application\ Support/Tool/scripts:/usr/bin next
{"text":"    export PATH\\=\/Applications\/Xcode.app\/Contents\/Developer\/usr\/bin:\/opt\/tools\/bin\nHOME=\/testbed\/user"}
PATH="/opt/tools/bin:/usr/bin"
PATH=/Volumes/Tools/Xcode-beta.app/Contents/Developer/usr/bin:/opt/tools/bin
    export MANPATH\=/opt/tools/share/man DYLD_LIBRARY_PATH=/opt/tools/lib
PATHS
  cat > "$wanted" <<'PATHS'
    export PATH\=/Applications/Xcode-27.2.0.app/Contents/Developer/usr/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin next
{"text":"    export PATH\\=\/Applications\/Xcode.app\/Contents\/Developer\/usr\/bin:\/usr\/local\/bin:\/usr\/bin:\/bin:\/usr\/sbin:\/sbin\nHOME=\/testbed\/user"}
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PATH=/Volumes/Tools/Xcode-beta.app/Contents/Developer/usr/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
    export MANPATH\=/opt/tools/share/man DYLD_LIBRARY_PATH=/opt/tools/lib
PATHS
  failed=0
  if ! neutral_path < "$given" | diff "$wanted" - >&2; then echo "generate.sh self-test: neutral_path wrote the lines above otherwise" >&2; failed=1; fi
  rm -f "$given" "$wanted"
  [ "$failed" = 0 ] && echo "generate.sh self-test: every PATH is neutral, and nothing else is touched"
  return "$failed"
}

if [ "$build" = field-captures ]; then
  capture_simulator
  field_captures
  exit 0
fi

if [ "$build" = self-test ]; then
  # Called plainly, so `set -e` holds inside them: a failing setup step fails the self-test, not one of its cases.
  crash_self_test
  modes_self_test
  path_self_test
  exit 0
fi

if [ "$build" = shapes ]; then
  capture_simulator
  shapes_captures
  exit 0
fi

if [ "$build" = raw-answers ]; then
  raw_answers
  exit 0
fi

if [ "$build" = neutral-paths ]; then
  neutral_paths
  exit 0
fi

if [ "$build" = multi-pass ]; then
  capture_simulator
  multi_pass_captures
  exit 0
fi

if [ "$build" = field-logs ]; then
  field_logs
  exit 0
fi

if [ "$build" = parallel ]; then
  capture_simulator
  parallel_captures
  exit 0
fi

if [ "$build" = xcode-mcp ]; then
  xcode_mcp_captures
  exit 0
fi

if [ "$build" = raw ]; then
  capture_simulator
  raw_captures
  exit 0
fi

if [ "$build" = raw-session ]; then
  capture_simulator --no-boot
  raw_session_captures
  exit 0
fi

if [ "$build" = raw-build ]; then
  capture_simulator --no-boot
  raw_build_capture
  exit 0
fi

if [ "$build" = concurrency ]; then
  capture_simulator --no-boot
  concurrency_captures
  exit 0
fi

# Only a full run takes every capture. A fixture's name made that fixture above and stops here; any other name is no
# step's or fixture's, and stops having changed nothing. So no name but a full run's boots a simulator from here.
case $build in
  "" | --build) ;;
  *)
    if [ -n "$named" ]; then exit 0; fi
    echo "generate.sh: no step or fixture is named \"$build\"; usage: scripts/generate.sh [--build | <step> | <fixture>]: a step named at the top of this script, or a fixture, forms, adversarial, modular, field, swift-testing or plans" >&2
    exit 2
    ;;
esac

capture_simulator
repetitions
coverage
environment
snapshots
uitests
field_captures
concurrency_captures
raw_captures
raw_build_capture
raw_session_captures
shapes_captures
parallel_captures

scripts/leaks.sh
