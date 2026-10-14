import Testing

@testable import VoicePaste

/// Режим «удержание или защёлка»: одна клавиша. Держишь — пишет, пока держишь;
/// тапнул — запись защёлкнулась и идёт до следующего нажатия. Время приходит
/// снаружи, автомат остаётся чистым.
@Suite("Удержание или защёлка")
struct HoldOrLatchTests {

    private static let threshold = DictationStateMachine.latchThreshold

    private func recordingMachine(downAt time: Double = 0) -> DictationStateMachine {
        var machine = DictationStateMachine(mode: .holdOrLatch)
        #expect(machine.handleHotkeyDown(at: time) == .startCapture)
        return machine
    }

    @Test("порог защёлки — треть секунды")
    func thresholdValue() {
        #expect(Self.threshold == 0.35)
    }

    @Test("нажатие начинает запись")
    func downStartsCapture() {
        let machine = recordingMachine()
        #expect(machine.phase == .recording)
    }

    @Test("долгое удержание: отпускание останавливает и отдаёт запись в расшифровку")
    func longHoldStopsOnRelease() {
        var machine = recordingMachine(downAt: 10)
        #expect(machine.handleHotkeyUp(at: 10 + Self.threshold + 0.5) == .stopCaptureAndProcess)
        #expect(machine.phase == .processing)
    }

    @Test("удержание ровно на пороге считается удержанием")
    func holdExactlyAtThresholdIsHold() {
        var machine = recordingMachine(downAt: 10)
        #expect(machine.handleHotkeyUp(at: 10 + Self.threshold) == .stopCaptureAndProcess)
    }

    @Test("короткий тап: запись защёлкивается и продолжается")
    func shortTapLatches() {
        var machine = recordingMachine(downAt: 10)
        #expect(machine.handleHotkeyUp(at: 10.1) == .none)
        #expect(machine.phase == .recording)
    }

    @Test("после защёлки следующее нажатие останавливает запись")
    func nextPressAfterLatchStops() {
        var machine = recordingMachine(downAt: 10)
        _ = machine.handleHotkeyUp(at: 10.1)
        #expect(machine.handleHotkeyDown(at: 14) == .stopCaptureAndProcess)
        #expect(machine.phase == .processing)
    }

    @Test("отпускание после остановки защёлки ничего не делает")
    func releaseAfterLatchStopIsIgnored() {
        var machine = recordingMachine(downAt: 10)
        _ = machine.handleHotkeyUp(at: 10.1)
        _ = machine.handleHotkeyDown(at: 14)
        #expect(machine.handleHotkeyUp(at: 14.05) == .none)
        #expect(machine.phase == .processing)
    }

    @Test("автоповтор клавиши при удержании не останавливает запись")
    func keyRepeatWhileHeldIsIgnored() {
        var machine = recordingMachine(downAt: 10)
        #expect(machine.handleHotkeyDown(at: 10.5) == .none)
        #expect(machine.phase == .recording)
    }

    @Test("кнопка «Готово» в окне останавливает и защёлкнутую запись")
    func finishFromUIWorksWhenLatched() {
        var machine = recordingMachine(downAt: 10)
        _ = machine.handleHotkeyUp(at: 10.1)
        #expect(machine.finishFromUI() == .stopCaptureAndProcess)
    }

    @Test("новая запись после отмены начинается с чистого состояния")
    func cancelResetsLatch() {
        var machine = recordingMachine(downAt: 10)
        _ = machine.handleHotkeyUp(at: 10.1)
        _ = machine.cancelFromUI()
        #expect(machine.handleHotkeyDown(at: 20) == .startCapture)
        // Тап нового сеанса защёлкивает заново, а не останавливает по старому состоянию.
        #expect(machine.handleHotkeyUp(at: 20.1) == .none)
        #expect(machine.phase == .recording)
    }

    @Test("прежние режимы не зависят от времени")
    func oldModesIgnoreTime() {
        var toggle = DictationStateMachine(mode: .toggle)
        #expect(toggle.handleHotkeyDown(at: 100) == .startCapture)
        #expect(toggle.handleHotkeyUp(at: 100.01) == .none)
        #expect(toggle.handleHotkeyDown(at: 100.02) == .stopCaptureAndProcess)

        var hold = DictationStateMachine(mode: .hold)
        #expect(hold.handleHotkeyDown(at: 100) == .startCapture)
        #expect(hold.handleHotkeyUp(at: 100.01) == .stopCaptureAndProcess)
    }
}
