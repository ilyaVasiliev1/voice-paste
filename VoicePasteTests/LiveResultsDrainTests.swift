import Foundation
import Testing

@testable import VoicePaste

private struct Boom: Error {}

/// Отдаёт два элемента и бросает.
private struct FailingResults: AsyncSequence {
    typealias Element = Int

    struct AsyncIterator: AsyncIteratorProtocol {
        var emitted = 0
        mutating func next() async throws -> Int? {
            guard emitted < 2 else { throw Boom() }
            emitted += 1
            return emitted
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
}

private struct FiniteResults: AsyncSequence {
    typealias Element = Int

    struct AsyncIterator: AsyncIteratorProtocol {
        var emitted = 0
        mutating func next() async throws -> Int? {
            guard emitted < 3 else { return nil }
            emitted += 1
            return emitted
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
}

/// Поток обновлений лекции обязан закончиться при любом исходе распознавателя.
/// Прежде ошибка результатов терялась в безымянной задаче, и поток, на который
/// ждёт запись лекции, не заканчивался никогда.
@MainActor
@Suite("Результаты системного распознавателя")
struct LiveResultsDrainTests {

    private static func update(_ value: Int) -> LiveTranscriptUpdate {
        LiveTranscriptUpdate(text: "\(value)", isFinal: true, startSeconds: 0, endSeconds: 0)
    }

    @Test("ошибка распознавателя закрывает поток, принятое не теряется", .timeLimit(.minutes(1)))
    @available(macOS 26.0, *)
    func failureFinishesTheStreamKeepingWhatArrived() async {
        let (stream, continuation) = AsyncStream<LiveTranscriptUpdate>.makeStream()

        await SystemLiveTranscriber.drain(FailingResults(), into: continuation, map: Self.update)

        var received: [String] = []
        for await item in stream { received.append(item.text) }
        #expect(received == ["1", "2"])
    }

    @Test("обычный конец результатов закрывает поток", .timeLimit(.minutes(1)))
    @available(macOS 26.0, *)
    func normalEndFinishesTheStream() async {
        let (stream, continuation) = AsyncStream<LiveTranscriptUpdate>.makeStream()

        await SystemLiveTranscriber.drain(FiniteResults(), into: continuation, map: Self.update)

        var received: [String] = []
        for await item in stream { received.append(item.text) }
        #expect(received == ["1", "2", "3"])
    }
}
