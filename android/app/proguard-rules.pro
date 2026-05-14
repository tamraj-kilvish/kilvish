# Preserve generic type signatures so Gson's TypeToken works after R8 shrinking.
# flutter_local_notifications uses Gson internally to load scheduled notifications.
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
