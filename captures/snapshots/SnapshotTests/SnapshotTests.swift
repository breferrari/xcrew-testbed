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
