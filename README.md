# 📁 Otros archivos modificados

## 🤖 Android
```kotlin
android/app/src/main/kotlin/com/yourpackage/yourapp/MainActivity.kt
```

## 🍎 iOS
```swift
ios/Runner/AppDelegate.swift
```

# Para hacer monitoreo de logs: 

## From your project root

``` python
mkdir -p logs
script -a -f "logs/console_$(date +%F_%H-%M-%S).log"
```

# Solo instalar apk en el dispositivo

# Ver id de dispositivo con flutter devices en la segunda columna

flutter build apk --release
flutter install -d adb-R58T60HBV1D-fdD64J._adb-tls-connect._tcp \
  --use-application-binary build/app/outputs/apk/release/app-release.apk