# 릴리즈(R8 full mode) 난독화/축소 예외 규칙.

# ── 카카오 SDK (Retrofit + Gson) ──
# R8 full mode 가 제네릭 시그니처를 지우면 카카오 토큰 요청 시
# "Call return type must be parameterized as Call<Foo>" 로 앱이 죽는다(로그인 직후).
-keepattributes Signature, InnerClasses, EnclosingMethod
-keepattributes RuntimeVisibleAnnotations, RuntimeVisibleParameterAnnotations
-keepattributes AnnotationDefault

# Retrofit (공식 R8 full mode 규칙)
-keepclassmembers,allowshrinking,allowobfuscation interface * {
    @retrofit2.http.* <methods>;
}
-keep,allowobfuscation,allowshrinking interface retrofit2.Call
-keep,allowobfuscation,allowshrinking class retrofit2.Response
-keep,allowobfuscation,allowshrinking class kotlin.coroutines.Continuation
-dontwarn retrofit2.**
-dontwarn okhttp3.**
-dontwarn okio.**

# Gson TypeToken (제네릭 응답 파싱)
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

# 카카오 SDK 공식 규칙: API 인터페이스 + 모델 필드
-keep interface com.kakao.sdk.**.*Api
-keep class com.kakao.sdk.**.model.* { <fields>; }
-dontwarn com.kakao.sdk.**
