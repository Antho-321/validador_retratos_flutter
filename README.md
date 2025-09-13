# 📁 Archivos modificados

## 🤖 Android

```text
android/app/src/main/kotlin/com/yourpackage/yourapp/MainActivity.kt
```

## 🍎 iOS

```text
ios/Runner/AppDelegate.swift
```

# 🪵 Monitoreo de logs

## Desde la raíz del proyecto (Linux/macOS)

```bash
mkdir -p logs
script -a -f "logs/console_$(date +%F_%H-%M-%S).log"
```

Escribe `exit` para terminar.

## En Windows (PowerShell)

```powershell
New-Item -ItemType Directory -Force -Path logs | Out-Null
$log = "logs\console_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
Start-Transcript -Append -Path $log
```

Ejecuta `Stop-Transcript` para terminar.

# 📦 Instalar solo el APK en el dispositivo

1. Obtén el ID del dispositivo (segunda columna) con:

   ```bash
   flutter devices
   ```

2. Compila el APK en modo *release*:

   ```bash
   flutter build apk --release
   ```

3. Instala el APK en el dispositivo (reemplaza `<DEVICE_ID>` con el ID obtenido):

   ```bash
   flutter install -d <DEVICE_ID> \
     --use-application-binary build/app/outputs/apk/release/app-release.apk
   ```

   **Ejemplo:**

   ```bash
   flutter install -d adb-R58T60HBV1D-fdD64J._adb-tls-connect._tcp \
     --use-application-binary build/app/outputs/apk/release/app-release.apk
   ```
