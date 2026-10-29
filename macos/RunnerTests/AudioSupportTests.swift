import XCTest

@testable import pp_friend

final class MicFramerTests: XCTestCase {
  func testSplitsIntoExactFramesAcrossChunks() {
    let framer = MicFramer(frameBytes: 8)

    XCTAssertEqual(framer.append(Data(repeating: 1, count: 3)).count, 0)
    XCTAssertEqual(framer.append(Data(repeating: 2, count: 5)).count, 1)
    XCTAssertEqual(framer.append(Data(repeating: 3, count: 17)).count, 2)

    // 前面剩 1 字节，再来 7 字节正好补齐一帧，剩 0。
    XCTAssertEqual(framer.append(Data(repeating: 4, count: 7)).count, 1)
    XCTAssertEqual(framer.append(Data(repeating: 5, count: 1)).count, 0)
    XCTAssertEqual(framer.totalFrames, 4)
  }

  func testResetDropsPartialFrame() {
    let framer = MicFramer(frameBytes: 8)
    _ = framer.append(Data(repeating: 1, count: 5))
    framer.reset()
    XCTAssertEqual(framer.append(Data(repeating: 2, count: 3)).count, 0)
  }
}

final class PlaybackTimelineTests: XCTestCase {
  func testEpochFiltering() {
    let timeline = PlaybackTimeline()
    XCTAssertTrue(timeline.accepts(epoch: 0))
    XCTAssertTrue(timeline.accepts(epoch: 7))
    _ = timeline.flush(newEpoch: 3)
    XCTAssertFalse(timeline.accepts(epoch: 2))
    XCTAssertTrue(timeline.accepts(epoch: 3))
  }

  func testBacklogAndPlayed() {
    let timeline = PlaybackTimeline()
    let gen = timeline.schedule(1000)
    timeline.schedule(500)
    XCTAssertEqual(timeline.backlogFrames, 1500)

    timeline.played(400, generation: gen)
    XCTAssertEqual(timeline.backlogFrames, 1100)
  }

  func testFlushDiscardsUnplayedAndBumpsGeneration() {
    let timeline = PlaybackTimeline()
    let gen = timeline.schedule(1000)
    timeline.played(300, generation: gen)
    XCTAssertEqual(timeline.flush(newEpoch: 5), 700)
    XCTAssertEqual(timeline.backlogFrames, 0)

    // flush 之前排队的完成回调不能算进新账。
    timeline.played(200, generation: gen)
    XCTAssertEqual(timeline.backlogFrames, 0)
  }

  func testFlushNeverLowersEpoch() {
    let timeline = PlaybackTimeline()
    _ = timeline.flush(newEpoch: 9)
    _ = timeline.flush(newEpoch: 2)
    XCTAssertFalse(timeline.accepts(epoch: 8))
    XCTAssertTrue(timeline.accepts(epoch: 9))
  }
}

final class RmsTests: XCTestCase {
  func testSilenceIsFloor() {
    let samples = [Float](repeating: 0, count: 128)
    XCTAssertEqual(rmsDb(samples), -120)
  }

  func testFullScaleIsNearZeroDb() {
    let samples = [Float](repeating: 1, count: 128)
    XCTAssertEqual(rmsDb(samples), 0, accuracy: 0.01)
  }
}
