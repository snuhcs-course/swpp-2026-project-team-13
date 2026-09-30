# DiaryWiki

DiaryWiki is the SWPP 2026 Fall Team 13 Android project. The planned product turns diary entries into wiki-style content.

## Current status

The P9 project foundation is implemented with Kotlin and Jetpack Compose. The app currently displays **Hello Android!**.

Diary entry editing, local data storage, wiki generation, and snapshot features are not implemented yet. This foundation validates the build environment and app launch; it is not the complete Iteration 1 end-to-end demo.

## Development environment

| Item | Version |
| --- | --- |
| Android Studio | Quail 3 recommended by Tutorial 00 |
| Android SDK / compileSdk / targetSdk | API 36 |
| Minimum Android version | API 26 (Android 8.0) |
| Gradle daemon JDK | 21 |
| Java source / target compatibility | 11 |
| Gradle Wrapper | 9.5.0 |
| Android Gradle Plugin | 9.3.3 |
| Kotlin Compose compiler plugin | 2.2.10 |
| Compose BOM | 2026.02.01 |
| AndroidX Core KTX | 1.17.0 |

The application ID and namespace are `com.team13.diarywiki`. Dependency versions are declared in `gradle/libs.versions.toml`. Core KTX 1.17.0 is selected for the course's API 36 baseline; the original 1.19.0 dependency required API 37.

JDK 21 runs Gradle, while Java source and target compatibility remain at 11. These are separate settings. The shared `gradle/gradle-daemon-jvm.properties` requires JDK 21; each developer must install it locally.

## Open and run

1. Clone this repository and open its **root folder** in Android Studio, not just the `app/` directory.
2. In SDK Manager, install Android SDK Platform 36 and the SDK tools requested by Android Studio. Install JDK 21 if it is not already available.
3. Confirm that Android Studio recognizes your local SDK location. Machine-specific SDK settings belong in the ignored `local.properties` file.
4. Run **File > Sync Project with Gradle Files** and wait for completion. The first sync requires internet access to download build tools and dependencies. If JDK 21 is not detected, select your installed JDK 21 in the IDE's Gradle JVM settings.
5. In Device Manager, create or reuse an emulator (for example, Medium Phone with an API 36 system image). A physical Android device running API 26 or newer with USB debugging enabled can also be used.
6. Select the `app` run configuration and the device, then click **Run**. The expected screen shows **Hello Android!**.

No API keys or backend services are needed for the current app.

## Build and checks

Run commands from the repository root using the included Gradle Wrapper. For terminal builds, set `JAVA_HOME` to your local JDK 21 installation.

Windows PowerShell:

```powershell
.\gradlew.bat clean :app:assembleDebug :app:testDebugUnitTest :app:lintDebug --no-build-cache
```

macOS / Linux:

```sh
sh ./gradlew clean :app:assembleDebug :app:testDebugUnitTest :app:lintDebug --no-build-cache
```

The debug APK is generated at `app/build/outputs/apk/debug/app-debug.apk`. The Lint HTML report is at `app/build/reports/lint-results-debug.html`.

Verified on Windows: clean debug build with JDK 21 and SDK 36, the template unit test, and Lint. Lint reports no errors; remaining warnings include version-update suggestions and unused template resources. Android Studio sync and the Hello Android screen on a Medium Phone emulator were also confirmed. Physical-device and instrumented tests have not been run. The template unit test does not validate diary or wiki functionality.

## Project structure

| Path | Purpose |
| --- | --- |
| `app/src/main/java/com/team13/diarywiki/MainActivity.kt` | Activity entry point and initial Compose screen |
| `app/src/main/java/com/team13/diarywiki/ui/theme/` | Compose colors, typography, and theme |
| `app/src/main/AndroidManifest.xml` | Application and launcher Activity declarations |
| `app/src/main/res/` | App strings, icons, and Android resources |
| `app/src/test/`, `app/src/androidTest/` | Local and device-based test sources |
| `app/build.gradle.kts` | SDK levels, app identity, and app dependencies |
| `gradle/`, `build.gradle.kts`, `settings.gradle.kts` | Shared build versions and project configuration |

The current UI flow is `MainActivity -> DiaryWikiTheme -> Greeting -> Text`. There is no repository, persistent data flow, or AI integration yet.

Keep IDE settings, local SDK paths, build outputs, and signing keys out of Git. See [Iteration 1 guidance](docs/iteration-1.md) for deliverables. Update this README with implemented features, limitations, and a demo video link as the prototype develops.
