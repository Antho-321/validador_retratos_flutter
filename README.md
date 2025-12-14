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

# Eliminar ramas locales que ya no tienen remoto

1)

git fetch --all --prune 

2)

git for-each-ref --format='%(refname:short) %(upstream:trackshort)' refs/heads | 

awk '$2=="[gone]" || $2=="" {print $1}' | 

xargs -r -n1 git branch -D 

# Enviar RAW (DNG) al backend WebRTC

- En `PoseCapturePage` aparece el botón `Enviar RAW` (selecciona un `.dng` y lo envía por el DataChannel `images`).
- Luego de actualizar dependencias, ejecuta `flutter pub get`.
