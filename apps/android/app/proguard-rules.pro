# Retrofit
-keepattributes Signature
-keepattributes *Annotation*
-keep class retrofit2.** { *; }
-keepclasseswithmembers class * { @retrofit2.http.* <methods>; }

# Kotlinx Serialization
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class com.kuurier.app.core.models.** { *; }

# Ed25519
-keep class net.i2p.crypto.eddsa.** { *; }

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
