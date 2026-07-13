#!/bin/bash
set -e  # stop immediately on any real error

PROJECT_DIR="$HOME/wallet-manager"
APP_ID="com.krushn.pukywallet"
APP_NAME="PUKY-Wallet"
OUT_APK="puky.apk"
TARGET_SDK=35   # Android 15
COMPILE_SDK=35

# Persistent keystore — created ONCE, reused every build.
# This is what prevents "package appears invalid" / install failures:
# reinstalling an APK signed with a DIFFERENT key than the one already
# on the device is the #1 cause of that error.
KEYSTORE_PATH="$PROJECT_DIR/release-key.jks"
KEYSTORE_ALIAS="pukyrelease"
KEYSTORE_PASS="PukyBuild2026!"

cd "$PROJECT_DIR"

echo "==> 1. Selecting JDK 23 (confirmed full JDK on this system)"
JAVA_HOME_CANDIDATE="/usr/lib/jvm/java-23-openjdk-amd64"
if [ ! -x "$JAVA_HOME_CANDIDATE/bin/javac" ]; then
    echo "❌ JDK 23 not found at $JAVA_HOME_CANDIDATE"
    echo "Run: update-alternatives --list javac"
    exit 1
fi
export JAVA_HOME="$JAVA_HOME_CANDIDATE"
export PATH="$JAVA_HOME/bin:$PATH"
echo "Using: $(java -version 2>&1 | head -n1)"
echo "javac: $(javac -version 2>&1)"

echo "==> 2. Generate persistent release keystore (only if it doesn't already exist)"
if [ ! -f "$KEYSTORE_PATH" ]; then
    keytool -genkeypair -v \
        -keystore "$KEYSTORE_PATH" \
        -alias "$KEYSTORE_ALIAS" \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass "$KEYSTORE_PASS" -keypass "$KEYSTORE_PASS" \
        -dname "CN=PukyWallet, OU=Dev, O=Krushn, L=City, S=State, C=IN"
    echo "✅ New keystore created at $KEYSTORE_PATH — back this file up, it must stay the same forever."
else
    echo "✅ Reusing existing keystore at $KEYSTORE_PATH"
fi

echo "==> 3. Clean slate for the Capacitor/Android project (keystore is OUTSIDE android/, so it survives)"
rm -rf android www apk
mkdir -p www apk
rm -rf ~/.gradle/caches/8.* 2>/dev/null || true

echo "==> 4. Copy web assets"
cp index.html style.css app.js crypto-client.js www/ 2>/dev/null || true
cp logo.svg puky-icon.jpg vizkus.png www/ 2>/dev/null || true
cp *.min.js www/ 2>/dev/null || true

echo "==> 5. Init Capacitor + Android platform"
npx cap init "$APP_NAME" "$APP_ID" --web-dir=www
npx cap add android
npx cap sync android

echo "==> 5b. Patch AndroidManifest.xml with permissions"
MANIFEST_PATH="android/app/src/main/AndroidManifest.xml"
if [ -f "$MANIFEST_PATH" ]; then
    # Remove existing closing manifest tag to append permissions and re-close
    sed -i 's/<\/manifest>//g' "$MANIFEST_PATH"
    cat >> "$MANIFEST_PATH" << 'EOF'
    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29" />
    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
    <uses-feature android:name="android.hardware.camera" android:required="false" />
    <uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />
</manifest>
EOF
    echo "✅ Patched AndroidManifest.xml permissions"
fi

echo "==> 5c. Patch MainActivity.java to request camera permission at startup"
MAIN_ACTIVITY_DIR="android/app/src/main/java/com/krushn/pukywallet"
mkdir -p "$MAIN_ACTIVITY_DIR"
cat > "$MAIN_ACTIVITY_DIR/MainActivity.java" << 'JAVAEOF'
package com.krushn.pukywallet;

import android.Manifest;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.webkit.PermissionRequest;
import android.webkit.WebChromeClient;
import android.webkit.WebView;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    private static final int CAMERA_PERMISSION_REQUEST = 101;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // Request camera permission at startup for QR scanning
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this,
                new String[]{Manifest.permission.CAMERA},
                CAMERA_PERMISSION_REQUEST);
        }

        // Override WebChromeClient to handle camera permission requests from web
        WebView webView = getBridge().getWebView();
        if (webView != null) {
            webView.setWebChromeClient(new WebChromeClient() {
                @Override
                public void onPermissionRequest(final PermissionRequest request) {
                    runOnUiThread(() -> {
                        if (ContextCompat.checkSelfPermission(MainActivity.this, Manifest.permission.CAMERA)
                                == PackageManager.PERMISSION_GRANTED) {
                            request.grant(request.getResources());
                        } else {
                            ActivityCompat.requestPermissions(MainActivity.this,
                                new String[]{Manifest.permission.CAMERA},
                                CAMERA_PERMISSION_REQUEST);
                            request.grant(request.getResources());
                        }
                    });
                }
            });
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == CAMERA_PERMISSION_REQUEST) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                android.util.Log.d("PUKY", "Camera permission granted");
            }
        }
    }
}
JAVAEOF
echo "✅ MainActivity.java patched with camera permission + WebChromeClient override"

echo "==> 5d. Run generate_icons.sh to generate launcher icons"
bash generate_icons.sh

cd android

echo "==> 6. Patch variables.gradle for Android 15 (API 35)"
if [ -f "variables.gradle" ]; then
    sed -i "s/compileSdkVersion = [0-9]*/compileSdkVersion = $COMPILE_SDK/" variables.gradle
    sed -i "s/targetSdkVersion = [0-9]*/targetSdkVersion = $TARGET_SDK/" variables.gradle
    echo "variables.gradle patched:"
    grep -E "compileSdkVersion|targetSdkVersion|minSdkVersion" variables.gradle
else
    echo "⚠️  variables.gradle not found — skipping SDK version patch (check app/build.gradle manually)."
fi

echo "==> 7. Pin app source/target Java compatibility to 17 (what AGP actually needs, regardless of host JDK)"
if grep -q "compileOptions" app/build.gradle; then
    sed -i '/compileOptions/,/}/ s/VERSION_[0-9]*/VERSION_17/g' app/build.gradle
fi
find . -name "build.gradle" -path "*capacitor*" -exec sed -i 's/VERSION_[0-9]*/VERSION_17/g' {} \; 2>/dev/null || true

echo "==> 8. Fix Kotlin stdlib duplicate-class conflict"
if ! grep -q "kotlin-stdlib-jdk7" app/build.gradle; then
    sed -i '/^dependencies {/i \
configurations.all {\
    exclude group: "org.jetbrains.kotlin", module: "kotlin-stdlib-jdk7"\
    exclude group: "org.jetbrains.kotlin", module: "kotlin-stdlib-jdk8"\
}\
' app/build.gradle
    echo "✅ Added Kotlin stdlib exclusions."
fi

echo "==> 9. Add persistent release signing config"
if ! grep -q "signingConfigs" app/build.gradle; then
    sed -i '/^android {/a \
    signingConfigs {\
        release {\
            storeFile file("'"$KEYSTORE_PATH"'")\
            storePassword "'"$KEYSTORE_PASS"'"\
            keyAlias "'"$KEYSTORE_ALIAS"'"\
            keyPassword "'"$KEYSTORE_PASS"'"\
        }\
    }' app/build.gradle

    # attach signingConfig to the existing release buildType block
    sed -i '/buildTypes {/,/^    }/ s/release {/release {\n            signingConfig signingConfigs.release/' app/build.gradle
    echo "✅ Release signing config wired in."
fi

echo "==> 10. Force gradle to use JDK 23"
sed -i '/org.gradle.java.home/d' gradle.properties 2>/dev/null || true
echo "org.gradle.java.home=$JAVA_HOME" >> gradle.properties

echo "==> 11. Clean build"
chmod +x gradlew
./gradlew clean --no-daemon
./gradlew assembleRelease --no-daemon --no-build-cache

echo "==> 12. Copy + verify APK integrity BEFORE touching the device"
BUILT_APK="app/build/outputs/apk/release/app-release.apk"
if [ ! -f "$BUILT_APK" ]; then
    echo "❌ Release build did not produce an APK. Aborting — check the gradle output above."
    exit 1
fi

cp "$BUILT_APK" "../apk/$OUT_APK"
cd ..

echo "==> 13. Verify the APK is a valid, uncorrupted, SIGNED zip"
file apk/"$OUT_APK"
if ! unzip -t apk/"$OUT_APK" > /dev/null 2>&1; then
    echo "❌ APK failed zip integrity check — corrupted build. Do not install."
    exit 1
fi

if ! unzip -l apk/"$OUT_APK" | grep -q "META-INF/.*\.RSA\|META-INF/.*\.SF"; then
    echo "❌ APK is NOT signed (no signature files found). Aborting."
    exit 1
fi
echo "✅ APK is a valid, signed zip archive."

echo "==> 14. Write version.json with SHA256 fingerprints for verification"
APK_SHA256=$(sha256sum apk/"$OUT_APK" | awk '{print $1}')
CERT_SHA256=$(keytool -list -v -keystore "$KEYSTORE_PATH" -alias "$KEYSTORE_ALIAS" -storepass "$KEYSTORE_PASS" 2>/dev/null | grep "SHA256:" | head -n1 | awk '{print $2}')
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > apk/version.json << EOF
{
  "appId": "$APP_ID",
  "appName": "$APP_NAME",
  "buildDate": "$BUILD_DATE",
  "targetSdk": $TARGET_SDK,
  "compileSdk": $COMPILE_SDK,
  "jdkUsed": "23",
  "apkFile": "$OUT_APK",
  "apkSha256": "$APK_SHA256",
  "signingCertSha256": "$CERT_SHA256",
  "keystoreAlias": "$KEYSTORE_ALIAS"
}
EOF
echo "✅ version.json written:"
cat apk/version.json

echo "==> 15. Install (uninstall any old differently-signed build first, to prevent 'package invalid')"
if command -v adb &> /dev/null && adb devices | grep -v "List of devices" | grep -q "device"; then
    echo "Device detected, installing..."
    adb uninstall "$APP_ID" 2>/dev/null || true
    adb install -r "apk/$OUT_APK"
else
    echo "No adb devices connected or adb not found — skipping installation. APK is ready at: $(pwd)/apk/$OUT_APK"
fi

echo "✅ DONE. Signed APK: $(pwd)/apk/$OUT_APK"
ls -lh apk/"$OUT_APK" apk/version.json