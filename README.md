# � Validador Retratos Flutter

Aplicación Flutter para validación de retratos.

---

## 📋 Tabla de Contenidos

- [Requisitos Previos](#-requisitos-previos)
- [Ejecución Rápida](#-ejecución-rápida)
- [Estructura de Archivos](#-estructura-de-archivos)
- [Características](#-características)
- [Herramientas de Desarrollo](#-herramientas-de-desarrollo)
- [Mantenimiento de Git](#-mantenimiento-de-git)

---

## 🛠️ Requisitos Previos

### 📱 Instalar ADB (Android Debug Bridge)

Para depurar y comunicarse con dispositivos Android, instala ADB:

```bash
sudo apt update && sudo apt install -y android-tools-adb
```

Verificar dispositivos conectados:

```bash
adb devices
```

> [!NOTE]
> Asegúrate de que el dispositivo tenga habilitada la **"Depuración USB"** en las opciones de desarrollador.

---

## ⚡ Ejecución Rápida

### Script `flutter run` optimizado

- **Script:** `tool/flutter_run_fast.sh`  
  *(usa `android/local.properties` para ubicar tu Flutter SDK)*

- **Wrapper opcional:** `tool/flutter`  
  Para seguir usando `flutter run` con los flags rapidos:
  ```bash
  PATH="$PWD/tool:$PATH" flutter run
  ```

- **Dispositivo por defecto:** `DEVICE_ID="SM A135M"`  
  Puedes cambiarlo así:
  ```bash
  DEVICE_ID="<tu_device_id>" tool/flutter_run_fast.sh
  ```

- **Flags de optimización:**
  - `--no-pub`
  - `--no-track-widget-creation`
  - `--android-skip-build-dependency-validation`
  - `--android-project-arg=compressNativeLibs=true` (reduce el APK para instalaciones más rápidas; desactivar con `COMPRESS_NATIVE_LIBS=false`)

---

## 📁 Estructura de Archivos

### 🤖 Android
```
android/app/src/main/kotlin/com/yourpackage/yourapp/MainActivity.kt
```

### 🍎 iOS
```
ios/Runner/AppDelegate.swift
```

---

## ✨ Características

### 📤 Enviar RAW (DNG) al backend WebRTC

- En `PoseCapturePage` aparece el botón **"Enviar RAW"** (selecciona un `.dng` y lo envía por el DataChannel `images`).
- Luego de actualizar dependencias, ejecuta:
  ```bash
  flutter pub get
  ```

---

## 🔧 Herramientas de Desarrollo

### 📊 Monitoreo de Logs

Desde la raíz del proyecto:

```bash
mkdir -p logs
script -a -f "logs/console_$(date +%F_%H-%M-%S).log"
```

---

## 🧹 Mantenimiento de Git

### Eliminar ramas locales sin remoto

**1. Sincronizar y podar referencias remotas:**
```bash
git fetch --all --prune
```

**2. Eliminar ramas locales huérfanas:**
```bash
git for-each-ref --format='%(refname:short) %(upstream:trackshort)' refs/heads | \
  awk '$2=="[gone]" || $2=="" {print $1}' | \
  xargs -r -n1 git branch -D
```

---

<p align="center">
  <sub>Desarrollado con ❤️ usando Flutter</sub>
</p>
