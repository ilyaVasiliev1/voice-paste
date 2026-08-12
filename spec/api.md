# Локальные контракты — VoicePaste

HTTP/API-сервера нет. Идентификаторы `API-local-*` — стабильные границы между UI и локальными Swift actors/protocols; они не создают сетевой интерфейс.

| Контракт | Вход | Выход | Ошибки |
|---|---|---|---|
| `API-local-readiness` | — | `ReadinessState` (разрешения, модель, hotkey) | `modelMissing`, `permissionDenied` |
| `API-local-startDictation` | `hotkeyEvent`, mode | `SessionID` | `notReady`, `alreadyRecording`, `microphoneDenied` |
| `API-local-stopDictation` | `SessionID` | `Transcript` после обработки | `emptyAudio`, `transcriptionFailed` |
| `API-local-enqueueImport` | security-scoped file URL, origin (`mainWindow \| hud`) | `ImportJobID` после staging в локальный cache | `unsupportedFormat`, `insufficientStorage`, `sourceReadFailed` |
| `API-local-importQueue` | observe / cancel / retry action, `ImportJobID` | упорядоченный `[ImportJob]`, progress/stage/ETA | `notFound`, `cancelled`, `decodeFailed`, `transcriptionFailed` |
| `API-local-insertText` | text, target app snapshot | `inserted \| copied` | `accessibilityDenied`, `targetUnavailable` |
| `API-local-normalizeText` | raw text, language, vocabulary, settings | normalized text + applied changes | `spellLanguageUnavailable` (без падения) |
| `API-local-history` | query/CRUD action | `Transcript[]` / updated item | `notFound`, `historyDisabled` |
| `API-local-model` | ensure/load/unload | `ModelState` | `downloadFailed`, `verificationFailed`, `insufficientStorage` |

`ReadinessState` отдельно показывает `ready`, `needsMicrophonePermission`, `needsAccessibilityPermission`, `needsModel`, `downloadingModel`, `error`. UI не начинает запись в любом состоянии, кроме `ready`.

`API-local-enqueueImport` не выполняет инференс в обработчике drop или Finder. Он возвращает управление UI после принятия файла в очередь; единый worker `API-local-importQueue` последовательно готовит и транскрибирует задачи в фоне.
