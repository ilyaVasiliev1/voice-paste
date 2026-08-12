# Зависимости и инфраструктура — VoicePaste

| ID | Компонент | Назначение | Решение |
|---|---|---|---|
| DEP-001 | Swift 6 / Xcode / macOS SDK | Нативная сборка | Обязательная системная основа. |
| DEP-002 | SwiftUI + AppKit | Menu bar, Settings, split view, HUD panel | Системные фреймворки. |
| DEP-003 | AVFoundation | Захват микрофона и чтение системно поддерживаемых медиа | Системный фреймворк. |
| DEP-004 | GRDB / SQLite | Локальная история, словарь, миграции и FTS5-поиск | MIT-зависимость через Swift Package Manager; база не покидает устройство. |
| DEP-005 | Accessibility / ApplicationServices | Глобальная hotkey и вставка текста в активное приложение | Системные API; требуют разрешения. |
| DEP-006 | `argmax-oss-swift` / продукт WhisperKit | Локальная Core ML-транскрипция | Открытая MIT-зависимость через Swift Package Manager; без Argmax Pro и без облачного API. |
| DEP-007 | `NSSpellChecker` | Локальная проверка орфографии и язык словаря | Системный AppKit API; только как безопасный слой. |
| DEP-008 | OGG/Opus decode — **системный CoreAudio / AVFoundation** | Telegram voice OGG/Opus | **Spike ЗАКРЫТ (2026-07-19): сторонняя зависимость НЕ нужна.** macOS декодирует OGG-контейнер с Opus штатно через `AVAudioFile` + `AVAudioConverter` (CoreAudio). Никакого libopus/libogg/SwiftOGG/FFmpeg. |

Нет backend, БД-сервера, очереди, Docker, ключей API или внешней инфраструктуры.

## Условие закрытия DEP-008 — ✅ ЗАКРЫТО (2026-07-19)

**Решение:** декодирование OGG/Opus выполняется **нативным CoreAudio/AVFoundation**, без сторонних библиотек. Это упрощает supply chain (`_standards`): новых зависимостей и лицензий не добавляется, отпадают ранее рассматривавшиеся `SwiftOGG` / `libopus`+`libogg` / `YbridOpus`.

**Доказательство (risk-спайк на реальном Telegram-файле, Apple Silicon, macOS 26.4):**
- Реальный Telegram voice: OGG-контейнер, кодек Opus, 48 кГц, mono, 132.35 с (`afinfo` → `File type ID: Oggf`, `Data format: opus`).
- `afconvert -f WAVE -d LEI16@16000 -c 1` → корректный PCM WAV 16 кГц mono, `exit 0`, длительность сходится (132.35 с) — CoreAudio-кодек Opus работает.
- **In-app путь подтверждён кодом:** `AVAudioFile(forReading:)` открыл файл (48 кГц / mono / 6 352 968 кадров), `read(into:)` + `AVAudioConverter` пересэмплировали в **16 кГц mono Float32** (2 117 650 кадров) — ровно входной формат WhisperKit. Всё через системные API; hardened runtime / App Sandbox доп. прав не требуют.
- **Минимальная версия:** нативный декод Opus-в-OGG доступен с macOS 12+; deployment target проекта = **macOS 14.0**, покрывается полностью.

**Реализация US-007 разблокирована.**

**Sample-кейс:** `VoicePasteTests/Fixtures/TelegramOGG/sample-01.ogg` — реальный обезличённый Telegram-семпл, использован для спайка.

**Остаток по AT-024:** приёмочный `AT-024` требует **≥2** реальных Telegram-семпла. Сейчас в фикстурах один (`sample-01.ogg`) → **AT-024 = `blocked`** до появления второго файла (см. `VoicePasteTests/Fixtures/TelegramOGG/README.md`). Это не блокирует реализацию US-007, только финальную приёмку релиза v1.
