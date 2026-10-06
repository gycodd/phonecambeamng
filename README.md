# PhoneCam (iOS)

Требуется Mac с Xcode 15+ и iPhone (симулятор не подходит: нет датчиков).

## Сборка
1. `brew install xcodegen`
2. `cd PhoneCam && xcodegen generate`  -> появится PhoneCam.xcodeproj
3. Откройте проект в Xcode, в Signing & Capabilities выберите свою Team
   (подойдёт бесплатный Apple ID) и при необходимости смените Bundle Identifier.
4. Подключите iPhone, нажмите Run. На телефоне: Настройки -> Основные ->
   VPN и управление устройством -> доверять разработчику.

## Без XcodeGen
Создайте в Xcode проект iOS App (SwiftUI), удалите авто-файлы, добавьте
Sources/PhoneCamApp.swift и вручную внесите ключи из project.yml в Info.plist.

## Использование
Введите IP ПК -> Старт. Держите телефон в ландшафте (кнопка Home справа).
"Центр" обнуляет камеру, тройной тап возвращает скрытую панель.
