# VoicePaste

Если доступен `~/Developer/AGENTS.md`, применяй общие правила. Здесь только особенности проекта.

## Документы

- `README.md` — возможности, установка, приватность и ограничения для пользователя.
- `spec/` — требования к поведению. При изменении поведения сначала обновляется соответствующее требование.
- `CLAUDE.md` импортирует этот файл; отдельных правил для Claude нет.
- Задачи ведутся на общей доске, изменения выпусков — в GitHub Releases. Планы, дневники, ADR и отчёты о переездах в репозитории не заводятся.

## Разработка и проверки

macOS 15+, Apple Silicon, Xcode 26+, Swift 6. Интерфейс нативный SwiftUI/AppKit.

Первая машина получает закреплённые зависимости:

```bash
xcodebuild -resolvePackageDependencies -project VoicePaste.xcodeproj -scheme VoicePaste \
  -clonedSourcePackagesDirPath "$HOME/Library/Caches/VoicePaste/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile
```

Дальше сборка и проверки работают из кэша без автоматического обновления пакетов:

```bash
python3 scripts/test-build-info.py
zsh scripts/test-safely.sh
```

`xcodebuild test` напрямую запрещён: скрипт изолирует историю, настройки, модель и горячую клавишу пользователя. Обычный `xcodebuild ... build` допустим. Снимки на демонстрационных данных — `zsh scripts/snapshots.sh .artifacts/screenshots`. Реальную историю и аудио в тесты и скриншоты не подставлять.

## Установка и выпуск

- Единственная установленная копия — `/Applications/VoicePaste.app`. Модель и пользовательские данные не входят в пакет приложения.
- Локальная подпись настраивается один раз: `zsh scripts/setup-build-keychain.sh`. Существующий сертификат при обновлении не пересоздаётся.
- Закрыть VoicePaste, затем `zsh scripts/install-local.sh`; проверить — `zsh scripts/verify-local.sh`. Подпись проверяется до замены, при отказе остаётся прежняя копия. Сброс разрешений и тихая подмена подписи на ad-hoc запрещены.
- `MARKETING_VERSION` и `CURRENT_PROJECT_VERSION` задаются в Xcode-проекте. `build-info.py` записывает отпечаток исходников до подписи. Версия и источник видны в настройках; журнал установок — `~/Library/Application Support/VoicePaste/installations.json`.
- Публичный DMG собирает `zsh scripts/build-release.sh`. Без `SIGN_IDENTITY` используется ad-hoc; Developer ID и нотаризация требуют настроенных владельцем `SIGN_IDENTITY`, при необходимости `SIGN_KEYCHAIN` и `NOTARY_PROFILE`.
- Секреты хранятся вне проекта, их значения не читать и не выводить. Коммиты, push и публикация — по запросу владельца. Теги опубликованных выпусков не переписывать.
